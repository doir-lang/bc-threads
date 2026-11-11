/// Reader-writer locks that sleep while they wait: pthread rwlocks on Linux, macOS and WASI, slim reader/writer locks on Windows, and `bc.spinlock` where there are no OS locks.
module bc.mutex;

static import bc.platform;
static import fp.pointer;

@nogc nothrow:

mixin(bc.platform.backendSelection);

// `Posix`, not `PthreadBackend`: imports resolve before the mixin above declares it.
version(Posix) {
	static import core.sys.posix.pthread;
} else version(Windows) {
	static import core.sys.windows.windows;

	// druntime does not bind the slim reader/writer lock API, so declare it from synchapi.h.
	private struct SRWLOCK { void* ptr = null; }
	extern(Windows) private {
		void InitializeSRWLock(SRWLOCK*);
		void AcquireSRWLockShared(SRWLOCK*);
		core.sys.windows.windows.BOOLEAN TryAcquireSRWLockShared(SRWLOCK*);
		void ReleaseSRWLockShared(SRWLOCK*);
		void AcquireSRWLockExclusive(SRWLOCK*);
		core.sys.windows.windows.BOOLEAN TryAcquireSRWLockExclusive(SRWLOCK*);
		void ReleaseSRWLockExclusive(SRWLOCK*);
	}
}


static if(bc.platform.threadingSupported) {

	/// A reader-writer lock, used only through the pointer `create` returns: macOS binds a rwlock to its address, so a moved one blocks forever.
	version(PthreadBackend) struct Mutex { core.sys.posix.pthread.pthread_rwlock_t handle; }
	else version(Windows) struct Mutex { SRWLOCK handle; }


	/// Allocates an unlocked mutex.
	/// Several `bc` modules define `create`, so call it fully qualified, as `bc.mutex.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns null, having freed what it allocated, if allocation or initialization fails.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// assert(m !is null);
	/// free(m);
	/// ---
	Mutex* create() @trusted {
		auto m = fp.pointer.allocate!Mutex(1);
		if(m is null) return null;
		*m = Mutex.init;
		version(PthreadBackend) {
			bool failed = false;
			debug failed = bc.platform.simulatedFailure();
			if(failed || core.sys.posix.pthread.pthread_rwlock_init(&m.handle, null) != 0) {
				fp.pointer.free(m);
				return null;
			}
		} else version(Windows) InitializeSRWLock(&m.handle);
		version(assert) {
			immutable unheld = tryLockForWriting(m);
			if(unheld) unlockForWriting(m);
			assert(unheld, "bc.mutex.create: a new mutex that is already held");
		}
		return m;
	}

	/// Destroys and frees `m`, which no thread may hold; does nothing if `m` is null.
	/// Freeing `m` twice is undefined.
	///
	/// Examples:
	/// ---
	/// free(bc.mutex.create());
	/// free(null);
	/// ---
	void free(Mutex* m) @trusted {
		if(m is null) return;
		version(PthreadBackend) {
			immutable destroyed = core.sys.posix.pthread.pthread_rwlock_destroy(&m.handle);
			assert(destroyed == 0, "bc.mutex.free: destroying a mutex that is held");
		}
		fp.pointer.free(m);
	}


	/// Takes a shared hold on `m` without waiting; returns false, taking nothing, if a writer holds it.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// assert(tryLockForReading(m));
	/// unlockForReading(m);
	/// free(m);
	/// ---
	bool tryLockForReading(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) return core.sys.posix.pthread.pthread_rwlock_tryrdlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockShared(&m.handle) != 0;
	}

	/// Waits until no writer holds `m`, then takes a shared hold on it.
	/// The calling thread must not already hold `m`: Windows forbids a second shared hold, and a writer-preferring rwlock deadlocks on one.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// lockForReading(m);
	/// unlockForReading(m);
	/// free(m);
	/// ---
	void lockForReading(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) {
			immutable result = core.sys.posix.pthread.pthread_rwlock_rdlock(&m.handle);
			assert(result == 0, "bc.mutex: a read hold the thread may not take, as one it already has");
		}
		else version(Windows) AcquireSRWLockShared(&m.handle);
	}

	/// Releases a shared hold on `m` that the calling thread took.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// lockForReading(m);
	/// unlockForReading(m);
	/// assert(tryLockForWriting(m));
	/// unlockForWriting(m);
	/// free(m);
	/// ---
	void unlockForReading(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) {
			immutable result = core.sys.posix.pthread.pthread_rwlock_unlock(&m.handle);
			assert(result == 0, "bc.mutex: unlocking a lock this thread does not hold");
		}
		else version(Windows) ReleaseSRWLockShared(&m.handle);
	}


	/// Takes the exclusive hold on `m` without waiting; returns false, taking nothing, if anyone holds it.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// assert(tryLockForWriting(m));
	/// assert(!tryLockForReading(m));
	/// unlockForWriting(m);
	/// free(m);
	/// ---
	bool tryLockForWriting(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) return core.sys.posix.pthread.pthread_rwlock_trywrlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockExclusive(&m.handle) != 0;
	}

	/// Waits until nobody holds `m`, then takes the exclusive hold on it.
	/// The calling thread must not already hold `m`.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// lockForWriting(m);
	/// unlockForWriting(m);
	/// free(m);
	/// ---
	void lockForWriting(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) {
			immutable result = core.sys.posix.pthread.pthread_rwlock_wrlock(&m.handle);
			assert(result == 0, "bc.mutex: a write hold the thread may not take, as one it already has");
		}
		else version(Windows) AcquireSRWLockExclusive(&m.handle);
	}

	/// Releases the exclusive hold on `m` that the calling thread took.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// lockForWriting(m);
	/// unlockForWriting(m);
	/// assert(tryLockForReading(m));
	/// unlockForReading(m);
	/// free(m);
	/// ---
	void unlockForWriting(Mutex* m) @trusted {
		assert(m !is null, "bc.mutex: locking no mutex");
		version(PthreadBackend) {
			immutable result = core.sys.posix.pthread.pthread_rwlock_unlock(&m.handle);
			assert(result == 0, "bc.mutex: unlocking a lock this thread does not hold");
		}
		else version(Windows) ReleaseSRWLockExclusive(&m.handle);
	}

} else {

	static import bc.spinlock;

	// A struct of its own, not an alias of `SpinLock`, so `bc.monitor` finds this module's functions for a `Mutex*`.
	struct Mutex { bc.spinlock.SpinLock lock; }


	Mutex* create() @trusted {
		auto m = fp.pointer.allocate!Mutex(1);
		if(m is null) return null;
		*m = Mutex.init;
		assert(!bc.spinlock.isLocked(m.lock), "bc.mutex.create: a new mutex that is already held");
		return m;
	}

	void free(Mutex* m) @trusted {
		assert(m is null || !bc.spinlock.isLocked(m.lock), "bc.mutex.free: freeing a mutex that is held");
		fp.pointer.free(m);
	}


	// wrapper: the threadless build keeps the threaded API
	bool tryLockForReading(Mutex* m) @trusted { return bc.spinlock.tryLockForReading(m.lock); }
	// wrapper: the threadless build keeps the threaded API
	void lockForReading(Mutex* m) @trusted { bc.spinlock.lockForReading(m.lock); }
	// wrapper: the threadless build keeps the threaded API
	void unlockForReading(Mutex* m) @trusted { bc.spinlock.unlockForReading(m.lock); }


	// wrapper: the threadless build keeps the threaded API
	bool tryLockForWriting(Mutex* m) @trusted { return bc.spinlock.tryLockForWriting(m.lock); }
	// wrapper: the threadless build keeps the threaded API
	void lockForWriting(Mutex* m) @trusted { bc.spinlock.lockForWriting(m.lock); }
	// wrapper: the threadless build keeps the threaded API
	void unlockForWriting(Mutex* m) @trusted { bc.spinlock.unlockForWriting(m.lock); }

}


unittest {
	auto m = create();
	assert(m !is null);
	scope(exit) free(m);

	lockForReading(m);
	static if(bc.platform.threadingSupported) {
		// Windows forbids taking a shared SRW lock twice on one thread, so a second thread takes the other hold.
		static import bc.thread;
		static void tryRead(Mutex* m, bool* ok) @nogc nothrow {
			*ok = tryLockForReading(m);
			if(*ok) unlockForReading(m);
		}
		bool ok = false;
		auto t = bc.thread.create(&tryRead, m, &ok);
		assert(!t.isNull);
		bc.thread.join(t.get);
		assert(ok);
	} else {
		assert(tryLockForReading(m));
		unlockForReading(m);
	}
	assert(!tryLockForWriting(m));
	unlockForReading(m);

	lockForWriting(m);
	assert(!tryLockForReading(m));
	unlockForWriting(m);
	assert(tryLockForWriting(m));
	unlockForWriting(m);

	free(null);
	debug {
		bc.platform.failAfter(0);
		assert(create() is null);
		// The allocation succeeds, then initializing the rwlock fails.
		static if(bc.platform.threadingSupported) version(PthreadBackend) {
			bc.platform.failAfter(1);
			assert(create() is null);
		}
	}
}
