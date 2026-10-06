/// A test-and-test-and-set reader-writer spinlock that needs no `create`:
/// `SpinLock.init` is unlocked, so one can sit in a `__gshared` or a struct
/// field and be used on first touch, with no lazy initialization of its own
/// to race on. Meant for short, rarely contended critical sections; anything
/// that may hold the lock for long belongs on `bc.mutex`, which sleeps
/// instead of spinning (on platforms without OS locks, `bc.mutex` is this).
///
/// Readers are not kept out by a waiting writer, so a steady stream of
/// overlapping readers can starve one.
module bc.spinlock;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas, pause, MemoryOrder;

@nogc nothrow:

/// Plain data, but never copy one that is held: the copy would be held too.
struct SpinLock {
	// 0 when free, the number of readers while read-held, -1 while write-held.
	private shared int state = 0;
}

/// Acquires a shared hold if no writer has the lock, without waiting.
bool tryReadLock(ref SpinLock self) @trusted {
	int cur = atomicLoad!(MemoryOrder.raw)(self.state);
	while (cur >= 0) {
		if (cas(&self.state, cur, cur + 1)) return true;
		cur = atomicLoad!(MemoryOrder.raw)(self.state);
	}
	return false;
}

void readLock(ref SpinLock self) @trusted {
	// Wait on plain loads, so waiters share the cache line until it is
	// released, rather than each `cas` stealing it from the holder.
	while (!tryReadLock(self))
		while (atomicLoad!(MemoryOrder.raw)(self.state) < 0) pause();
}

void readUnlock(ref SpinLock self) @trusted {
	assert(atomicLoad!(MemoryOrder.raw)(self.state) > 0, "bc.spinlock: readUnlock of a lock that is not read-held");
	atomicOp!"-="(self.state, 1);
}

/// Acquires the exclusive hold if nobody has the lock, without waiting.
bool tryWriteLock(ref SpinLock self) @trusted {
	return cas(&self.state, 0, -1);
}

void writeLock(ref SpinLock self) @trusted {
	while (!tryWriteLock(self))
		while (atomicLoad!(MemoryOrder.raw)(self.state) != 0) pause();
}

void writeUnlock(ref SpinLock self) @trusted {
	assert(atomicLoad!(MemoryOrder.raw)(self.state) == -1, "bc.spinlock: writeUnlock of a lock that is not write-held");
	atomicStore!(MemoryOrder.rel)(self.state, 0);
}

/// Whether the lock is held at all, by readers or a writer.
bool isLocked(ref SpinLock self) @trusted {
	return atomicLoad(self.state) != 0;
}

bool isWriteLocked(ref SpinLock self) @trusted {
	return atomicLoad(self.state) < 0;
}


unittest {
	SpinLock l;
	assert(!isLocked(l));

	// multiple readers may hold the lock together
	readLock(l);
	assert(tryReadLock(l));
	assert(isLocked(l));
	assert(!isWriteLocked(l));
	assert(!tryWriteLock(l));
	readUnlock(l);
	assert(!tryWriteLock(l));
	readUnlock(l);
	assert(!isLocked(l));

	// once readers are gone, a writer can take it exclusively
	assert(tryWriteLock(l));
	assert(isWriteLocked(l));
	assert(!tryReadLock(l));
	assert(!tryWriteLock(l)); // not reentrant
	writeUnlock(l);
	assert(!isLocked(l));

	writeLock(l);
	assert(isWriteLocked(l));
	writeUnlock(l);
}

unittest {
	// Mutual exclusion under contention: a plain, non-atomic counter bumped
	// from every worker ends exact only if no two increments interleave, and
	// readers, which share the lock with each other but never with a writer,
	// must only ever see an even value since each write adds two in steps.
	import bc.threadpool : create, free, run, Job;

	static struct Shared {
		SpinLock lock;
		size_t counter;
		shared bool sawOdd;
	}
	enum workers = 4, perJob = 20_000;

	static void bump(void* arg) @nogc nothrow {
		auto s = cast(Shared*) arg;
		foreach (i; 0 .. perJob) {
			writeLock(s.lock);
			s.counter = s.counter + 1;
			s.counter = s.counter + 1;
			writeUnlock(s.lock);
		}
	}

	static void peek(void* arg) @nogc nothrow {
		auto s = cast(Shared*) arg;
		foreach (i; 0 .. perJob) {
			readLock(s.lock);
			if (s.counter % 2) atomicStore(s.sawOdd, true);
			readUnlock(s.lock);
		}
	}

	Shared s;
	auto pool = create(workers);
	scope(exit) free(pool);

	enum writers = workers;
	Job[workers * 2] jobs;
	foreach (i, ref j; jobs) j = Job(i < writers ? &bump : &peek, &s);
	run(pool, jobs[]);

	assert(s.counter == writers * perJob * 2);
	assert(!atomicLoad(s.sawOdd));
	assert(!isLocked(s.lock));
}

unittest {
	// Usable from a `__gshared` with no initialization at all.
	__gshared SpinLock global;
	writeLock(global);
	assert(isWriteLocked(global));
	writeUnlock(global);
	readLock(global);
	assert(isLocked(global) && !isWriteLocked(global));
	readUnlock(global);
}
