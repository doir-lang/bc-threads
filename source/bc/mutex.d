module bc.mutex;

import bc.platform : threadingSupported, PthreadBackendMixin;

@nogc nothrow:

mixin(PthreadBackendMixin);

version(linux) {
	import core.sys.posix.pthread : pthread_rwlock_t, pthread_rwlock_init, pthread_rwlock_destroy,
		pthread_rwlock_rdlock, pthread_rwlock_tryrdlock, pthread_rwlock_wrlock, pthread_rwlock_trywrlock,
		pthread_rwlock_unlock;
} else version(OSX) {
	import core.sys.posix.pthread : pthread_rwlock_t, pthread_rwlock_init, pthread_rwlock_destroy,
		pthread_rwlock_rdlock, pthread_rwlock_tryrdlock, pthread_rwlock_wrlock, pthread_rwlock_trywrlock,
		pthread_rwlock_unlock;
} else version(Windows) {
	import core.sys.windows.windows : BOOLEAN;

	// SRWLOCK is not exposed by druntime's windows bindings, so declare the
	// slim reader/writer lock API (synchapi.h, kernel32.dll) ourselves.
	private struct SRWLOCK { void* ptr = null; }
	extern(Windows) @nogc nothrow private {
		void InitializeSRWLock(SRWLOCK*);
		void AcquireSRWLockShared(SRWLOCK*);
		BOOLEAN TryAcquireSRWLockShared(SRWLOCK*);
		void ReleaseSRWLockShared(SRWLOCK*);
		void AcquireSRWLockExclusive(SRWLOCK*);
		BOOLEAN TryAcquireSRWLockExclusive(SRWLOCK*);
		void ReleaseSRWLockExclusive(SRWLOCK*);
	}
}


static if(threadingSupported) {

	version(PthreadBackend) struct Mutex { pthread_rwlock_t handle; }
	else version(Windows) struct Mutex { SRWLOCK handle; }

	Mutex create() @trusted @nogc nothrow {
		Mutex m;
		version(PthreadBackend) pthread_rwlock_init(&m.handle, null);
		else version(Windows) InitializeSRWLock(&m.handle);
		return m;
	}

	void free(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_rwlock_destroy(&m.handle);
		else version(Windows) {}
	}

	bool tryReadLock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) return pthread_rwlock_tryrdlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockShared(&m.handle) != 0;
	}

	void readLock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_rwlock_rdlock(&m.handle);
		else version(Windows) AcquireSRWLockShared(&m.handle);
	}

	void readUnlock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockShared(&m.handle);
	}

	bool tryWriteLock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) return pthread_rwlock_trywrlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockExclusive(&m.handle) != 0;
	}

	void writeLock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_rwlock_wrlock(&m.handle);
		else version(Windows) AcquireSRWLockExclusive(&m.handle);
	}

	void writeUnlock(ref Mutex m) @trusted @nogc nothrow {
		version(PthreadBackend) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockExclusive(&m.handle);
	}

} else {

	// No OS lock primitives available on this platform - fall back to a
	// busy-wait spinlock built on plain atomics.
	import core.atomic : atomicOp, atomicLoad, atomicStore, cas;

	struct Mutex { shared int state = 0; }

	Mutex create() @nogc nothrow { return Mutex.init; }

	void free(ref Mutex m) @nogc nothrow {}

	bool tryReadLock(ref Mutex m) @trusted @nogc nothrow {
		int cur = atomicLoad(m.state);
		while(cur >= 0) {
			if(cas(&m.state, cur, cur + 1)) return true;
			cur = atomicLoad(m.state);
		}
		return false;
	}

	void readLock(ref Mutex m) @nogc nothrow {
		while(!tryReadLock(m)) {}
	}

	void readUnlock(ref Mutex m) @trusted @nogc nothrow {
		atomicOp!"-="(m.state, 1);
	}

	bool tryWriteLock(ref Mutex m) @trusted @nogc nothrow {
		return cas(&m.state, 0, -1);
	}

	void writeLock(ref Mutex m) @nogc nothrow {
		while(!tryWriteLock(m)) {}
	}

	void writeUnlock(ref Mutex m) @trusted @nogc nothrow {
		atomicStore(m.state, 0);
	}

}


unittest {
	Mutex m = create();
	scope(exit) free(m);

	// multiple readers may hold the lock together
	readLock(m);
	assert(tryReadLock(m));
	assert(!tryWriteLock(m));
	readUnlock(m);
	assert(!tryWriteLock(m));
	readUnlock(m);

	// once readers are gone, a writer can take it exclusively
	assert(tryWriteLock(m));
	assert(!tryReadLock(m));
	writeUnlock(m);

	writeLock(m);
	assert(!tryReadLock(m));
	assert(!tryWriteLock(m));
	writeUnlock(m);
}
