module bc.mutex;

import bc.platform : threadingSupported, PthreadBackendMixin;
import fp.pointer;

@nogc nothrow:

mixin(PthreadBackendMixin);

// Not `version(PthreadBackend)`: imports are resolved before the string mixin
// that declares that identifier has run. `Posix` selects the same platforms
// this module has a pthread backend for.
version(Posix) {
	import core.sys.posix.pthread : pthread_rwlock_t, pthread_rwlock_init, pthread_rwlock_destroy,
		pthread_rwlock_rdlock, pthread_rwlock_tryrdlock, pthread_rwlock_wrlock, pthread_rwlock_trywrlock,
		pthread_rwlock_unlock;
} else version(Windows) {
	import core.sys.windows.windows : BOOLEAN;

	// SRWLOCK is not exposed by druntime's windows bindings, so declare the
	// slim reader/writer lock API (synchapi.h, kernel32.dll) ourselves.
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


static if(threadingSupported) {

	version(PthreadBackend) struct Mutex { pthread_rwlock_t handle; }
	else version(Windows) struct Mutex { SRWLOCK handle; }

	// Heap-allocated and never relocated after `create`: on Darwin,
	// pthread_rwlock_t's internal state is bound to the struct's address at
	// init time, so moving/copying an initialized one to a different address
	// (e.g. returning it by value into a caller-owned field) corrupts it and
	// every subsequent lock call blocks forever.
	Mutex* create() @trusted {
		auto m = fp.pointer.malloc!Mutex(1);
		*m = Mutex.init;
		version(PthreadBackend) pthread_rwlock_init(&m.handle, null);
		else version(Windows) InitializeSRWLock(&m.handle);
		return m;
	}

	void free(Mutex* m) @trusted {
		version(PthreadBackend) pthread_rwlock_destroy(&m.handle);
		else version(Windows) {}
		fp.pointer.free(m);
	}

	bool tryReadLock(Mutex* m) @trusted {
		version(PthreadBackend) return pthread_rwlock_tryrdlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockShared(&m.handle) != 0;
	}

	void readLock(Mutex* m) @trusted {
		version(PthreadBackend) pthread_rwlock_rdlock(&m.handle);
		else version(Windows) AcquireSRWLockShared(&m.handle);
	}

	void readUnlock(Mutex* m) @trusted {
		version(PthreadBackend) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockShared(&m.handle);
	}

	bool tryWriteLock(Mutex* m) @trusted {
		version(PthreadBackend) return pthread_rwlock_trywrlock(&m.handle) == 0;
		else version(Windows) return TryAcquireSRWLockExclusive(&m.handle) != 0;
	}

	void writeLock(Mutex* m) @trusted {
		version(PthreadBackend) pthread_rwlock_wrlock(&m.handle);
		else version(Windows) AcquireSRWLockExclusive(&m.handle);
	}

	void writeUnlock(Mutex* m) @trusted {
		version(PthreadBackend) pthread_rwlock_unlock(&m.handle);
		else version(Windows) ReleaseSRWLockExclusive(&m.handle);
	}

} else {

	// No OS lock primitives available on this platform - fall back to a
	// busy-wait spinlock built on plain atomics.
	import core.atomic : atomicOp, atomicLoad, atomicStore, cas;

	struct Mutex { shared int state = 0; }

	Mutex* create() @trusted {
		auto m = fp.pointer.malloc!Mutex(1);
		*m = Mutex.init;
		return m;
	}

	void free(Mutex* m) @trusted { fp.pointer.free(m); }

	bool tryReadLock(Mutex* m) @trusted {
		int cur = atomicLoad(m.state);
		while(cur >= 0) {
			if(cas(&m.state, cur, cur + 1)) return true;
			cur = atomicLoad(m.state);
		}
		return false;
	}

	void readLock(Mutex* m) {
		while(!tryReadLock(m)) {}
	}

	void readUnlock(Mutex* m) @trusted {
		atomicOp!"-="(m.state, 1);
	}

	bool tryWriteLock(Mutex* m) @trusted {
		return cas(&m.state, 0, -1);
	}

	void writeLock(Mutex* m) {
		while(!tryWriteLock(m)) {}
	}

	void writeUnlock(Mutex* m) @trusted {
		atomicStore(m.state, 0);
	}

}


unittest {
	auto m = create();
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
