/// OS threads: pthreads on Linux, macOS and WASI, Win32 threads on Windows.
module bc.thread;

static import bc.platform;
static import core.stdc.stdlib;
public import bc.platform : threadingSupported;
import std.meta : staticMap;
import std.traits : Unqual;
import std.typecons : Nullable;

@nogc nothrow:

mixin(bc.platform.backendSelection);

// `Posix`, not `PthreadBackend`: imports resolve before the mixin above declares it.
version(Posix) import core.sys.posix.pthread : pthread_t, pthread_create, pthread_detach, pthread_join;
version(Posix) static import core.sys.posix.time;

version(linux) {
	import core.sys.linux.sched : cpu_set_t, CPU_COUNT, sched_getaffinity;
	import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
} else version(OSX) {
	import core.sys.darwin.sys.sysctl : sysctlbyname;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, DWORD, CreateThread, WaitForSingleObject, CloseHandle, INFINITE, GetSystemInfo, SYSTEM_INFO;
}


/// The number of logical processors this process may run on (on Linux, those its CPU affinity allows), or 1 if the OS reports none or the platform has no threads.
///
/// Examples:
/// ---
/// assert(processorCount() >= 1);
/// ---
size_t processorCount() @trusted {
	version(linux) {
		// `cpu_set_t` holds 1024 CPUs, so a larger machine fails here and falls back to counting every online one.
		cpu_set_t set;
		if(sched_getaffinity(0, set.sizeof, &set) == 0) {
			immutable allowed = CPU_COUNT(&set);
			if(allowed > 0) return cast(size_t) allowed;
		}
		immutable n = sysconf(_SC_NPROCESSORS_ONLN);
		return n > 0 ? cast(size_t) n : 1;
	} else version(OSX) {
		uint n;
		size_t size = n.sizeof;
		if(sysctlbyname("hw.logicalcpu", &n, &size, null, 0) != 0) return 1;
		return n > 0 ? cast(size_t) n : 1;
	} else version(Windows) {
		SYSTEM_INFO info;
		GetSystemInfo(&info);
		return info.dwNumberOfProcessors > 0 ? cast(size_t) info.dwNumberOfProcessors : 1;
	} else
		return 1;
}


// --- scheduling and time -------------------------------------------------------

// druntime binds neither `clock_gettime` nor `CLOCK_MONOTONIC` on macOS, though libSystem has had both since 10.12.
version(OSX) {
	private extern(C) int clock_gettime(int clock, core.sys.posix.time.timespec* time);
	private enum int darwinClockMonotonic = 6;
}

/// Gives up the rest of the calling thread's time slice, so a thread spinning on another's progress lets it run: `sched_yield` on POSIX and WASI, `SwitchToThread` on Windows, nothing on a platform without threads. It cannot fail.
///
/// Examples:
/// ---
/// yield();
/// ---
void yield() @trusted {
	version(Posix) {
		static import core.sys.posix.sched;
		cast(void) core.sys.posix.sched.sched_yield();
	} else version(WASI) {
		static import core.sys.wasi.sched;
		cast(void) core.sys.wasi.sched.sched_yield();
	} else version(Windows) {
		static import core.sys.windows.winbase;
		cast(void) core.sys.windows.winbase.SwitchToThread();
	}
}

/// Suspends the calling thread for at least `microseconds`, sleeping again for what remains when a signal interrupts it; Windows rounds up to whole milliseconds. Returns false if the platform cannot sleep or the OS reports a failure other than an interruption.
///
/// Examples:
/// ---
/// immutable before = monotonicMicroseconds();
/// assert(sleep(1000));
/// assert(monotonicMicroseconds() - before >= 1000);
/// ---
bool sleep(ulong microseconds) @trusted {
	version(Posix) {
		static import core.stdc.errno;
		core.sys.posix.time.timespec request = {
			tv_sec: cast(typeof(core.sys.posix.time.timespec.tv_sec))(microseconds / 1_000_000),
			tv_nsec: cast(typeof(core.sys.posix.time.timespec.tv_nsec))((microseconds % 1_000_000) * 1_000),
		};
		core.sys.posix.time.timespec remaining;
		while(core.sys.posix.time.nanosleep(&request, &remaining) != 0) {
			if(core.stdc.errno.errno != core.stdc.errno.EINTR) return false;
			request = remaining;
		}
		return true;
	} else version(Windows) {
		static import core.sys.windows.winbase;
		core.sys.windows.winbase.Sleep(cast(uint)((microseconds + 999) / 1000));
		return true;
	} else return false;
}

/// Microseconds since an arbitrary origin fixed for the life of the process, from a clock that never goes backwards: for timing and deadlines, not for the date. It cannot fail on a supported platform; without a monotonic clock it falls back to processor time.
///
/// Examples:
/// ---
/// immutable a = monotonicMicroseconds();
/// assert(monotonicMicroseconds() >= a);
/// ---
ulong monotonicMicroseconds() @trusted {
	version(Posix) {
		core.sys.posix.time.timespec now;
		version(OSX) cast(void) clock_gettime(darwinClockMonotonic, &now);
		else cast(void) core.sys.posix.time.clock_gettime(core.sys.posix.time.CLOCK_MONOTONIC, &now);
		return cast(ulong) now.tv_sec * 1_000_000 + cast(ulong) now.tv_nsec / 1_000;
	} else version(Windows) {
		static import core.sys.windows.winbase;
		static import core.sys.windows.winnt;
		core.sys.windows.winnt.LARGE_INTEGER counter, frequency;
		// Neither fails on Windows XP or later.
		cast(void) core.sys.windows.winbase.QueryPerformanceCounter(&counter);
		cast(void) core.sys.windows.winbase.QueryPerformanceFrequency(&frequency);
		return cast(ulong)(counter.QuadPart / frequency.QuadPart * 1_000_000 + counter.QuadPart % frequency.QuadPart * 1_000_000 / frequency.QuadPart);
	} else {
		static import core.stdc.time;
		return cast(ulong) core.stdc.time.clock() * 1_000_000 / core.stdc.time.CLOCKS_PER_SEC;
	}
}

/// Whole milliseconds since the same origin as `monotonicMicroseconds`, for deadlines and timeouts counted in milliseconds.
///
/// Examples:
/// ---
/// immutable deadline = monotonicMilliseconds() + 50;
/// assert(monotonicMilliseconds() <= deadline);
/// ---
ulong monotonicMilliseconds() {
	return monotonicMicroseconds() / 1000;
}

static if(threadingSupported) {

	/// The entry point `create` runs on a new thread: `extern(C)` returning `void*` with pthreads, `extern(Windows)` returning `DWORD` on Windows.
	version(PthreadBackend) alias ThreadFunction = extern(C) void* function(void*) @nogc nothrow;
	else version(Windows) alias ThreadFunction = extern(Windows) DWORD function(void*) @nogc nothrow;

	/// A started thread, to be joined exactly once with `join`.
	version(PthreadBackend) struct Thread { pthread_t handle; }
	else version(Windows) struct Thread { HANDLE handle; }

	// The C heap, not `fp.pointer`: its `allocator` is per thread, so the new thread could not free with the creator's.
	private struct Closure(F, Args...) {
		F entry;
		// Unqualified, since a `const` or `immutable` argument would make the closure impossible to assign into its heap copy.
		staticMap!(Unqual, Args) args;
	}


	/// Starts `entry(arg)` on a new thread. Several `bc` modules define `create`, so call it fully qualified, as `bc.thread.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns an empty `Nullable` if the OS cannot start one.
	///
	/// Examples:
	/// ---
	/// version(Windows) static extern(Windows) uint entry(void* arg) @nogc nothrow { *cast(int*) arg = 1; return 0; }
	/// else static extern(C) void* entry(void* arg) @nogc nothrow { *cast(int*) arg = 1; return null; }
	///
	/// int ran = 0;
	/// auto t = bc.thread.create(&entry, &ran);
	/// assert(!t.isNull);
	/// join(t.get);
	/// assert(ran == 1);
	/// ---
	Nullable!Thread create(ThreadFunction entry, void* arg) @trusted {
		debug if(bc.platform.simulatedFailure()) return Nullable!Thread.init;
		Thread t;
		version(PthreadBackend) {
			if(pthread_create(&t.handle, null, entry, arg) != 0) return Nullable!Thread.init;
		} else version(Windows) {
			t.handle = CreateThread(null, 0, entry, arg, 0, null);
			if(t.handle is null) return Nullable!Thread.init;
		}
		return Nullable!Thread(t);
	}

	version(PthreadBackend) {
		private extern(C) void* closureTrampoline(F, Args...)(void* arg) {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.entry(closure.args);
			core.stdc.stdlib.free(closure);
			return null;
		}
	} else version(Windows) {
		private extern(Windows) DWORD closureTrampoline(F, Args...)(void* arg) {
			auto closure = cast(Closure!(F, Args)*) arg;
			closure.entry(closure.args);
			core.stdc.stdlib.free(closure);
			return 0;
		}
	}

	/// Starts `entry(args)` on a new thread, passing it a heap copy of `args` that the thread frees once `entry` returns. Several `bc` modules define `create`, so call it fully qualified, as `bc.thread.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns an empty `Nullable`, having freed the copy, if allocation fails or the OS cannot start a thread.
	///
	/// Examples:
	/// ---
	/// static void add(int* sum, int a, int b) @nogc nothrow { *sum = a + b; }
	///
	/// int sum = 0;
	/// auto t = bc.thread.create(&add, &sum, 3, 4);
	/// assert(!t.isNull);
	/// join(t.get);
	/// assert(sum == 7);
	/// ---
	Nullable!Thread create(F, Args...)(F entry, Args args) @trusted
	if(is(typeof(entry(args))) && !is(F == ThreadFunction)) {
		alias closureType = Closure!(F, Args);
		debug if(bc.platform.simulatedFailure()) return Nullable!Thread.init;
		auto closure = cast(closureType*) core.stdc.stdlib.malloc(closureType.sizeof);
		if(closure is null) return Nullable!Thread.init;
		*closure = closureType(entry, args);
		auto t = create(&closureTrampoline!(F, Args), closure);
		if(t.isNull) core.stdc.stdlib.free(closure);
		return t;
	}


	/// Waits for `t` to finish, then releases it.
	///
	/// Examples:
	/// ---
	/// static void work() @nogc nothrow {}
	/// auto t = bc.thread.create(&work);
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

	/// Lets `t` run unjoined, releasing it when it finishes, for a thread nothing will wait for. Call this or `join` on a thread, once, not both.
	///
	/// Examples:
	/// ---
	/// static void work() @nogc nothrow {}
	/// auto t = bc.thread.create(&work);
	/// assert(!t.isNull);
	/// detach(t.get);
	/// ---
	void detach(ref Thread t) @trusted {
		version(PthreadBackend) cast(void) pthread_detach(t.handle);
		else version(Windows) cast(void) CloseHandle(t.handle);
	}

}


unittest {
	assert(processorCount() >= 1);
	version(linux) {
		import core.sys.linux.sched : CPU_ISSET, CPU_SET, sched_setaffinity;

		// Pinned to one CPU it may run on, this thread must count only that one.
		cpu_set_t original, pinned;
		assert(sched_getaffinity(0, original.sizeof, &original) == 0);
		size_t cpu = 0;
		while(!CPU_ISSET(cpu, &original)) cpu++;
		cast(void) CPU_SET(cpu, &pinned);
		assert(sched_setaffinity(0, pinned.sizeof, &pinned) == 0);
		immutable pinnedCount = processorCount();
		assert(sched_setaffinity(0, original.sizeof, &original) == 0);
		assert(pinnedCount == 1);
	}

	// The millisecond clock is the microsecond one truncated, and never runs backwards.
	immutable microseconds = monotonicMicroseconds();
	immutable milliseconds = monotonicMilliseconds();
	assert(milliseconds == microseconds / 1000 || milliseconds == microseconds / 1000 + 1);
	assert(monotonicMilliseconds() >= milliseconds);

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

		// A thread's own `fp.pointer.allocator` must free everything it allocated; the creator's stays untouched.
		static import fp.pointer;
		import core.atomic : atomicLoad, atomicOp, atomicStore;
		static __gshared fp.pointer.Allocator underlying;
		static shared ptrdiff_t live = 0;
		static shared ptrdiff_t calls = 0;
		static void* counting(void* p, size_t size) @nogc nothrow {
			atomicOp!"+="(calls, 1);
			if(size == 0) atomicOp!"-="(live, 1);
			else if(p is null) atomicOp!"+="(live, 1);
			return underlying(p, size);
		}
		static void allocateAndFree(void*) @nogc nothrow {
			fp.pointer.allocator = &counting;
			int* p = fp.pointer.allocate!int(1);
			if(p !is null) fp.pointer.free(p);
		}
		underlying = fp.pointer.allocator;
		t = create(&allocateAndFree, null);
		assert(!t.isNull);
		join(t.get);
		assert(calls == 2 && atomicLoad(live) == 0);
		assert(fp.pointer.allocator is underlying);

		// A detached thread runs to the end without anyone joining it.
		static shared bool finished = false;
		static void finish() @nogc nothrow { atomicStore(finished, true); }
		t = create(&finish);
		assert(!t.isNull);
		detach(t.get);
		while(!atomicLoad(finished)) bc.platform.nap(1);
	}
}

// WASI has no signals to interrupt a sleep.
version(WASI) {} else
version(Posix)
unittest { // a repeating 2ms timer interrupts a 30ms sleep about fifteen times, and sleep must sleep the remainder each time
	import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGALRM;
	import core.sys.posix.sys.time : itimerval, setitimer;

	// druntime does not define `ITIMER_REAL` on macOS; `<sys/time.h>` has it as 0, like every other platform.
	version(OSX) enum ITIMER_REAL = 0;
	else import core.sys.posix.sys.time : ITIMER_REAL;

	static extern(C) void onAlarm(int) @nogc nothrow {}

	// The handler only has to exist for the signal not to kill the process.
	sigaction_t action, previous;
	assert(sigemptyset(&action.sa_mask) == 0);
	action.sa_handler = &onAlarm;
	assert(sigaction(SIGALRM, &action, &previous) == 0);

	itimerval timer;
	timer.it_value.tv_usec = 2_000;
	timer.it_interval.tv_usec = 2_000;
	assert(setitimer(ITIMER_REAL, &timer, null) == 0);

	immutable start = monotonicMicroseconds();
	immutable finished = sleep(30_000);
	immutable elapsed = monotonicMicroseconds() - start;

	// Stop the timer and put the old handler back before asserting anything.
	itimerval off;
	immutable stopped = setitimer(ITIMER_REAL, &off, null) == 0;
	immutable restored = sigaction(SIGALRM, &previous, null) == 0;
	assert(stopped && restored);

	assert(finished);
	// A loaded machine can only oversleep, never undersleep, so the bound is loose.
	assert(elapsed >= 25_000);
	yield();
}
