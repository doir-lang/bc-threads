/// Interning tables any thread may use at once: an `Interner!T` gives each distinct sequence of `T` a dense id, from 0, and gives back the sequence for an id without taking a lock, so the jobs of a pool can intern names side by side.
///
/// Each copy is followed by a `T.init`, so an interned `char` sequence is a C string too. The table is split into shards by hash, each behind a `bc.spinlock`, so interning on different shards never waits. Sequences are copied into chunks a shard never moves, and ids find them through pages that are never moved either, so a lookup by id reads without locking: an id reaches another thread only after the interning that made it has released its shard.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// immutable a = intern(names, "a"), b = intern(names, "b");
/// assert(a != b && intern(names, "a") == a && content(names, b) == "b");
/// assert(find(names, "c") == none && count(names) == 2);
/// ---
module bc.interner;

static import core.atomic;
static import core.stdc.string;

static import fp.dynarray;
static import fp.hash;
static import fp.hashtable;
static import fp.pointer;

static import bc.spinlock;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// No id: what `find` gives for a sequence never interned, and what `intern` gives when an allocation is refused.
enum uint none = uint.max;

private enum size_t shardBits = 6;
private enum size_t pageBits = 14;
private enum size_t directoryBits = 14;
// Ids are below this, so a page and a slot in it are found by shifting.
private enum size_t maxIds = size_t(1) << (pageBits + directoryBits);
private enum size_t chunkBytes = 1 << 12;

private struct Entry(T) {
	const(T)* items;
	uint length;
	uint id;
}

private struct Shard(T) {
	bc.spinlock.SpinLock lock;
	Entry!T* table;
	T** chunks; // where this shard's sequences live; each is a block of `chunkBytes`, or one sequence larger than that
	size_t used; // items used in the last chunk
}

/// A table interning sequences of `T`, which must be plain bytes. Its `.init` is empty and ready; release it with `free`, from one thread, once no other uses it.
///
/// Examples:
/// ---
/// Interner!ulong keys;
/// scope(exit) free(keys);
/// ulong[2] key = [5, 0];
/// assert(intern(keys, key[]) == find(keys, key[]));
/// ---
struct Interner(T) {
	private Shard!T* shards = null;
	private const(T)[]** pages = null; // the directory: ids `i << pageBits` up are in page `i`
	private shared uint next = 0;
	private bc.spinlock.SpinLock setup; // held while the shards, the directory or a page are first allocated
}


// --- table entries -----------------------------------------------------------

private const(ubyte)[] bytesOf(T)(const(T)[] items) @trusted {
	return (cast(const(ubyte)*) items.ptr)[0 .. items.length * T.sizeof];
}

private size_t hashEntry(T)(inout(ubyte)[] bytes) @trusted {
	auto e = cast(const(Entry!T)*) bytes.ptr;
	return cast(size_t) fp.hash.murmur(bytesOf(e.items[0 .. e.length]));
}

private bool equalEntry(T)(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	auto x = cast(const(Entry!T)*) a.ptr, y = cast(const(Entry!T)*) b.ptr;
	return x.length == y.length && core.stdc.string.memcmp(x.items, y.items, x.length * T.sizeof) == 0;
}


// --- queries -----------------------------------------------------------------

/// The number of ids handed out.
///
/// Examples:
/// ---
/// Interner!char names;
/// assert(count(names) == 0);
/// ---
size_t count(T)(ref const Interner!T interner) @trusted {
	return core.atomic.atomicLoad((cast(Interner!T*) &interner).next);
}

/// The sequence interned as `id`, which must have come from `intern` on `interner`. It takes no lock.
///
/// Examples:
/// ---
/// Interner!ulong keys;
/// scope(exit) free(keys);
/// ulong[2] key = [3, 0];
/// assert(content(keys, intern(keys, key[])) == key[]);
/// ---
const(T)[] content(T)(ref const Interner!T interner, uint id) @trusted {
	assert(id < count(interner), "bc.interner: no such id");
	return interner.pages[id >> pageBits][id & ((1 << pageBits) - 1)];
}

// The shard `hash` selects, from its top bits: a shard's table indexes by its low ones, which a shard chosen from them would cluster.
private Shard!T* shardOf(T)(ref Interner!T interner, ulong hash) {
	return &interner.shards[hash >> (64 - shardBits)];
}

/// The id of `items`, or `none` if they were never interned.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// assert(find(names, "a") == none);
/// ---
uint find(T)(ref Interner!T interner, const(T)[] items) @trusted {
	if (core.atomic.atomicLoad(*cast(shared(Shard!T*)*) &interner.shards) is null) return none;
	auto shard = shardOf(interner, fp.hash.murmur(bytesOf(items)));
	bc.spinlock.readLock(shard.lock);
	scope(exit) bc.spinlock.readUnlock(shard.lock);
	if (shard.table is null) return none;
	auto found = fp.hashtable.find(shard.table, Entry!T(items.ptr, cast(uint) items.length, none));
	return found is null ? none : found.id;
}


// --- creation and freeing ----------------------------------------------------

// Allocates the shards and the directory if no thread has yet. False on refusal.
private bool ready(T)(ref Interner!T interner) @trusted {
	if (core.atomic.atomicLoad(*cast(shared(Shard!T*)*) &interner.shards) !is null) return true;
	bc.spinlock.writeLock(interner.setup);
	scope(exit) bc.spinlock.writeUnlock(interner.setup);
	if (interner.shards !is null) return true;
	auto directory = cast(const(T)[]**) fp.pointer.allocFunction(null, (size_t(1) << directoryBits) * (const(T)[]*).sizeof);
	if (directory is null) return false;
	core.stdc.string.memset(directory, 0, (size_t(1) << directoryBits) * (const(T)[]*).sizeof);
	auto shards = cast(Shard!T*) fp.pointer.allocFunction(null, (size_t(1) << shardBits) * Shard!T.sizeof);
	if (shards is null) {
		cast(void) fp.pointer.allocFunction(directory, 0);
		return false;
	}
	foreach (i; 0 .. size_t(1) << shardBits) shards[i] = Shard!T.init;
	interner.pages = directory;
	// Published last: a thread that sees the shards sees the directory too.
	core.atomic.atomicStore(*cast(shared(Shard!T*)*) &interner.shards, cast(shared(Shard!T*)) shards);
	return true;
}

// Takes the next id, first allocating the page that holds it if no thread has yet. `none` on refusal, taking no id.
private uint takeId(T)(ref Interner!T interner) @trusted {
	for (;;) {
		immutable id = core.atomic.atomicLoad(interner.next);
		assert(id < maxIds, "bc.interner: id space exhausted");
		auto page = &interner.pages[id >> pageBits];
		if (core.atomic.atomicLoad(*cast(shared(const(T)[]*)*) page) is null) {
			bc.spinlock.writeLock(interner.setup);
			if (*page is null) {
				immutable bytes = (size_t(1) << pageBits) * (const(T)[]).sizeof;
				auto fresh = cast(const(T)[]*) fp.pointer.allocFunction(null, bytes);
				if (fresh is null) {
					bc.spinlock.writeUnlock(interner.setup);
					return none;
				}
				core.stdc.string.memset(fresh, 0, bytes);
				core.atomic.atomicStore(*cast(shared(const(T)[]*)*) page, cast(shared(const(T)[]*)) fresh);
			}
			bc.spinlock.writeUnlock(interner.setup);
		}
		if (core.atomic.cas(&interner.next, id, id + 1)) return id;
	}
}

/// The id of `items`, interning a copy of them if they are new. Any thread may call it at once with any other.
///
/// Returns `none` if an allocation is refused, having taken no id and left every interned sequence as it was.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// assert(intern(names, "x") == 0 && intern(names, "y") == 1 && intern(names, "x") == 0);
/// ---
uint intern(T)(ref Interner!T interner, const(T)[] items) @trusted {
	if (!ready(interner)) return none;
	immutable hash = fp.hash.murmur(bytesOf(items));
	auto shard = shardOf(interner, hash);
	// Most interning finds what another thread interned, which readers do side by side.
	bc.spinlock.readLock(shard.lock);
	if (shard.table !is null)
		if (auto found = fp.hashtable.find(shard.table, Entry!T(items.ptr, cast(uint) items.length, none))) {
			immutable id = found.id;
			bc.spinlock.readUnlock(shard.lock);
			return id;
		}
	bc.spinlock.readUnlock(shard.lock);
	bc.spinlock.writeLock(shard.lock);
	scope(exit) bc.spinlock.writeUnlock(shard.lock);
	if (shard.table is null) {
		fp.hashtable.Config config;
		config.hashFunction = &hashEntry!T;
		config.equalFunction = &equalEntry!T;
		shard.table = fp.hashtable.create!(Entry!T)(config);
		if (shard.table is null) return none;
	}

	// The copy goes where the shard's next sequence would; it counts as used only once the id is taken.
	immutable chunks = fp.dynarray.length(shard.chunks);
	immutable fresh = chunks == 0 || shard.used + items.length + 1 > fp.pointer.length(shard.chunks[chunks - 1]);
	if (fresh) {
		immutable size = (items.length + 1) * T.sizeof > chunkBytes ? items.length + 1 : chunkBytes / T.sizeof;
		auto chunk = fp.pointer.malloc!T(size);
		if (chunk is null) return none;
		if (!fp.dynarray.pushBack(shard.chunks, chunk)) {
			fp.pointer.free(chunk);
			return none;
		}
		shard.used = 0;
	}
	auto copy = shard.chunks[fp.dynarray.length(shard.chunks) - 1] + shard.used;
	if (items.length) core.stdc.string.memcpy(copy, items.ptr, items.length * T.sizeof);
	copy[items.length] = T.init;
	// One lookup finds the sequence or places it: a placed entry still has no id.
	auto stored = fp.hashtable.insert(shard.table, Entry!T(copy, cast(uint) items.length, none));
	if (stored is null) return none;
	if (stored.id != none) return stored.id;
	immutable id = takeId(interner);
	if (id == none) {
		fp.hashtable.remove(shard.table, *stored);
		return none;
	}
	stored.id = id;
	shard.used += items.length + 1;
	interner.pages[id >> pageBits][id & ((1 << pageBits) - 1)] = copy[0 .. items.length];
	return id;
}

/// Releases everything `interner` holds, leaving it empty and reusable. No other thread may be using it.
///
/// Examples:
/// ---
/// Interner!char names;
/// cast(void) intern(names, "a");
/// free(names);
/// assert(count(names) == 0);
/// ---
void free(T)(ref Interner!T interner) @trusted {
	if (interner.shards !is null) {
		foreach (i; 0 .. size_t(1) << shardBits) {
			auto shard = &interner.shards[i];
			foreach (chunk; fp.dynarray.slice(shard.chunks)) fp.pointer.free(chunk);
			fp.dynarray.free(shard.chunks);
			fp.hashtable.free(shard.table);
		}
		cast(void) fp.pointer.allocFunction(interner.shards, 0);
	}
	if (interner.pages !is null) {
		foreach (i; 0 .. size_t(1) << directoryBits)
			if (interner.pages[i] !is null) cast(void) fp.pointer.allocFunction(cast(void*) interner.pages[i], 0);
		cast(void) fp.pointer.allocFunction(interner.pages, 0);
	}
	interner = Interner!T.init;
}


version(unittest) {
	static import bc.threadpool;
	static import fp.testing;

	private struct Interning {
		Interner!ulong* keys;
		ulong from;
		uint[512] ids;
	}

	private void internMany(void* arg) @trusted {
		auto job = cast(Interning*) arg;
		foreach (i, ref id; job.ids) {
			ulong[2] key = [(job.from + i) % 700, 0];
			id = intern(*job.keys, key[]);
		}
	}
}

unittest { // threads interning overlapping sequences agree on every id, and ids stay dense
	Interner!ulong keys;
	scope(exit) free(keys);
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	Interning[8] jobs;
	bc.threadpool.Job[8] work;
	foreach (i, ref job; jobs) {
		job.keys = &keys;
		job.from = i * 100;
		work[i] = bc.threadpool.Job(&internMany, &job);
	}
	assert(bc.threadpool.run(pool, work[]));
	assert(count(keys) == 700);
	foreach (ref job; jobs)
		foreach (i, id; job.ids) {
			assert(id != none && content(keys, id)[0] == (job.from + i) % 700);
			ulong[2] key = [(job.from + i) % 700, 0];
			assert(find(keys, key[]) == id);
		}
}

unittest { // long and empty sequences; a refused allocation takes no id and leaves the table as it was
	Interner!char names;
	scope(exit) free(names);
	// Longer than a chunk, yet within WASI's 64 KiB default stack.
	char[10_000] long_ = 'x';
	immutable big = intern(names, long_[]), empty = intern(names, "");
	assert(content(names, big) == long_[] && content(names, empty).length == 0 && intern(names, "") == empty);

	Interner!char rationed;
	scope(exit) free(rationed);
	foreach (i; 0 .. 50) {
		char[8] name;
		foreach (k; 0 .. 8) name[k] = cast(char) ('a' + (i >> (k % 4)) % 26);
		name[7] = cast(char) ('0' + i % 10);
		for (size_t budget = 0;; ++budget) {
			immutable before = count(rationed);
			auto previous = fp.testing.beginRationedAllocator(budget);
			immutable id = intern(rationed, name[]);
			fp.testing.endRationedAllocator(previous);
			if (id != none) {
				assert(content(rationed, id) == name[]);
				break;
			}
			assert(count(rationed) == before && find(rationed, name[]) == none);
		}
	}
}
