/// A reader-writer lock for data mostly read, sharded so readers on different threads never touch one cache line: a reader holds its thread's shard alone, a writer every shard.
///
/// It meets `bc.monitor.isLock`, so a `bc.monitor.Monitor!(T, ReaderLock)` keeps a value behind it.
///
/// Examples:
/// ---
/// static import bc.monitor;
/// bc.monitor.Monitor!(int, ReaderLock) m;
/// bc.monitor.write(m).value = 3;
/// assert(bc.monitor.read(m).value == 3);
/// ---
module bc.readerlock;

static import core.atomic;

static import bc.monitor;
static import bc.platform;
static import bc.spinlock;

@nogc nothrow:


/// How many shards a `ReaderLock` has.
enum size_t readerShards = 16;

/// A reader-writer lock whose `.init` is unlocked. A thread already holding it must not take it again.
///
/// Examples:
/// ---
/// ReaderLock l;
/// lockForReading(l);
/// unlockForReading(l);
/// ---
struct ReaderLock {
	private static struct Shard {
		align(bc.platform.cacheLineBytes) bc.spinlock.SpinLock lock;
	}
	private Shard[readerShards] shards;
}

private shared size_t shardsGiven; // threads given a shard, round-robin
private enum size_t noShard = size_t.max;
private size_t ownShard = noShard; // module scope, so one per thread; the shard this thread reads under

private ref bc.spinlock.SpinLock shardOf(return ref ReaderLock self) {
	if(ownShard == noShard) ownShard = core.atomic.atomicOp!"+="(shardsGiven, 1) % readerShards;
	return self.shards[ownShard].lock;
}



// wrapper: takes the calling thread's shard
/// Spins until no writer holds `self`, then takes a shared hold on the calling thread's shard.
///
/// Examples:
/// ---
/// ReaderLock l;
/// lockForReading(l);
/// assert(!tryLockForWriting(l));
/// unlockForReading(l);
/// ---
void lockForReading(ref ReaderLock self) { bc.spinlock.lockForReading(shardOf(self)); }

// wrapper: takes the calling thread's shard
/// Releases the calling thread's shared hold on `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// lockForReading(l);
/// unlockForReading(l);
/// assert(tryLockForWriting(l));
/// unlockForWriting(l);
/// ---
void unlockForReading(ref ReaderLock self) { bc.spinlock.unlockForReading(shardOf(self)); }

// wrapper: takes the calling thread's shard
/// Takes a shared hold on the calling thread's shard without waiting; returns false, taking nothing, if a writer holds `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// assert(tryLockForReading(l));
/// unlockForReading(l);
/// ---
bool tryLockForReading(ref ReaderLock self) { return bc.spinlock.tryLockForReading(shardOf(self)); }


/// Spins until nobody holds `self`, then takes every shard exclusively, in order, so two writers cannot each hold part of it.
///
/// Examples:
/// ---
/// ReaderLock l;
/// lockForWriting(l);
/// assert(!tryLockForReading(l));
/// unlockForWriting(l);
/// ---
void lockForWriting(ref ReaderLock self) {
	foreach(ref shard; self.shards) bc.spinlock.lockForWriting(shard.lock);
}

/// Releases the exclusive hold on `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// lockForWriting(l);
/// unlockForWriting(l);
/// assert(tryLockForReading(l));
/// unlockForReading(l);
/// ---
void unlockForWriting(ref ReaderLock self) {
	foreach(ref shard; self.shards) bc.spinlock.unlockForWriting(shard.lock);
}

/// Takes every shard exclusively without waiting; returns false, taking nothing, if anyone holds `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// assert(tryLockForWriting(l));
/// assert(!tryLockForWriting(l));
/// unlockForWriting(l);
/// ---
bool tryLockForWriting(ref ReaderLock self) {
	foreach(i, ref shard; self.shards)
		if(!bc.spinlock.tryLockForWriting(shard.lock)) {
			foreach(ref taken; self.shards[0 .. i]) bc.spinlock.unlockForWriting(taken.lock);
			return false;
		}
	return true;
}


unittest {
	static assert(bc.monitor.isLock!ReaderLock);
	ReaderLock l;
	lockForReading(l);
	assert(!tryLockForWriting(l));
	unlockForReading(l);
	// Held on the last shard, a write hold fails after taking every other, and gives them back.
	bc.spinlock.lockForReading(l.shards[$ - 1].lock);
	assert(!tryLockForWriting(l));
	foreach(ref shard; l.shards) assert(!bc.spinlock.isLockedForWriting(shard.lock));
	bc.spinlock.unlockForReading(l.shards[$ - 1].lock);
	assert(tryLockForWriting(l));
	assert(!tryLockForReading(l) && !tryLockForWriting(l));
	unlockForWriting(l);
	lockForWriting(l);
	unlockForWriting(l);
	foreach(ref shard; l.shards) assert(!bc.spinlock.isLocked(shard.lock));

	static import bc.platform;
	static if(bc.platform.threadingSupported) {
		static import bc.thread;
		enum threads = 4, rounds = 10_000;
		static struct Pair { long a, b; }
		static void bump(bc.monitor.Monitor!(Pair, ReaderLock)* m) @nogc nothrow {
			foreach(i; 0 .. rounds) {
				auto w = bc.monitor.write(*m);
				++w.value.a;
				++w.value.b;
			}
		}
		bc.monitor.Monitor!(Pair, ReaderLock) m;
		typeof(bc.thread.create(&bump, &m).get())[threads] ts;
		foreach(ref t; ts) {
			auto made = bc.thread.create(&bump, &m);
			assert(!made.isNull);
			t = made.get;
		}
		// Each writer moves both halves in one hold, so a reader on any shard never sees them apart.
		foreach(i; 0 .. rounds) {
			auto r = bc.monitor.read(m);
			assert(r.value.a == r.value.b);
		}
		foreach(ref t; ts) bc.thread.join(t);
		assert(bc.monitor.read(m).value.a == threads * rounds);
	}
}
