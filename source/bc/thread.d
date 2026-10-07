/// OS threads: pthreads on Linux and macOS, Win32 threads on Windows.
module bc.thread;

static import bc.platform;
static import fp.pointer;
public import bc.platform : threadingSupported;
import std.meta : staticMap;
import std.traits : Unqual;
import std.typecons : Nullable;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);

// `Posix`, not `PthreadBackend`: imports resolve before the mixin above declares it.
version(Posix) import core.sys.posix.pthread : pthread_t, pthread_create, pthread_join;

version(linux) {
	import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
} else version(OSX) {
	import core.sys.darwin.sys.sysctl : sysctlbyname;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, DWORD, CreateThread, WaitForSingleObject, CloseHandle, INFINITE, GetSystemInfo, SYSTEM_INFO;
}


/// The number of processors the OS reports (physical cores on macOS), or 1 if it reports none or the platform has no threads.
///
/// Examples:
/// ---
/// assert(hardwareConcurrency() >= 1);
/// ---
size_t hardwareConcurrency() @trusted {
	version(linux) {
		immutable n = sysconf(_SC_NPROCESSORS_ONLN);
		return n > 0 ? cast(size_t) n : 1;
	} else version(OSX) {
		uint n;
		size_t len = n.sizeof;
		if(sysctlbyname("hw.physicalcpu", &n, &len, null, 0) != 0) return 1;
		return n > 0 ? cast(size_t) n : 1;
	} else version(Windows) {
		SYSTEM_INFO info;
		GetSystemInfo(&info);
		return info.dwNumberOfProcessors > 0 ? cast(size_t) info.dwNumberOfProcessors : 1;
	} else
		return 1;
}


static if(threadingSupported) {

	/// The entry point `create` runs on a new thread: `extern(C)` returning `void*` with pthreads, `extern(Windows)` returning `DWORD` on Windows.
	version(PthreadBackend) alias ThreadFunction = extern(C) void* function(void*) @nogc nothrow;
	else version(Windows) alias ThreadFunction = extern(Windows) DWORD function(void*) @nogc nothrow;

	/// A started thread, to be joined exactly once with `join`.
	version(PthreadBackend) struct Thread { pthread_t handle; }
	else version(Windows) struct Thread { HANDLE handle; }

	private struct Closure(F, Args...) {
		F fn;
		// Unqualified, since a `const` or `immutable` argument would make the closure impossible to assign into its heap copy.
		staticMap!(Unqual, Args) args;
	}


	/// Starts `fn(arg)` on a new thread.
	///
	/// Returns an empty `Nullable` if the OS cannot start one.
	///
	/// Examples:
	/// ---
	/// version(Windows) static extern(Windows) uint entry(void* arg) @nogc nothrow { *cast(int*) arg = 1; return 0; }
	/// else static extern(C) void* entry(void* arg) @nogc nothrow { *cast(int*) arg = 1; return null; }
	///
	/// int ran = 0;
	/// auto t = create(&entry, &ran);
	/// assert(!t.isNull);
	/// join(t.get);
	/// assert(ran == 1);
	/// ---
	Nullable!Thread create(ThreadFunction fn, void* arg) @trusted {
		debug if(bc.platform.simulatedFailure()) return Nullable!Thread.init;
		Thread t;
		version(PthreadBackend) {
			if(pthread_create(&t.handle, null, fn, arg) != 0) return Nullable!Thread.init;
		} else version(Windows) {
			t.handle = CreateThread(null, 0, fn, arg, 0, null);
			if(t.handle is null) return Nullable!Thread.init;
		}
		return Nullable!Thread(t);
	}

	version(PthreadBackend) {
		private extern(C) void* closureTrampoline(F, Args...)(void* arg) {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.fn(closure.args);
			fp.pointer.free(closure);
			return null;
		}
	} else version(Windows) {
		private extern(Windows) DWORD closureTrampoline(F, Args...)(void* arg) {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.fn(closure.args);
			fp.pointer.free(closure);
			return 0;
		}
	}

	/// Starts `fn(args)` on a new thread, passing it a heap copy of `args` that the thread frees once `fn` returns.
	///
	/// Returns an empty `Nullable`, having freed the copy, if allocation fails or the OS cannot start a thread.
	///
	/// Examples:
	/// ---
	/// static void add(int* sum, int a, int b) @nogc nothrow { *sum = a + b; }
	///
	/// int sum = 0;
	/// auto t = create(&add, &sum, 3, 4);
	/// assert(!t.isNull);
	/// join(t.get);
	/// assert(sum == 7);
	/// ---
	Nullable!Thread create(F, Args...)(F fn, Args args) @trusted
	if(is(typeof(fn(args))) && !is(F == ThreadFunction)) {
		alias C = Closure!(F, Args);
		auto closure = fp.pointer.malloc!C(1);
		if(closure is null) return Nullable!Thread.init;
		*closure = C(fn, args);
		auto t = create(&closureTrampoline!(F, Args), closure);
		if(t.isNull) fp.pointer.free(closure);
		return t;
	}


	/// Waits for `t` to finish, then releases it.
	///
	/// Examples:
	/// ---
	/// static void work() @nogc nothrow {}
	/// auto t = create(&work);
	/// assert(!t.isNull);
	/// join(t.get);
	/// ---
	void join(ref Thread t) @trusted {
		version(PthreadBackend) cast(void) pthread_join(t.handle, null);
		else version(Windows) {
			cast(void) WaitForSingleObject(t.handle, INFINITE);
			cast(void) CloseHandle(t.handle);
		}
	}

}


unittest {
	assert(hardwareConcurrency() >= 1);

	static if(threadingSupported) {
		static void add(int* sum, int a, int b) @nogc nothrow { *sum = a + b; }

		int sum = 0;
		immutable three = 3;
		auto t = create(&add, &sum, three, 4);
		assert(!t.isNull);
		join(t.get);
		assert(sum == 7);

		// The first fails copying the arguments, the second starting the thread.
		debug foreach(i; 0 .. 2) {
			bc.platform.failAfter(i);
			assert(create(&add, &sum, 1, 2).isNull);
		}
		assert(sum == 7);
	}
}
