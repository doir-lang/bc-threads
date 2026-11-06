/// Interning tables any thread may use at once: an `Interner!T` gives each distinct sequence of `T` a dense id, from 0, and gives back the sequence for an id without taking a lock, so the jobs of a pool can intern names side by side.
///
/// Each copy is followed by a `T.init`, so an interned `char` sequence is a C string too. The table is split into shards by hash, each behind a `bc.spinlock`, so interning on different shards never waits. Sequences are copied into chunks a shard never moves, and ids find them through pages that are never moved either, so a lookup by id reads without locking: an id reaches another thread only after the interning that made it has released its shard.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// immutable a = intern(names, "a"), b = intern(names, "b");
/// assert(a != b && intern(names, "a") == a && items(names, b) == "b");
/// assert(find(names, "c") == notInterned && count(names) == 2);
/// ---
module bc.interner;

static import core.atomic;
static import core.stdc.string;

static import fp.dynarray;
static import fp.hash;
static import fp.hashtable;
static import fp.pointer;

static import bc.atomics;
static import bc.spinlock;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// What `find` gives for a sequence never interned: no id.
enum uint notInterned = uint.max;

/// What `intern` gives when an allocation is refused: no id.
enum uint refused = uint.max - 1;

private enum size_t shardBits = 6;
private enum size_t pageBits = 14;
private enum size_t directoryBits = 14;
// Ids are below this, so a page and a slot in it are found by shifting, and `notInterned` and `refused` are never ids.
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

/// A table interning sequences of `T`, which must be plain bytes, handing out ids of type `Id`: a `uint`, or a struct whose one field is a `uint`, so a caller's ids cannot be confused with other numbers. Its `.init` is empty and ready; release it with `free`, from one thread, once no other uses it.
///
/// Examples:
/// ---
/// Interner!ulong keys;
/// scope(exit) free(keys);
/// ulong[2] key = [5, 0];
/// assert(intern(keys, key[]) == find(keys, key[]));
///
/// static struct Name { uint value = uint.max; }
/// Interner!(char, Name) names;
/// scope(exit) free(names);
/// Name x = intern(names, "x");
/// assert(x.value == 0 && find(names, "y") == Name(notInterned));
/// ---
struct Interner(T, Id = uint) if (isId!Id) {
	static assert(maxIds <= refused, "bc.interner: ids would reach the sentinels");
	private Shard!T* shards = null;
	private const(T)[]** pages = null; // the directory: ids `i << pageBits` up are in page `i`
	private shared uint next = 0;
	private bc.spinlock.SpinLock setup; // held while the shards, the directory or a page are first allocated
}


/// Whether `Id` can be an interner's id: a `uint`, or a struct whose one field is a `uint`.
///
/// Examples:
/// ---
/// static struct Name { uint value; }
/// static assert(isId!uint && isId!Name && !isId!ulong);
/// ---
template isId(Id) {
	static if (is(Id == struct)) enum bool isId = Id.tupleof.length == 1 && is(typeof(Id.tupleof[0]) == uint);
	else enum bool isId = is(Id == uint);
}

private Id toId(Id)(uint raw) {
	static if (is(Id == uint)) return raw;
	else {
		Id id;
		id.tupleof[0] = raw;
		return id;
	}
}

private uint rawOf(Id)(Id id) {
	static if (is(Id == uint)) return id;
	else return id.tupleof[0];
}


// --- table entries -----------------------------------------------------------

private const(ubyte)[] bytesOf(T)(const(T)[] items) @trusted {
	return (cast(const(ubyte)*) items.ptr)[0 .. items.length * T.sizeof];
}

private size_t hashEntry(T)(inout(ubyte)[] bytes) @trusted {
	auto e = cast(const(Entry!T)*) bytes.ptr;
	return cast(size_t) fp.hash.hashBytes(bytesOf(e.items[0 .. e.length]));
}

private bool equalEntry(T)(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	auto x = cast(const(Entry!T)*) a.ptr, y = cast(const(Entry!T)*) b.ptr;
	return x.length == y.length && core.stdc.string.memcmp(x.items, y.items, x.length * T.sizeof) == 0;
}


// --- queries -----------------------------------------------------------------

// wrapper: reads a private counter atomically
/// The number of ids handed out.
///
/// Examples:
/// ---
/// Interner!char names;
/// assert(count(names) == 0);
/// ---
size_t count(T, Id)(ref const Interner!(T, Id) interner) @trusted {
	return core.atomic.atomicLoad((cast(Interner!(T, Id)*) &interner).next);
}

/// The sequence interned as `id`, which must have come from `intern` on `interner`. It takes no lock.
///
/// Examples:
/// ---
/// Interner!ulong keys;
/// scope(exit) free(keys);
/// ulong[2] key = [3, 0];
/// assert(items(keys, intern(keys, key[])) == key[]);
/// ---
const(T)[] items(T, Id)(ref const Interner!(T, Id) interner, Id id) @trusted {
	immutable raw = rawOf(id);
	assert(raw < count(interner), "bc.interner: no such id");
	return interner.pages[raw >> pageBits][raw & ((1 << pageBits) - 1)];
}

// The shard `hash` selects, from its top bits: a shard's table indexes by its low ones, which a shard chosen from them would cluster.
private Shard!T* shardOf(T, Id)(ref Interner!(T, Id) interner, ulong hash) {
	return &interner.shards[hash >> (64 - shardBits)];
}

/// The id of `items`, or `notInterned` if they were never interned.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// assert(find(names, "a") == notInterned);
/// ---
Id find(T, Id)(ref Interner!(T, Id) interner, const(T)[] items) @trusted {
	if (core.atomic.atomicLoad(bc.atomics.asShared(interner.shards)) is null) return toId!Id(notInterned);
	auto shard = shardOf(interner, fp.hash.hashBytes(bytesOf(items)));
	bc.spinlock.lockForReading(shard.lock);
	scope(exit) bc.spinlock.unlockForReading(shard.lock);
	if (shard.table is null) return toId!Id(notInterned);
	auto found = fp.hashtable.find(shard.table, Entry!T(items.ptr, cast(uint) items.length, notInterned));
	return toId!Id(found is null ? notInterned : found.id);
}


// --- creation and freeing ----------------------------------------------------

// Allocates the shards and the directory if no thread has yet. False on refusal.
private bool ready(T, Id)(ref Interner!(T, Id) interner) @trusted {
	if (core.atomic.atomicLoad(bc.atomics.asShared(interner.shards)) !is null) return true;
	bc.spinlock.lockForWriting(interner.setup);
	scope(exit) bc.spinlock.unlockForWriting(interner.setup);
	if (interner.shards !is null) return true;
	auto directory = cast(const(T)[]**) fp.pointer.allocator(null, (size_t(1) << directoryBits) * (const(T)[]*).sizeof);
	if (directory is null) return false;
	core.stdc.string.memset(directory, 0, (size_t(1) << directoryBits) * (const(T)[]*).sizeof);
	auto shards = cast(Shard!T*) fp.pointer.allocator(null, (size_t(1) << shardBits) * Shard!T.sizeof);
	if (shards is null) {
		cast(void) fp.pointer.allocator(directory, 0);
		return false;
	}
	foreach (i; 0 .. size_t(1) << shardBits) shards[i] = Shard!T.init;
	interner.pages = directory;
	// Published last: a thread that sees the shards sees the directory too.
	core.atomic.atomicStore(bc.atomics.asShared(interner.shards), cast(shared(Shard!T*)) shards);
	return true;
}

// Takes the next id, first allocating the page that holds it if no thread has yet. `refused` on refusal, taking no id.
private uint takeId(T, Id)(ref Interner!(T, Id) interner) @trusted {
	for (;;) {
		immutable id = core.atomic.atomicLoad(interner.next);
		assert(id < maxIds, "bc.interner: id space exhausted");
		auto page = &interner.pages[id >> pageBits];
		if (core.atomic.atomicLoad(bc.atomics.asShared(*page)) is null) {
			bc.spinlock.lockForWriting(interner.setup);
			if (*page is null) {
				immutable bytes = (size_t(1) << pageBits) * (const(T)[]).sizeof;
				auto fresh = cast(const(T)[]*) fp.pointer.allocator(null, bytes);
				if (fresh is null) {
					bc.spinlock.unlockForWriting(interner.setup);
					return refused;
				}
				core.stdc.string.memset(fresh, 0, bytes);
				core.atomic.atomicStore(bc.atomics.asShared(*page), cast(shared(const(T)[]*)) fresh);
			}
			bc.spinlock.unlockForWriting(interner.setup);
		}
		if (core.atomic.cas(&interner.next, id, id + 1)) return id;
	}
}

// wrapper: converts the plain id internRaw gives on every path to Id once
/// The id of `items`, interning a copy of them if they are new. Any thread may call it at once with any other.
///
/// Returns `refused` if an allocation is refused, having taken no id and left every interned sequence as it was.
///
/// Examples:
/// ---
/// Interner!char names;
/// scope(exit) free(names);
/// assert(intern(names, "x") == 0 && intern(names, "y") == 1 && intern(names, "x") == 0);
/// ---
Id intern(T, Id)(ref Interner!(T, Id) interner, const(T)[] items) @trusted {
	return toId!Id(internRaw(interner, items));
}

// `intern`, giving the id as a plain number.
private uint internRaw(T, Id)(ref Interner!(T, Id) interner, const(T)[] items) @trusted {
	if (!ready(interner)) return refused;
	immutable hash = fp.hash.hashBytes(bytesOf(items));
	auto shard = shardOf(interner, hash);
	// Most interning finds what another thread interned, which readers do side by side.
	bc.spinlock.lockForReading(shard.lock);
	if (shard.table !is null)
		if (auto found = fp.hashtable.find(shard.table, Entry!T(items.ptr, cast(uint) items.length, notInterned))) {
			immutable id = found.id;
			bc.spinlock.unlockForReading(shard.lock);
			return id;
		}
	bc.spinlock.unlockForReading(shard.lock);
	bc.spinlock.lockForWriting(shard.lock);
	scope(exit) bc.spinlock.unlockForWriting(shard.lock);
	if (shard.table is null) {
		fp.hashtable.Config config;
		config.hashFunction = &hashEntry!T;
		config.equalFunction = &equalEntry!T;
		shard.table = fp.hashtable.create!(Entry!T)(config);
		if (shard.table is null) return refused;
	}

	// The copy goes where the shard's next sequence would; it counts as used only once the id is taken.
	immutable chunks = fp.dynarray.length(shard.chunks);
	immutable fresh = chunks == 0 || shard.used + items.length + 1 > fp.pointer.length(shard.chunks[chunks - 1]);
	if (fresh) {
		immutable size = (items.length + 1) * T.sizeof > chunkBytes ? items.length + 1 : chunkBytes / T.sizeof;
		auto chunk = fp.pointer.allocate!T(size);
		if (chunk is null) return refused;
		if (!fp.dynarray.pushBack(shard.chunks, chunk)) {
			fp.pointer.free(chunk);
			return refused;
		}
		shard.used = 0;
	}
	auto copy = shard.chunks[fp.dynarray.length(shard.chunks) - 1] + shard.used;
	if (items.length) core.stdc.string.memcpy(copy, items.ptr, items.length * T.sizeof);
	copy[items.length] = T.init;
	// One lookup finds the sequence or places it: a placed entry still has no id.
	auto stored = fp.hashtable.insert(shard.table, Entry!T(copy, cast(uint) items.length, notInterned));
	if (stored is null) return refused;
	if (stored.id != notInterned) return stored.id;
	immutable id = takeId(interner);
	if (id == refused) {
		fp.hashtable.remove(shard.table, *stored);
		return refused;
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
void free(T, Id)(ref Interner!(T, Id) interner) @trusted {
	if (interner.shards !is null) {
		foreach (i; 0 .. size_t(1) << shardBits) {
			auto shard = &interner.shards[i];
			foreach (chunk; fp.dynarray.slice(shard.chunks)) fp.pointer.free(chunk);
			fp.dynarray.free(shard.chunks);
			fp.hashtable.free(shard.table);
		}
		cast(void) fp.pointer.allocator(interner.shards, 0);
	}
	if (interner.pages !is null) {
		foreach (i; 0 .. size_t(1) << directoryBits)
			if (interner.pages[i] !is null) cast(void) fp.pointer.allocator(cast(void*) interner.pages[i], 0);
		cast(void) fp.pointer.allocator(interner.pages, 0);
	}
	interner = Interner!(T, Id).init;
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
			assert(id != refused && items(keys, id)[0] == (job.from + i) % 700);
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
	assert(items(names, big) == long_[] && items(names, empty).length == 0 && intern(names, "") == empty);

	// A fresh table each attempt, so every allocation the first interning makes, the id's page included, is refused in turn.
	for (size_t budget = 0;; ++budget) {
		Interner!char fresh;
		scope(exit) free(fresh);
		auto previous = fp.testing.limitAllocations(budget);
		immutable id = intern(fresh, "a");
		fp.testing.restoreAllocator(previous);
		if (id != refused) {
			assert(id == 0 && items(fresh, id) == "a");
			break;
		}
		assert(count(fresh) == 0 && find(fresh, "a") == notInterned && intern(fresh, "a") == 0);
	}

	Interner!char rationed;
	scope(exit) free(rationed);
	foreach (i; 0 .. 50) {
		char[8] name;
		foreach (k; 0 .. 8) name[k] = cast(char) ('a' + (i >> (k % 4)) % 26);
		name[7] = cast(char) ('0' + i % 10);
		for (size_t budget = 0;; ++budget) {
			immutable before = count(rationed);
			auto previous = fp.testing.limitAllocations(budget);
			immutable id = intern(rationed, name[]);
			fp.testing.restoreAllocator(previous);
			if (id != refused) {
				assert(items(rationed, id) == name[]);
				break;
			}
			assert(count(rationed) == before && find(rationed, name[]) == notInterned);
		}
	}
}
