/// A reader-writer spinlock whose `.init` is unlocked, so it needs no `create` and works from a `__gshared` on first use.
module bc.spinlock;

static import core.atomic;

@nogc nothrow:

/// A test-and-test-and-set reader-writer spinlock for short critical sections; `bc.mutex` sleeps instead, so suits long ones.
/// Never copy one that is held.
/// A waiting writer does not hold off new readers, so a steady stream of them can starve it.
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
/// lockForReading(l);
/// assert(isLocked(l));
/// unlockForReading(l);
/// ---
bool isLocked(ref SpinLock self) @trusted {
	return core.atomic.atomicLoad(self.state) != 0;
}

/// Whether a writer holds `self`.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForWriting(l);
/// assert(isLockedForWriting(l));
/// unlockForWriting(l);
/// ---
bool isLockedForWriting(ref SpinLock self) @trusted {
	return core.atomic.atomicLoad(self.state) < 0;
}

/// Whether readers hold `self`.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForReading(l);
/// assert(isLockedForReading(l));
/// unlockForReading(l);
/// ---
bool isLockedForReading(ref SpinLock self) @trusted {
	return core.atomic.atomicLoad(self.state) > 0;
}

/// Takes a shared hold on `self` without waiting; returns false, taking nothing, if a writer holds it.
///
/// Examples:
/// ---
/// SpinLock l;
/// assert(tryLockForReading(l));
/// assert(tryLockForReading(l));
/// unlockForReading(l);
/// unlockForReading(l);
/// ---
bool tryLockForReading(ref SpinLock self) @trusted {
	int current = core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state);
	// A failed `cas` stores the value it found in `current`, so the loop retries against that.
	while(current >= 0) {
		assert(current < int.max, "bc.spinlock: more readers than the count holds");
		if(core.atomic.cas(&self.state, &current, current + 1)) return true;
	}
	assert(current == -1, "bc.spinlock: a lock state that is neither readers nor one writer");
	return false;
}

/// Spins until no writer holds `self`, then takes a shared hold on it.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForReading(l);
/// assert(!tryLockForWriting(l));
/// unlockForReading(l);
/// ---
void lockForReading(ref SpinLock self) @trusted {
	// Spin on plain loads so waiters share the cache line, rather than each `cas` stealing it from the holder.
	while(!tryLockForReading(self))
		while(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) < 0) core.atomic.pause();
	assert(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) > 0, "bc.spinlock: a read hold that left the lock unheld");
}

/// Releases a shared hold on `self`, which must be read-held.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForReading(l);
/// unlockForReading(l);
/// assert(!isLocked(l));
/// ---
void unlockForReading(ref SpinLock self) @trusted {
	assert(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) > 0, "bc.spinlock: unlockForReading of a lock that is not read-held");
	core.atomic.atomicOp!"-="(self.state, 1);
}


/// Takes the exclusive hold on `self` without waiting; returns false, taking nothing, if anyone holds it.
///
/// Examples:
/// ---
/// SpinLock l;
/// assert(tryLockForWriting(l));
/// assert(!tryLockForWriting(l));
/// unlockForWriting(l);
/// ---
bool tryLockForWriting(ref SpinLock self) @trusted {
	immutable taken = core.atomic.cas(&self.state, 0, -1);
	assert(!taken || core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) == -1, "bc.spinlock: a write hold that left the lock unheld");
	return taken;
}

/// Spins until nobody holds `self`, then takes the exclusive hold on it.
/// Not reentrant: a thread already holding `self` spins forever.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForWriting(l);
/// assert(!tryLockForReading(l));
/// unlockForWriting(l);
/// ---
void lockForWriting(ref SpinLock self) @trusted {
	while(!tryLockForWriting(self))
		while(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) != 0) core.atomic.pause();
	assert(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) == -1, "bc.spinlock: a write hold that left the lock unheld");
}

/// Releases the exclusive hold on `self`, which must be write-held.
///
/// Examples:
/// ---
/// SpinLock l;
/// lockForWriting(l);
/// unlockForWriting(l);
/// assert(!isLocked(l));
/// ---
void unlockForWriting(ref SpinLock self) @trusted {
	assert(core.atomic.atomicLoad!(core.atomic.MemoryOrder.raw)(self.state) == -1, "bc.spinlock: unlockForWriting of a lock that is not write-held");
	core.atomic.atomicStore!(core.atomic.MemoryOrder.rel)(self.state, 0);
}


unittest {
	SpinLock l;
	assert(!isLocked(l));
	assert(tryLockForReading(l));
	lockForReading(l);
	assert(isLocked(l) && isLockedForReading(l) && !isLockedForWriting(l));
	assert(!tryLockForWriting(l));
	unlockForReading(l);
	unlockForReading(l);
	assert(!isLocked(l));

	lockForWriting(l);
	assert(isLockedForWriting(l) && !isLockedForReading(l));
	assert(!tryLockForReading(l) && !tryLockForWriting(l));
	unlockForWriting(l);

	static import bc.platform;
	static if(bc.platform.threadingSupported) {
		static import bc.thread;
		static void takeAndRelease(SpinLock* l, bool write) @nogc nothrow {
			if(write) { lockForWriting(*l); unlockForWriting(*l); }
			else { lockForReading(*l); unlockForReading(*l); }
		}

		// Another thread takes `l` the other way while this one holds it, so must spin until the release.
		foreach(i; 0 .. 2) {
			immutable write = i == 1;
			if(write) lockForReading(l); else lockForWriting(l);
			auto t = bc.thread.create(&takeAndRelease, &l, write);
			assert(!t.isNull);
			// Nothing shows when the thread starts spinning; one that starts late still passes.
			bc.platform.nap(10);
			if(write) unlockForReading(l); else unlockForWriting(l);
			bc.thread.join(t.get);
		}
	}
	assert(!isLocked(l));
}
