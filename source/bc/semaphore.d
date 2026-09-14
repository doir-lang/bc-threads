module bc.semaphore;

import bc.platform : threadingSupported;

@nogc nothrow:

version(linux) {
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
} else version(OSX) {
	import core.stdc.errno : errno, EINTR;
	import core.sys.darwin.mach.kern_return : KERN_ABORTED;
	import core.sys.darwin.mach.semaphore : mach_task_self, semaphore_create, semaphore_destroy, semaphore_signal, semaphore_t, semaphore_wait, SYNC_POLICY_FIFO;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, CreateSemaphoreA, ReleaseSemaphore, WaitForSingleObject, CloseHandle, INFINITE;
}


static if(threadingSupported) {

	version(linux) struct Semaphore { sem_t handle; }
	else version(OSX) struct Semaphore { semaphore_t handle; }
	else version(Windows) struct Semaphore { HANDLE handle; }

	Semaphore create(uint initial = 0) @trusted @nogc nothrow {
		Semaphore s;
		version(linux) sem_init(&s.handle, 0, initial);
		else version(OSX) semaphore_create(mach_task_self(), &s.handle, SYNC_POLICY_FIFO, cast(int) initial);
		else version(Windows) s.handle = CreateSemaphoreA(null, cast(int) initial, int.max, null);
		return s;
	}

	void wait(ref Semaphore s) @trusted @nogc nothrow {
		version(linux) sem_wait(&s.handle);
		else version(OSX) {
			while(true) {
				immutable rc = semaphore_wait(s.handle);
				if(!rc) return;
				// interrupted by a signal, not a real wakeup - retry
				if(rc == KERN_ABORTED && errno == EINTR) continue;
				return;
			}
		}
		else version(Windows) WaitForSingleObject(s.handle, INFINITE);
	}

	void post(ref Semaphore s) @trusted @nogc nothrow {
		version(linux) sem_post(&s.handle);
		else version(OSX) semaphore_signal(s.handle);
		else version(Windows) ReleaseSemaphore(s.handle, 1, null);
	}

	void free(ref Semaphore s) @trusted @nogc nothrow {
		version(linux) sem_destroy(&s.handle);
		else version(OSX) semaphore_destroy(mach_task_self(), s.handle);
		else version(Windows) CloseHandle(s.handle);
	}

}


static if(threadingSupported)
unittest {
	Semaphore s = create();
	scope(exit) free(s);

	post(s);
	wait(s); // already signalled, must not block
}
