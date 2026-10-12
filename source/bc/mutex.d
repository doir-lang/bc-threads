/// Reader-writer locks that sleep while they wait: pthread rwlocks on Linux and macOS, slim reader/writer locks on Windows, and `bc.spinlock` where there are no OS locks.
module bc.mutex;

static import bc.platform;
static import fp.pointer;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);

// `Posix`, not `PthreadBackend`: imports resolve before the mixin above declares it.
version(Posix) {
	import core.sys.posix.pthread : pthread_rwlock_t, pthread_rwlock_init, pthread_rwlock_destroy,
		pthread_rwlock_rdlock, pthread_rwlock_tryrdlock, pthread_rwlock_wrlock, pthread_rwlock_trywrlock,
		pthread_rwlock_unlock;
} else version(Windows) {
	import core.sys.windows.windows : BOOLEAN;

	// druntime does not bind the slim reader/writer lock API, so declare it from synchapi.h.
	private struct SRWLOCK { void* ptr = null; }
	extern(Windows) private {
		void InitializeSRWLock(SRWLOCK*);
		void AcquireSRWLockShared(SRWLOCK*);
		BOOLEAN TryAcquireSRWLockShared(SRWLOCK*);
		void ReleaseSRWLockShared(SRWLOCK*);
		void AcquireSRWLockExclusive(SRWLOCK*);
		BOOLEAN TryAcquireSRWLockExclusive(SRWLOCK*);
		void ReleaseSRWLockExclusive(SRWLOCK*);
	}
}


static if(bc.platform.threadingSupported) {

	/// A reader-writer lock, used only through the pointer `create` returns: macOS binds a rwlock to its address, so a moved one blocks forever.
	version(PthreadBackend) struct Mutex { pthread_rwlock_t handle; }
	else version(Windows) struct Mutex { SRWLOCK handle; }


	/// Allocates an unlocked mutex. Several `bc` modules define `create`, so call it fully qualified, as `bc.mutex.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
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
		auto m = fp.pointer.malloc!Mutex(1);
		if(m is null) return null;
		*m = Mutex.init;
		version(PthreadBackend) {
			bool failed = false;
			debug failed = bc.platform.simulatedFailure();
			if(failed || pthread_rwlock_init(&m.handle, null) != 0) {
				fp.pointer.free(m);
				return null;
			}
		} else version(Windows) InitializeSRWLock(&m.handle);
		return m;
	}

	/// Destroys and frees `m`, which no thread may hold; does nothing if `m` is null. Freeing `m` twice is undefined.
	///
	/// Examples:
	/// ---
	/// free(bc.mutex.create());
	/// free(null);
	/// ---
	void free(Mutex* m) @trusted {
		if(m is null) return;
		version(PthreadBackend) cast(void) pthread_rwlock_destroy(&m.handle);
		fp.pointer.free(m);
	}


	/// Takes a shared hold on `m` without waiting; returns false, taking nothing, if a writer holds it.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// assert(tryReadLock(m));
	/// readUnlock(m);
	/// free(m);
	/// ---
	bool tryReadLock(Mutex* m) @trusted {
		version(PthreadBackend) return pthread_rwlock_tryrdlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockShared(&m.handle) != 0;
	}

	/// Waits until no writer holds `m`, then takes a shared hold on it. The calling thread must not already hold `m`: Windows forbids a second shared hold, and a writer-preferring rwlock deadlocks on one.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// readLock(m);
	/// readUnlock(m);
	/// free(m);
	/// ---
	void readLock(Mutex* m) @trusted {
		version(PthreadBackend) cast(void) pthread_rwlock_rdlock(&m.handle);
		else version(Windows) AcquireSRWLockShared(&m.handle);
	}

	/// Releases a shared hold on `m` that the calling thread took.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// readLock(m);
	/// readUnlock(m);
	/// assert(tryWriteLock(m));
	/// writeUnlock(m);
	/// free(m);
	/// ---
	void readUnlock(Mutex* m) @trusted {
		version(PthreadBackend) cast(void) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockShared(&m.handle);
	}


	/// Takes the exclusive hold on `m` without waiting; returns false, taking nothing, if anyone holds it.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// assert(tryWriteLock(m));
	/// assert(!tryReadLock(m));
	/// writeUnlock(m);
	/// free(m);
	/// ---
	bool tryWriteLock(Mutex* m) @trusted {
		version(PthreadBackend) return pthread_rwlock_trywrlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockExclusive(&m.handle) != 0;
	}

	/// Waits until nobody holds `m`, then takes the exclusive hold on it. The calling thread must not already hold `m`.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// writeLock(m);
	/// writeUnlock(m);
	/// free(m);
	/// ---
	void writeLock(Mutex* m) @trusted {
		version(PthreadBackend) cast(void) pthread_rwlock_wrlock(&m.handle);
		else version(Windows) AcquireSRWLockExclusive(&m.handle);
	}

	/// Releases the exclusive hold on `m` that the calling thread took.
	///
	/// Examples:
	/// ---
	/// Mutex* m = bc.mutex.create();
	/// writeLock(m);
	/// writeUnlock(m);
	/// assert(tryReadLock(m));
	/// readUnlock(m);
	/// free(m);
	/// ---
	void writeUnlock(Mutex* m) @trusted {
		version(PthreadBackend) cast(void) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockExclusive(&m.handle);
	}

} else {

	static import bc.spinlock;

	alias Mutex = bc.spinlock.SpinLock;


	Mutex* create() @trusted {
		auto m = fp.pointer.malloc!Mutex(1);
		if(m is null) return null;
		*m = Mutex.init;
		return m;
	}

	void free(Mutex* m) @trusted { fp.pointer.free(m); }


	bool tryReadLock(Mutex* m) @trusted { return bc.spinlock.tryReadLock(*m); }
	void readLock(Mutex* m) @trusted { bc.spinlock.readLock(*m); }
	void readUnlock(Mutex* m) @trusted { bc.spinlock.readUnlock(*m); }


	bool tryWriteLock(Mutex* m) @trusted { return bc.spinlock.tryWriteLock(*m); }
	void writeLock(Mutex* m) @trusted { bc.spinlock.writeLock(*m); }
	void writeUnlock(Mutex* m) @trusted { bc.spinlock.writeUnlock(*m); }

}


unittest {
	auto m = create();
	assert(m !is null);
	scope(exit) free(m);

	readLock(m);
	static if(bc.platform.threadingSupported) {
		// Windows forbids taking a shared SRW lock twice on one thread, so a second thread takes the other hold.
		static import bc.thread;
		static void tryRead(Mutex* m, bool* ok) @nogc nothrow {
			*ok = tryReadLock(m);
			if(*ok) readUnlock(m);
		}
		bool ok = false;
		auto t = bc.thread.create(&tryRead, m, &ok);
		assert(!t.isNull);
		bc.thread.join(t.get);
		assert(ok);
	} else {
		assert(tryReadLock(m));
		readUnlock(m);
	}
	assert(!tryWriteLock(m));
	readUnlock(m);

	writeLock(m);
	assert(!tryReadLock(m));
	writeUnlock(m);
	assert(tryWriteLock(m));
	writeUnlock(m);

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
