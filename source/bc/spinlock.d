/// A reader-writer spinlock whose `.init` is unlocked, so it needs no `create` and works from a `__gshared` on first use.
module bc.spinlock;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas, pause, MemoryOrder;

@nogc nothrow:

/// A test-and-test-and-set reader-writer spinlock for short critical sections; `bc.mutex` sleeps instead, so suits long ones. Never copy one that is held. A waiting writer does not hold off new readers, so a steady stream of them can starve it.
struct SpinLock {
	// 0 when free, the number of readers while read-held, -1 while write-held.
	private shared int state = 0;
}


/// Whether readers or a writer hold `self`.
///
/// Examples:
/// ---
/// SpinLock l;
/// assert(!isLocked(l));
/// readLock(l);
/// assert(isLocked(l));
/// readUnlock(l);
/// ---
bool isLocked(ref SpinLock self) @trusted {
	return atomicLoad(self.state) != 0;
}

/// Whether a writer holds `self`.
///
/// Examples:
/// ---
/// SpinLock l;
/// writeLock(l);
/// assert(isWriteLocked(l));
/// writeUnlock(l);
/// ---
bool isWriteLocked(ref SpinLock self) @trusted {
	return atomicLoad(self.state) < 0;
}

/// Whether readers hold `self`.
///
/// Examples:
/// ---
/// SpinLock l;
/// readLock(l);
/// assert(isReadLocked(l));
/// readUnlock(l);
/// ---
bool isReadLocked(ref SpinLock self) @trusted {
	return atomicLoad(self.state) > 0;
}

/// Takes a shared hold on `self` without waiting; returns false, taking nothing, if a writer holds it.
///
/// Examples:
/// ---
/// SpinLock l;
/// assert(tryReadLock(l));
/// assert(tryReadLock(l));
/// readUnlock(l);
/// readUnlock(l);
/// ---
bool tryReadLock(ref SpinLock self) @trusted {
	int cur = atomicLoad!(MemoryOrder.raw)(self.state);
	// A failed `cas` stores the value it found in `cur`, so the loop retries against that.
	while(cur >= 0)
		if(cas(&self.state, &cur, cur + 1)) return true;
	return false;
}

/// Spins until no writer holds `self`, then takes a shared hold on it.
///
/// Examples:
/// ---
/// SpinLock l;
/// readLock(l);
/// assert(!tryWriteLock(l));
/// readUnlock(l);
/// ---
void readLock(ref SpinLock self) @trusted {
	// Spin on plain loads so waiters share the cache line, rather than each `cas` stealing it from the holder.
	while(!tryReadLock(self))
		while(atomicLoad!(MemoryOrder.raw)(self.state) < 0) pause();
}

/// Releases a shared hold on `self`, which must be read-held.
///
/// Examples:
/// ---
/// SpinLock l;
/// readLock(l);
/// readUnlock(l);
/// assert(!isLocked(l));
/// ---
void readUnlock(ref SpinLock self) @trusted {
	assert(atomicLoad!(MemoryOrder.raw)(self.state) > 0, "bc.spinlock: readUnlock of a lock that is not read-held");
	atomicOp!"-="(self.state, 1);
}


/// Takes the exclusive hold on `self` without waiting; returns false, taking nothing, if anyone holds it.
///
/// Examples:
/// ---
/// SpinLock l;
/// assert(tryWriteLock(l));
/// assert(!tryWriteLock(l));
/// writeUnlock(l);
/// ---
bool tryWriteLock(ref SpinLock self) @trusted {
	return cas(&self.state, 0, -1);
}

/// Spins until nobody holds `self`, then takes the exclusive hold on it. Not reentrant: a thread already holding `self` spins forever.
///
/// Examples:
/// ---
/// SpinLock l;
/// writeLock(l);
/// assert(!tryReadLock(l));
/// writeUnlock(l);
/// ---
void writeLock(ref SpinLock self) @trusted {
	while(!tryWriteLock(self))
		while(atomicLoad!(MemoryOrder.raw)(self.state) != 0) pause();
}

/// Releases the exclusive hold on `self`, which must be write-held.
///
/// Examples:
/// ---
/// SpinLock l;
/// writeLock(l);
/// writeUnlock(l);
/// assert(!isLocked(l));
/// ---
void writeUnlock(ref SpinLock self) @trusted {
	assert(atomicLoad!(MemoryOrder.raw)(self.state) == -1, "bc.spinlock: writeUnlock of a lock that is not write-held");
	atomicStore!(MemoryOrder.rel)(self.state, 0);
}


unittest {
	SpinLock l;
	assert(tryReadLock(l));
	readLock(l);
	assert(isLocked(l) && isReadLocked(l) && !isWriteLocked(l));
	assert(!tryWriteLock(l));
	readUnlock(l);
	readUnlock(l);
	assert(!isLocked(l));

	writeLock(l);
	assert(isWriteLocked(l) && !isReadLocked(l));
	assert(!tryReadLock(l) && !tryWriteLock(l));
	writeUnlock(l);

	static import bc.platform;
	static if(bc.platform.threadingSupported) {
		static import bc.thread;
		static void takeAndRelease(SpinLock* l, bool write) @nogc nothrow {
			if(write) { writeLock(*l); writeUnlock(*l); }
			else { readLock(*l); readUnlock(*l); }
		}

		// Another thread takes `l` the other way while this one holds it, so must spin until the release.
		foreach(i; 0 .. 2) {
			immutable write = i == 1;
			if(write) readLock(l); else writeLock(l);
			auto t = bc.thread.create(&takeAndRelease, &l, write);
			assert(!t.isNull);
			// Nothing shows when the thread starts spinning; one that starts late still passes.
			version(Windows) {
				import core.sys.windows.winbase : Sleep;
				Sleep(10);
			} else {
				import core.sys.posix.unistd : usleep;
				cast(void) usleep(10_000);
			}
			if(write) readUnlock(l); else writeUnlock(l);
			bc.thread.join(t.get);
		}
	}
	assert(!isLocked(l));
}
