/// Go-style channels between threads: a fixed ring buffer, or with `dynamicExtent` an unbounded queue.
module bc.channel;

static import bc.mutex;
static import bc.platform;
static import bc.semaphore;
static import fp.dynarray;
static import fp.pointer;

import core.atomic : atomicLoad, atomicOp, atomicStore, pause;
import std.traits : hasElaborateAssign, hasElaborateCopyConstructor, hasElaborateDestructor;
import std.typecons : Nullable, nullable;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);

/// Whether `Channel!T` accepts `T`: its buffer slots start uninitialized, so a type whose assignment, copy or destruction runs code would run it on garbage.
///
/// Examples:
/// ---
/// static struct Owner { ~this() @nogc nothrow {} }
/// static assert(isChannelable!int);
/// static assert(!isChannelable!Owner);
/// ---
enum bool isChannelable(T) = !hasElaborateAssign!T && !hasElaborateCopyConstructor!T && !hasElaborateDestructor!T;

/// Passed to `create` as the capacity, makes the channel unbounded, so `send` never waits.
enum size_t dynamicExtent = size_t.max;

// Takes `buffer[head]` and advances `head`, shifting the rest down only once at least half is consumed, so each take costs amortized O(1).
private T takeFront(T)(ref T* buffer, ref size_t head) @trusted {
	T value = buffer[head];
	buffer[head++] = T.init;
	if(head * 2 >= fp.dynarray.length(buffer)) {
		cast(void) fp.dynarray.deleteRange(buffer, 0, head);
		head = 0;
	}
	return value;
}


static if(bc.platform.threadingSupported) {

	/// A channel of `T` values, used through the pointer `create` returns. Its fields belong to the implementation. `T` must satisfy `isChannelable`.
	///
	/// Examples:
	/// ---
	/// Channel!int* ch = bc.channel.create!int(2);
	/// assert(send(ch, 1));
	/// assert(receive(ch).get == 1);
	/// free(ch);
	/// ---
	struct Channel(T) if(isChannelable!T) {
		bc.semaphore.Semaphore* itemAvailable;
		bc.semaphore.Semaphore* spaceAvailable;

		T* buffer = null;
		size_t capacity = 0;
		size_t head = 0;
		size_t count = 0;
		bc.mutex.Mutex* lock;

		shared bool closed = false;

		// Threads blocked, or about to block, on each semaphore, guarded by `lock`. Whoever posts takes one off, so no post outlives its waiter.
		size_t sendersWaiting = 0;
		size_t receiversWaiting = 0;

		// Threads inside `send` or `receive`, so `free` can wait for them to leave before destroying what they read.
		shared ptrdiff_t users = 0;
	}

	private void acquire(T)(Channel!T* ch) @trusted { bc.mutex.writeLock(ch.lock); }
	private void release(T)(Channel!T* ch) @trusted { bc.mutex.writeUnlock(ch.lock); }

	private void freeParts(T)(Channel!T* ch) @trusted {
		bc.semaphore.free(ch.itemAvailable);
		bc.semaphore.free(ch.spaceAvailable);
		bc.mutex.free(ch.lock);
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}


	/// The capacity `ch` was created with.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(dynamicExtent);
	/// assert(capacity(ch) == dynamicExtent);
	/// free(ch);
	/// ---
	size_t capacity(T)(const Channel!T* ch) { return ch.capacity; }

	/// How many values `ch` holds.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(4);
	/// assert(send(ch, 1));
	/// assert(length(ch) == 1);
	/// free(ch);
	/// ---
	size_t length(T)(Channel!T* ch) @trusted {
		acquire(ch);
		immutable n = ch.count;
		release(ch);
		return n;
	}

	/// Whether `close` has been called on `ch`.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(1);
	/// close(ch);
	/// assert(isClosed(ch));
	/// free(ch);
	/// ---
	bool isClosed(T)(const Channel!T* ch) @trusted { return atomicLoad(ch.closed); }


	/// Creates an open, empty channel holding up to `capacity` values, which must be above zero, or any number of them with `dynamicExtent`. Several `bc` modules define `create`, so call it fully qualified, as `bc.channel.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns null, having freed what it allocated, if allocation or creating its semaphores or lock fails.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(4);
	/// assert(ch !is null);
	/// assert(capacity(ch) == 4);
	/// free(ch);
	/// ---
	Channel!T* create(T)(size_t capacity) @trusted {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		if(ch is null) return null;
		*ch = Channel!T.init;
		ch.capacity = capacity;
		immutable bounded = capacity != dynamicExtent;
		// A dynamic channel never fills, so no sender can ever wait for room.
		if(bounded) {
			ch.buffer = fp.dynarray.create!T(capacity);
			ch.spaceAvailable = bc.semaphore.create();
		}

		// Both counts start at zero: every waiter rechecks the buffer under the lock, so a semaphore only needs to wake it.
		ch.itemAvailable = bc.semaphore.create();
		ch.lock = bc.mutex.create();
		if((bounded && (ch.buffer is null || ch.spaceAvailable is null)) || ch.itemAvailable is null || ch.lock is null) {
			freeParts(ch);
			return null;
		}
		return ch;
	}


	/// Appends `value` to `ch`, first waiting for room if `ch` is full. Without threads, `ch` never fills, so `send` never waits.
	///
	/// Returns false, leaving `ch` unchanged, if `ch` is closed before `value` fits, or if `ch` is unbounded and its buffer cannot grow.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(1);
	/// assert(send(ch, 1));
	/// close(ch);
	/// assert(!send(ch, 2));
	/// free(ch);
	/// ---
	bool send(T)(Channel!T* ch, T value) @trusted {
		immutable dynamic = ch.capacity == dynamicExtent;
		atomicOp!"+="(ch.users, 1);
		bool sent = false;
		while(true) {
			acquire(ch);
			if(atomicLoad(ch.closed)) {
				release(ch);
				break;
			}
			if(dynamic || ch.count < ch.capacity) {
				if(dynamic && !fp.dynarray.pushBack(ch.buffer, value)) {
					release(ch);
					break;
				}
				if(!dynamic) ch.buffer[(ch.head + ch.count) % ch.capacity] = value;
				ch.count++;
				immutable wake = ch.receiversWaiting > 0;
				if(wake) ch.receiversWaiting--;
				release(ch);
				if(wake) bc.semaphore.post(ch.itemAvailable);
				sent = true;
				break;
			}
			ch.sendersWaiting++;
			release(ch);
			bc.semaphore.wait(ch.spaceAvailable);
		}
		atomicOp!"-="(ch.users, 1);
		return sent;
	}

	/// Removes and returns the oldest value in `ch`, first waiting for one if `ch` is empty.
	///
	/// Returns an empty `Nullable` once `ch` is closed and empty. Without threads an empty `ch` returns an empty `Nullable` at once, since nothing could fill it while `receive` waited.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(2);
	/// assert(send(ch, 7));
	/// close(ch);
	/// assert(receive(ch).get == 7);
	/// assert(receive(ch).isNull);
	/// free(ch);
	/// ---
	Nullable!T receive(T)(Channel!T* ch) @trusted {
		immutable dynamic = ch.capacity == dynamicExtent;
		atomicOp!"+="(ch.users, 1);
		Nullable!T value = Nullable!T.init;
		while(true) {
			acquire(ch);
			if(ch.count > 0) {
				T taken;
				if(dynamic) taken = takeFront(ch.buffer, ch.head);
				else {
					taken = ch.buffer[ch.head];
					// Leaving the copy would keep whatever it references alive until a later send overwrites the slot.
					ch.buffer[ch.head] = T.init;
					ch.head = (ch.head + 1) % ch.capacity;
				}
				ch.count--;
				immutable wake = ch.sendersWaiting > 0;
				if(wake) ch.sendersWaiting--;
				release(ch);
				if(wake) bc.semaphore.post(ch.spaceAvailable);
				value = nullable(taken);
				break;
			}
			if(atomicLoad(ch.closed)) { release(ch); break; }
			ch.receiversWaiting++;
			release(ch);
			bc.semaphore.wait(ch.itemAvailable);
		}
		atomicOp!"-="(ch.users, 1);
		return value;
	}


	/// Closes `ch`: later sends fail, and threads waiting in `send` or `receive` on it wake. Values already in `ch` can still be received.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(1);
	/// close(ch);
	/// assert(!send(ch, 1));
	/// free(ch);
	/// ---
	void close(T)(Channel!T* ch) @trusted {
		acquire(ch);
		atomicStore(ch.closed, true);
		immutable senders = ch.sendersWaiting;
		immutable receivers = ch.receiversWaiting;
		ch.sendersWaiting = ch.receiversWaiting = 0;
		release(ch);
		foreach(_; 0 .. senders) bc.semaphore.post(ch.spaceAvailable);
		foreach(_; 0 .. receivers) bc.semaphore.post(ch.itemAvailable);
	}

	/// Closes and frees `ch`; does nothing if `ch` is null. Threads blocked in `send` or `receive` are woken and waited for before anything is destroyed, so freeing a channel others are blocked on is safe, though starting a new `send` or `receive` on it after is not. Freeing `ch` twice is undefined.
	///
	/// Examples:
	/// ---
	/// auto ch = bc.channel.create!int(1);
	/// free(ch);
	/// free!int(null);
	/// ---
	void free(T)(Channel!T* ch) @trusted {
		if(ch is null) return;
		close(ch);
		// A woken waiter still reads the channel, so it must leave before any part of it is destroyed.
		while(atomicLoad(ch.users) > 0) pause();
		freeParts(ch);
	}

} else {

	// Without threads nothing could fill an empty channel or drain a full one, so every capacity behaves as `dynamicExtent`.
	struct Channel(T) if(isChannelable!T) {
		T* buffer = null;
		size_t head = 0;
		size_t capacity = 0;
		bool closed = false;
	}


	size_t capacity(T)(const Channel!T* ch) { return ch.capacity; }
	size_t length(T)(Channel!T* ch) @trusted { return fp.dynarray.length(ch.buffer) - ch.head; }
	bool isClosed(T)(const Channel!T* ch) { return ch.closed; }


	Channel!T* create(T)(size_t capacity) @trusted {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		if(ch is null) return null;
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent && fp.dynarray.reserve(ch.buffer, capacity) is null) {
			fp.pointer.free(ch);
			return null;
		}
		return ch;
	}


	bool send(T)(Channel!T* ch, T value) @trusted {
		if(ch.closed) return false;
		return fp.dynarray.pushBack(ch.buffer, value);
	}

	Nullable!T receive(T)(Channel!T* ch) @trusted {
		if(length(ch) == 0) return Nullable!T.init;
		return nullable(takeFront(ch.buffer, ch.head));
	}


	void close(T)(Channel!T* ch) { ch.closed = true; }

	void free(T)(Channel!T* ch) @trusted {
		if(ch is null) return;
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}
}


unittest {
	// Fails each acquisition in turn: channel, buffer, then with threads each semaphore and its OS object, the lock, and any rwlock.
	static if(!bc.platform.threadingSupported) enum acquisitions = 2;
	else version(PthreadBackend) enum acquisitions = 8;
	else enum acquisitions = 7;
	debug foreach(i; 0 .. acquisitions) {
		bc.platform.failAfter(i);
		assert(create!int(1) is null);
	}
	free!int(null);
	static struct Owner { ~this() @nogc nothrow {} }
	static assert(!__traits(compiles, Channel!Owner) && !__traits(compiles, create!Owner(1)));

	auto queue = create!int(dynamicExtent);
	assert(queue !is null);
	scope(exit) free(queue);
	assert(capacity(queue) == dynamicExtent);
	debug {
		bc.platform.failAfter(0);
		assert(!send(queue, 1));
		assert(length(queue) == 0);
	}
	// Receives shift the buffer down twice here, after the second and third, so values must keep their order across both.
	foreach(i; 0 .. 4) assert(send(queue, i + 1));
	// The first receive does not shift, so the slot it took must already be cleared.
	assert(receive(queue).get == 1 && queue.buffer[0] == int.init);
	foreach(i; 1 .. 3) assert(receive(queue).get == i + 1);
	assert(send(queue, 5) && length(queue) == 2);
	close(queue);
	assert(isClosed(queue) && !send(queue, 6));
	assert(receive(queue).get == 4 && receive(queue).get == 5);
	assert(receive(queue).isNull);
	// Nothing waited, so no post may be left to make a later `receive` spin through stale wakeups.
	static if(bc.platform.threadingSupported) version(linux) assert(bc.semaphore.value(queue.itemAvailable) == 0);

	static if(bc.platform.threadingSupported) {
		static import bc.thread;

		static void sendTwo(Channel!int* ch, bool* ok) @nogc nothrow { *ok = send(ch, 2); }
		static void receiveOne(Channel!int* ch, bool* ok) @nogc nothrow { *ok = !receive(ch).isNull; }
		static size_t blocked(Channel!int* ch, bool senders) @nogc nothrow {
			acquire(ch);
			immutable n = senders ? ch.sendersWaiting : ch.receiversWaiting;
			release(ch);
			return n;
		}

		auto ch = create!int(1);
		assert(ch !is null);
		scope(exit) free(ch);
		assert(send(ch, 1));

		// The sender waits on the full channel until a receive makes room; the receiver waits on the empty one until `close` wakes it.
		bool sent = false, received = true;
		auto t = bc.thread.create(&sendTwo, ch, &sent);
		assert(!t.isNull);
		while(blocked(ch, true) == 0) {}
		assert(receive(ch).get == 1);
		bc.thread.join(t.get);
		assert(sent && receive(ch).get == 2);

		t = bc.thread.create(&receiveOne, ch, &received);
		assert(!t.isNull);
		while(blocked(ch, false) == 0) {}
		close(ch);
		bc.thread.join(t.get);
		assert(!received);

		auto full = create!int(2);
		assert(full !is null);
		scope(exit) free(full);
		foreach(i; 0 .. 2) assert(send(full, i + 1));
		foreach(i; 0 .. 2) assert(receive(full).get == i + 1);
		assert(full.buffer[0] == int.init && full.buffer[1] == int.init);
		version(linux) assert(bc.semaphore.value(full.itemAvailable) == 0 && bc.semaphore.value(full.spaceAvailable) == 0);

		// `free` wakes threads blocked in `receive` and waits for them to return before destroying what they read.
		static shared size_t left;
		static void receiveThenMark(Channel!int* ch) @nogc nothrow { receive(ch); atomicOp!"+="(left, 1); }
		auto closing = create!int(1);
		assert(closing !is null);
		enum waiters = 16;
		Nullable!(bc.thread.Thread)[waiters] blockedThreads;
		foreach(ref waiter; blockedThreads) {
			waiter = bc.thread.create(&receiveThenMark, closing);
			assert(!waiter.isNull);
		}
		// Every receiver must be inside `receive` before `free`, since entering it afterwards would touch freed memory.
		while(blocked(closing, false) < waiters) {}
		free(closing);
		assert(atomicLoad(left) == waiters);
		foreach(ref waiter; blockedThreads) bc.thread.join(waiter.get);
	}
}
