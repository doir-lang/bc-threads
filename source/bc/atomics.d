/// Atomic access to plain fields: `asShared` views a field declared without `shared` as `shared`, which `core.atomic` requires, so a struct can stay plain data, copied and zeroed like any other, while threads read and write some of its fields atomically.
///
/// Examples:
/// ---
/// static import core.atomic;
/// struct Counters { size_t hits; }
/// Counters c;
/// core.atomic.atomicOp!"+="(asShared(c.hits), 1);
/// assert(core.atomic.atomicLoad(asShared(c.hits)) == 1);
/// ---
module bc.atomics;

@nogc nothrow:


// wrapper: names the shared view core.atomic needs of a field declared without `shared`
/// `value` viewed as `shared`, for `core.atomic.atomicLoad`, `atomicStore`, `atomicOp` and `cas`. Every access to the field while other threads may touch it must go through such a view; a plain read or write races. A `const` field gives a `shared(const)` view, which only loads.
///
/// Examples:
/// ---
/// static import core.atomic;
/// bool flag;
/// core.atomic.atomicStore(asShared(flag), true);
/// const bool* view = &flag;
/// assert(core.atomic.atomicLoad(asShared(*view)));
/// ---
ref shared(T) asShared(T)(return ref T value) @trusted {
	return *cast(shared(T)*) &value;
}


unittest { // views of different widths and qualifiers act on the field itself
	static import core.atomic;
	static struct Plain { ubyte small; ulong wide; void* pointer; }
	Plain p;
	core.atomic.atomicStore(asShared(p.small), cast(ubyte) 7);
	assert(core.atomic.cas(&asShared(p.wide), 0UL, 9UL) && p.wide == 9 && p.small == 7);
	int target;
	core.atomic.atomicStore(asShared(p.pointer), cast(shared(void*)) &target);
	assert(p.pointer is &target);
	const Plain frozen = p;
	assert(core.atomic.atomicLoad(asShared(frozen.wide)) == 9);
}
