/// Lock striping: a fixed set of locks, each on its own cache line, that a key picks among, so threads guarding many small things take few locks and threads on different stripes never contend or share a line.
///
/// Examples:
/// ---
/// static import bc.spinlock;
/// Striped!(bc.spinlock.SpinLock, 8) locks;
/// bc.spinlock.lockForWriting(stripeFor(locks, 42));
/// bc.spinlock.unlockForWriting(stripeFor(locks, 42));
/// ---
module bc.spinlock.striped;

static import bc.platform;

@nogc nothrow:


/// `stripes` locks of type `Lock`, each padded to `bc.platform.cacheLineBytes`.
/// Its `.init` holds `Lock.init` in every stripe, so it suits a lock whose `.init` is unlocked, such as `bc.spinlock.SpinLock`.
///
/// Examples:
/// ---
/// static import bc.spinlock;
/// Striped!(bc.spinlock.SpinLock, 4) locks;
/// assert(&stripeFor(locks, 1) !is &stripeFor(locks, 2) && &stripeFor(locks, 1) is &stripeFor(locks, 5));
/// ---
struct Striped(Lock, size_t stripes) {
	static assert(stripes > 0, "bc.spinlock.striped: a Striped needs at least one stripe");

	private static struct Padded {
		align(bc.platform.cacheLineBytes) Lock lock;
	}
	private Padded[stripes] padded;
}

/// The stripe guarding `key`: the same lock for the same key, and for keys equal modulo the number of stripes.
/// Hold it briefly, since every key on the stripe waits for it.
///
/// Examples:
/// ---
/// static import bc.spinlock;
/// Striped!(bc.spinlock.SpinLock, 2) locks;
/// assert(&stripeFor(locks, 0) is &stripeFor(locks, 2));
/// ---
ref Lock stripeFor(Lock, size_t stripes)(return ref Striped!(Lock, stripes) striped, size_t key) {
	return striped.padded[key % stripes].lock;
}


unittest { // stripes sit on separate cache lines
	static import bc.spinlock;
	Striped!(bc.spinlock.SpinLock, 3) locks;
	immutable first = cast(size_t) &stripeFor(locks, 0), second = cast(size_t) &stripeFor(locks, 1);
	assert(second - first >= bc.platform.cacheLineBytes && first % bc.platform.cacheLineBytes == 0);
	bc.spinlock.lockForWriting(stripeFor(locks, 0));
	assert(bc.spinlock.tryLockForWriting(stripeFor(locks, 1)));
	bc.spinlock.unlockForWriting(stripeFor(locks, 1));
	bc.spinlock.unlockForWriting(stripeFor(locks, 0));
}
