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


// Covers the plain `return` on line 40 above: an obviously-invalid port
// name makes semaphore_wait fail immediately with a real (non-interrupt)
// error, rather than the successful or EINTR-retry paths.
version(OSX)
static if(threadingSupported)
unittest {
	Semaphore bogus;
	bogus.handle = cast(semaphore_t) int.max;
	wait(bogus);
}


// Covers the EINTR retry on line 39 above, which only fires when a real
// signal interrupts a thread actually blocked inside semaphore_wait.
version(OSX)
static if(threadingSupported)
unittest {
	import core.sys.posix.signal : sigaction_t, SIGUSR1, pthread_kill;
	import core.sys.posix.unistd : usleep;
	import bc.thread;

	// `sigaction` predates druntime's nothrow/@nogc block for this module,
	// so pull in the real libc symbol under the attributes this module
	// needs. Leaving sa_mask at its zero .init gives an empty signal mask,
	// and sa_flags = 0 deliberately omits SA_RESTART so the syscall aborts
	// instead of transparently restarting.
	pragma(mangle, "sigaction")
	extern(C) nothrow @nogc int sigactionNoGC(int, const scope sigaction_t*, sigaction_t*);
	extern(C) nothrow @nogc void noop(int) {}

	sigaction_t act;
	act.sa_handler = &noop;
	sigactionNoGC(SIGUSR1, &act, null);

	Semaphore s = create();
	scope(exit) free(s);

	static void blockOnWait(Semaphore* s) @nogc nothrow { wait(*s); }
	bc.thread.Thread t = bc.thread.create(&blockOnWait, &s);

	// There's no signal from inside the blocking mach trap saying "the
	// thread is in it now", so send SIGUSR1 repeatedly for a while: any
	// delivery that lands while the thread is inside semaphore_wait aborts
	// it with KERN_ABORTED/EINTR, exercising the retry branch; deliveries
	// that land earlier are harmless no-ops.
	foreach(_; 0 .. 200) {
		pthread_kill(t.handle, SIGUSR1);
		usleep(1000);
	}

	post(s);
	bc.thread.join(t);
}
