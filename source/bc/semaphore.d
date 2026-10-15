/// Counting semaphores: POSIX semaphores on Linux and WASI, Mach semaphores on macOS, and semaphore objects on Windows.
module bc.semaphore;

static import bc.platform;
static import fp.pointer;

@nogc nothrow:

version(linux) version = PosixSemaphore;
else version(WASI) version = PosixSemaphore;

version(linux) {
	import core.stdc.errno : errno, EINTR;
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
} else version(WASI) {
	import core.stdc.config : c_long;
	import core.stdc.errno : errno, EINTR;

	// druntime binds no semaphores for WASI, so declare wasi-libc's from its semaphore.h.
	private struct sem_t { int[4 * c_long.sizeof / int.sizeof] val; }
	static assert(sem_t.sizeof == 16);
	extern(C) private {
		int sem_init(sem_t*, int, uint);
		int sem_destroy(sem_t*);
		int sem_wait(sem_t*);
		int sem_post(sem_t*);
	}
} else version(OSX) {
	// macOS declares unnamed POSIX semaphores, but `sem_init` always fails with ENOSYS.
	import core.sys.darwin.mach.kern_return : KERN_ABORTED, KERN_SUCCESS;
	import core.sys.darwin.mach.semaphore : mach_task_self, semaphore_create, semaphore_destroy, semaphore_signal, semaphore_t, semaphore_wait, SYNC_POLICY_FIFO;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, CreateSemaphoreA, ReleaseSemaphore, WaitForSingleObject, CloseHandle, INFINITE;
}


static if(bc.platform.threadingSupported) {

	/// The largest count a semaphore can hold on every platform.
	enum uint maxCount = int.max;

	/// A counting semaphore, used only through the pointer `create` returns: POSIX forbids waiting or posting through a copy of one.
	version(PosixSemaphore) struct Semaphore { sem_t handle; }
	else version(OSX) struct Semaphore { semaphore_t handle; }
	else version(Windows) struct Semaphore { HANDLE handle; }


	/// Allocates a semaphore whose count starts at `initial`, which must not exceed `maxCount`. Several `bc` modules define `create`, so call it fully qualified, as `bc.semaphore.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns null, having freed what it allocated, if allocation fails or the OS cannot create one.
	///
	/// Examples:
	/// ---
	/// Semaphore* s = bc.semaphore.create(1);
	/// assert(s !is null);
	/// wait(s);
	/// free(s);
	/// ---
	Semaphore* create(uint initial = 0) @trusted {
		assert(initial <= maxCount, "bc.semaphore: initial count above maxCount");
		auto s = fp.pointer.malloc!Semaphore(1);
		if(s is null) return null;
		*s = Semaphore.init;
		bool failed = false;
		debug failed = bc.platform.simulatedFailure();
		if(!failed) {
			version(PosixSemaphore) failed = sem_init(&s.handle, 0, initial) != 0;
			else version(OSX) failed = semaphore_create(mach_task_self(), &s.handle, SYNC_POLICY_FIFO, cast(int) initial) != KERN_SUCCESS;
			else version(Windows) {
				s.handle = CreateSemaphoreA(null, cast(int) initial, maxCount, null);
				failed = s.handle is null;
			}
		}
		if(failed) {
			fp.pointer.free(s);
			return null;
		}
		return s;
	}

	/// Destroys and frees `s`, which no thread may still be waiting on; does nothing if `s` is null. Freeing `s` twice is undefined.
	///
	/// Examples:
	/// ---
	/// free(bc.semaphore.create());
	/// free(null);
	/// ---
	void free(Semaphore* s) @trusted {
		if(s is null) return;
		version(PosixSemaphore) cast(void) sem_destroy(&s.handle);
		else version(OSX) cast(void) semaphore_destroy(mach_task_self(), s.handle);
		else version(Windows) cast(void) CloseHandle(s.handle);
		fp.pointer.free(s);
	}


	/// Blocks until the count of `s` is above zero, then decrements it.
	///
	/// Examples:
	/// ---
	/// Semaphore* s = bc.semaphore.create();
	/// post(s);
	/// wait(s);
	/// free(s);
	/// ---
	void wait(Semaphore* s) @trusted {
		// A signal interrupts the wait without a post, so retry; any other failure means `s` is not a live semaphore.
		version(PosixSemaphore) while(sem_wait(&s.handle) != 0 && errno == EINTR) {}
		else version(OSX) while(semaphore_wait(s.handle) == KERN_ABORTED) {}
		else version(Windows) cast(void) WaitForSingleObject(s.handle, INFINITE);
	}

	/// Increments the count of `s`, waking one thread blocked in `wait` on it, if any. A post that would raise the count above `maxCount` is lost.
	///
	/// Examples:
	/// ---
	/// Semaphore* s = bc.semaphore.create();
	/// post(s);
	/// post(s);
	/// wait(s);
	/// wait(s);
	/// free(s);
	/// ---
	void post(Semaphore* s) @trusted {
		version(PosixSemaphore) cast(void) sem_post(&s.handle);
		else version(OSX) cast(void) semaphore_signal(s.handle);
		else version(Windows) cast(void) ReleaseSemaphore(s.handle, 1, null);
	}

	version(unittest) version(linux) {
		import core.sys.posix.semaphore : sem_getvalue;

		/// The count of `s`, for tests to check that no post is left over; only Linux can report it.
		///
		/// Examples:
		/// ---
		/// version(linux) {
		/// 	Semaphore* s = bc.semaphore.create(2);
		/// 	assert(value(s) == 2);
		/// 	free(s);
		/// }
		/// ---
		package int value(Semaphore* s) @trusted {
			int n;
			immutable failed = sem_getvalue(&s.handle, &n) != 0;
			assert(!failed);
			return n;
		}
	}


	unittest {
		free(null);
		debug {
			bc.platform.failAfter(0);
			assert(create() is null);
			// The allocation succeeds, then creating the OS semaphore fails.
			bc.platform.failAfter(1);
			assert(create() is null);
		}

		auto s = create(2);
		assert(s !is null);
		scope(exit) free(s);
		wait(s);
		wait(s);
		post(s);
		post(s);
		version(linux) assert(value(s) == 2);
		wait(s);
		wait(s);
		version(linux) assert(value(s) == 0);

		static import bc.thread;
		static void waitThenMark(Semaphore* s, shared bool* passed) @nogc nothrow {
			import core.atomic : atomicStore;
			wait(s);
			atomicStore(*passed, true);
		}

		// The count is zero, so the thread cannot pass its `wait` until this one posts, however long it is given.
		import core.atomic : atomicLoad;
		shared bool passed = false;
		auto t = bc.thread.create(&waitThenMark, s, &passed);
		assert(!t.isNull);
		bc.platform.nap(10);
		assert(!atomicLoad(passed));
		post(s);
		bc.thread.join(t.get);
		assert(atomicLoad(passed));
	}

}
