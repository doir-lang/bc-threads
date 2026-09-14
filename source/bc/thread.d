module bc.thread;

import core.atomic : atomicOp, atomicLoad;
import fp.pointer;
public import bc.platform : threadingSupported;
import bc.platform : PthreadBackendMixin;

@nogc nothrow:

mixin(PthreadBackendMixin);

version(linux) {
	import core.sys.posix.pthread : pthread_t, pthread_create, pthread_join;
	import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
} else version(OSX) {
	import core.sys.posix.pthread : pthread_t, pthread_create, pthread_join;
	import core.sys.darwin.sys.sysctl : sysctlbyname;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, DWORD, CreateThread, WaitForSingleObject, CloseHandle, INFINITE, GetSystemInfo, SYSTEM_INFO;
}


size_t hardwareConcurrency() @trusted @nogc nothrow {
	version(linux) {
		immutable n = sysconf(_SC_NPROCESSORS_ONLN);
		return n > 0 ? cast(size_t) n : 1;
	} else version(OSX) {
		uint n;
		size_t len = n.sizeof;
		sysctlbyname("hw.physicalcpu", &n, &len, null, 0);
		return n > 0 ? cast(size_t) n : 1;
	} else version(Windows) {
		SYSTEM_INFO info;
		GetSystemInfo(&info);
		return info.dwNumberOfProcessors > 0 ? cast(size_t) info.dwNumberOfProcessors : 1;
	} else
		return 1;
}


static if(threadingSupported) {

	version(PthreadBackend) alias ThreadFunction = extern(C) void* function(void*) @nogc nothrow;
	else version(Windows) alias ThreadFunction = extern(Windows) DWORD function(void*) @nogc nothrow;

	version(PthreadBackend) struct Thread { pthread_t handle; }
	else version(Windows) struct Thread { HANDLE handle; }

	Thread create(ThreadFunction fn, void* arg) @trusted @nogc nothrow {
		Thread t;
		version(PthreadBackend) pthread_create(&t.handle, null, fn, arg);
		else version(Windows) t.handle = CreateThread(null, 0, fn, arg, 0, null);
		return t;
	}

	void join(ref Thread t) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_join(t.handle, null);
		else version(Windows) { WaitForSingleObject(t.handle, INFINITE); CloseHandle(t.handle); }
	}


	private struct Closure(F, Args...) {
		F fn;
		Args args;
	}

	version(PthreadBackend) {
		private extern(C) void* closureTrampoline(F, Args...)(void* arg) @nogc nothrow {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.fn(closure.args);
			fp.pointer.free(closure);
			return null;
		}
	} else version(Windows) {
		private extern(Windows) DWORD closureTrampoline(F, Args...)(void* arg) @nogc nothrow {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.fn(closure.args);
			fp.pointer.free(closure);
			return 0;
		}
	}

	// Spawns fn(args) on a new thread, boxing fn and a copy of args in a
	// malloc'd closure that the trampoline frees after the call returns.
	Thread create(F, Args...)(F fn, Args args) @trusted @nogc nothrow
	if(is(typeof(fn(args))) && !is(F == ThreadFunction)) {
		alias C = Closure!(F, Args);
		auto closure = fp.pointer.malloc!C(1);
		assert(closure !is null);
		*closure = C(fn, args);
		return create(&closureTrampoline!(F, Args), closure);
	}

}


static if(threadingSupported)
unittest {
	static shared int counter = 0;

	version(PthreadBackend) extern(C) void* bump(void* arg) @nogc nothrow {
		atomicOp!"+="(counter, 1);
		return null;
	} else version(Windows) extern(Windows) DWORD bump(void* arg) @nogc nothrow {
		atomicOp!"+="(counter, 1);
		return 0;
	}

	Thread t = create(&bump, null);
	join(t);
	assert(atomicLoad(counter) == 1);
}


static if(threadingSupported)
unittest {
	static shared int sum = 0;

	static void addTwo(int a, int b) @nogc nothrow {
		atomicOp!"+="(sum, a + b);
	}

	Thread t = create(&addTwo, 3, 4);
	join(t);
	assert(atomicLoad(sum) == 7);
}
