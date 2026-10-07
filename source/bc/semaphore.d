/// Counting semaphores: POSIX semaphores on Linux, Mach semaphores on macOS, and semaphore objects on Windows.
module bc.semaphore;

static import bc.platform;
import std.typecons : Nullable, nullable;

@nogc nothrow:

version(linux) {
	import core.stdc.errno : errno, EINTR;
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
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

	/// A counting semaphore made by `create`. Copy one only before threads share it: POSIX forbids waiting or posting through a copy of one in use.
	version(linux) struct Semaphore { sem_t handle; }
	else version(OSX) struct Semaphore { semaphore_t handle; }
	else version(Windows) struct Semaphore { HANDLE handle; }


	/// Creates a semaphore whose count starts at `initial`, which must not exceed `maxCount`.
	///
	/// Returns an empty `Nullable` if the OS cannot create one.
	///
	/// Examples:
	/// ---
	/// auto s = create(1);
	/// assert(!s.isNull);
	/// wait(s.get);
	/// free(s.get);
	/// ---
	Nullable!Semaphore create(uint initial = 0) @trusted {
		assert(initial <= maxCount, "bc.semaphore: initial count above maxCount");
		debug if(bc.platform.simulatedFailure()) return Nullable!Semaphore.init;
		Semaphore s;
		version(linux) {
			if(sem_init(&s.handle, 0, initial) != 0) return Nullable!Semaphore.init;
		} else version(OSX) {
			if(semaphore_create(mach_task_self(), &s.handle, SYNC_POLICY_FIFO, cast(int) initial) != KERN_SUCCESS) return Nullable!Semaphore.init;
		} else version(Windows) {
			s.handle = CreateSemaphoreA(null, cast(int) initial, maxCount, null);
			if(s.handle is null) return Nullable!Semaphore.init;
		}
		return nullable(s);
	}

	/// Destroys `s`, which no thread may still be waiting on.
	///
	/// Examples:
	/// ---
	/// auto s = create().get;
	/// free(s);
	/// ---
	void free(ref Semaphore s) @trusted {
		version(linux) cast(void) sem_destroy(&s.handle);
		else version(OSX) cast(void) semaphore_destroy(mach_task_self(), s.handle);
		else version(Windows) cast(void) CloseHandle(s.handle);
	}


	/// Blocks until the count of `s` is above zero, then decrements it.
	///
	/// Examples:
	/// ---
	/// auto s = create().get;
	/// post(s);
	/// wait(s);
	/// free(s);
	/// ---
	void wait(ref Semaphore s) @trusted {
		// A signal interrupts the wait without a post, so retry; any other failure means `s` is not a live semaphore.
		version(linux) while(sem_wait(&s.handle) != 0 && errno == EINTR) {}
		else version(OSX) while(semaphore_wait(s.handle) == KERN_ABORTED) {}
		else version(Windows) cast(void) WaitForSingleObject(s.handle, INFINITE);
	}

	/// Increments the count of `s`, waking one thread blocked in `wait` on it, if any. A post that would raise the count above `maxCount` is lost.
	///
	/// Examples:
	/// ---
	/// auto s = create().get;
	/// post(s);
	/// post(s);
	/// wait(s);
	/// wait(s);
	/// free(s);
	/// ---
	void post(ref Semaphore s) @trusted {
		version(linux) cast(void) sem_post(&s.handle);
		else version(OSX) cast(void) semaphore_signal(s.handle);
		else version(Windows) cast(void) ReleaseSemaphore(s.handle, 1, null);
	}

}
