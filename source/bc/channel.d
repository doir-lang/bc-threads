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

mixin(bc.platform.backendSelection);

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
		cast(void) fp.dynarray.removeRange(buffer, 0, head);
		head = 0;
	}
	return value;
}


static if(bc.platform.threadingSupported) {

	/// A channel of `T` values, used through the pointer `create` returns. Its fields belong to the implementation. `T` must satisfy `isChannelable`.
	///
	/// Examples:
	/// ---
	/// Channel!int* channel = bc.channel.create!int(2);
	/// assert(send(channel, 1));
	/// assert(receive(channel).get == 1);
	/// free(channel);
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


	private void freeParts(T)(Channel!T* channel) @trusted {
		bc.semaphore.free(channel.itemAvailable);
		bc.semaphore.free(channel.spaceAvailable);
		bc.mutex.free(channel.lock);
		fp.dynarray.free(channel.buffer);
		fp.pointer.free(channel);
	}


	// wrapper: reads a field of an opaque channel
	/// The capacity `channel` was created with.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(dynamicExtent);
	/// assert(capacity(channel) == dynamicExtent);
	/// free(channel);
	/// ---
	size_t capacity(T)(const Channel!T* channel) { return channel.capacity; }

	/// How many values `channel` holds.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(4);
	/// assert(send(channel, 1));
	/// assert(length(channel) == 1);
	/// free(channel);
	/// ---
	size_t length(T)(Channel!T* channel) @trusted {
		bc.mutex.lockForWriting(channel.lock);
		immutable n = channel.count;
		bc.mutex.unlockForWriting(channel.lock);
		return n;
	}

	// wrapper: reads a field of an opaque channel
	/// Whether `close` has been called on `channel`.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(1);
	/// close(channel);
	/// assert(isClosed(channel));
	/// free(channel);
	/// ---
	bool isClosed(T)(const Channel!T* channel) @trusted { return atomicLoad(channel.closed); }


	/// Creates an open, empty channel holding up to `capacity` values, which must be above zero, or any number of them with `dynamicExtent`. Several `bc` modules define `create`, so call it fully qualified, as `bc.channel.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns null, having freed what it allocated, if allocation or creating its semaphores or lock fails.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(4);
	/// assert(channel !is null);
	/// assert(capacity(channel) == 4);
	/// free(channel);
	/// ---
	Channel!T* create(T)(size_t capacity) @trusted {
		assert(capacity > 0);
		auto channel = fp.pointer.allocate!(Channel!T)(1);
		if(channel is null) return null;
		*channel = Channel!T.init;
		channel.capacity = capacity;
		immutable bounded = capacity != dynamicExtent;
		// A dynamic channel never fills, so no sender can ever wait for room.
		if(bounded) {
			channel.buffer = fp.dynarray.create!T(capacity);
			channel.spaceAvailable = bc.semaphore.create();
		}

		// Both counts start at zero: every waiter rechecks the buffer under the lock, so a semaphore only needs to wake it.
		channel.itemAvailable = bc.semaphore.create();
		channel.lock = bc.mutex.create();
		if((bounded && (channel.buffer is null || channel.spaceAvailable is null)) || channel.itemAvailable is null || channel.lock is null) {
			freeParts(channel);
			return null;
		}
		return channel;
	}


	/// Appends `value` to `channel`, first waiting for room if `channel` is full. Without threads, `channel` never fills, so `send` never waits.
	///
	/// Returns false, leaving `channel` unchanged, if `channel` is closed before `value` fits, or if `channel` is unbounded and its buffer cannot grow.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(1);
	/// assert(send(channel, 1));
	/// close(channel);
	/// assert(!send(channel, 2));
	/// free(channel);
	/// ---
	bool send(T)(Channel!T* channel, T value) @trusted {
		immutable dynamic = channel.capacity == dynamicExtent;
		atomicOp!"+="(channel.users, 1);
		bool sent = false;
		while(true) {
			bc.mutex.lockForWriting(channel.lock);
			if(atomicLoad(channel.closed)) {
				bc.mutex.unlockForWriting(channel.lock);
				break;
			}
			if(dynamic || channel.count < channel.capacity) {
				if(dynamic && !fp.dynarray.pushBack(channel.buffer, value)) {
					bc.mutex.unlockForWriting(channel.lock);
					break;
				}
				if(!dynamic) channel.buffer[(channel.head + channel.count) % channel.capacity] = value;
				channel.count++;
				immutable wake = channel.receiversWaiting > 0;
				if(wake) channel.receiversWaiting--;
				bc.mutex.unlockForWriting(channel.lock);
				if(wake) bc.semaphore.post(channel.itemAvailable);
				sent = true;
				break;
			}
			channel.sendersWaiting++;
			bc.mutex.unlockForWriting(channel.lock);
			bc.semaphore.wait(channel.spaceAvailable);
		}
		atomicOp!"-="(channel.users, 1);
		return sent;
	}

	/// Removes and returns the oldest value in `channel`, first waiting for one if `channel` is empty.
	///
	/// Returns an empty `Nullable` once `channel` is closed and empty. Without threads an empty `channel` returns an empty `Nullable` at once, since nothing could fill it while `receive` waited.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(2);
	/// assert(send(channel, 7));
	/// close(channel);
	/// assert(receive(channel).get == 7);
	/// assert(receive(channel).isNull);
	/// free(channel);
	/// ---
	Nullable!T receive(T)(Channel!T* channel) @trusted {
		immutable dynamic = channel.capacity == dynamicExtent;
		atomicOp!"+="(channel.users, 1);
		Nullable!T value = Nullable!T.init;
		while(true) {
			bc.mutex.lockForWriting(channel.lock);
			if(channel.count > 0) {
				T taken;
				if(dynamic) taken = takeFront(channel.buffer, channel.head);
				else {
					taken = channel.buffer[channel.head];
					// Leaving the copy would keep whatever it references alive until a later send overwrites the slot.
					channel.buffer[channel.head] = T.init;
					channel.head = (channel.head + 1) % channel.capacity;
				}
				channel.count--;
				immutable wake = channel.sendersWaiting > 0;
				if(wake) channel.sendersWaiting--;
				bc.mutex.unlockForWriting(channel.lock);
				if(wake) bc.semaphore.post(channel.spaceAvailable);
				value = nullable(taken);
				break;
			}
			if(atomicLoad(channel.closed)) { bc.mutex.unlockForWriting(channel.lock); break; }
			channel.receiversWaiting++;
			bc.mutex.unlockForWriting(channel.lock);
			bc.semaphore.wait(channel.itemAvailable);
		}
		atomicOp!"-="(channel.users, 1);
		return value;
	}


	/// Closes `channel`: later sends fail, and threads waiting in `send` or `receive` on it wake. Values already in `channel` can still be received.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(1);
	/// close(channel);
	/// assert(!send(channel, 1));
	/// free(channel);
	/// ---
	void close(T)(Channel!T* channel) @trusted {
		bc.mutex.lockForWriting(channel.lock);
		atomicStore(channel.closed, true);
		immutable senders = channel.sendersWaiting;
		immutable receivers = channel.receiversWaiting;
		channel.sendersWaiting = channel.receiversWaiting = 0;
		bc.mutex.unlockForWriting(channel.lock);
		foreach(_; 0 .. senders) bc.semaphore.post(channel.spaceAvailable);
		foreach(_; 0 .. receivers) bc.semaphore.post(channel.itemAvailable);
	}

	/// Closes and frees `channel`; does nothing if `channel` is null. Threads blocked in `send` or `receive` are woken and waited for before anything is destroyed, so freeing a channel others are blocked on is safe, though starting a new `send` or `receive` on it after is not. Freeing `channel` twice is undefined.
	///
	/// Examples:
	/// ---
	/// auto channel = bc.channel.create!int(1);
	/// free(channel);
	/// free!int(cast(Channel!int*) null);
	/// ---
	void free(T)(Channel!T* channel) @trusted {
		if(channel is null) return;
		close(channel);
		// A woken waiter still reads the channel, so it must leave before any part of it is destroyed.
		while(atomicLoad(channel.users) > 0) pause();
		freeParts(channel);
	}

}


// --- channels within one thread ------------------------------------------------

/// A channel of `T` values that one thread, or coroutines taking turns on one thread, send through: an unbounded queue with the channel's operations, whose `receive` never waits. Without threads it is `Channel`, since nothing could fill an empty channel or drain a full one while a call waited. Used through the pointer `createLocal` returns; its fields belong to the implementation.
///
/// Examples:
/// ---
/// LocalChannel!int* channel = createLocal!int();
/// assert(send(channel, 1) && send(channel, 2));
/// assert(receive(channel).get == 1 && length(channel) == 1);
/// free(channel);
/// ---
struct LocalChannel(T) if(isChannelable!T) {
	T* buffer = null;
	size_t head = 0;
	size_t capacity = dynamicExtent;
	bool closed = false;
}

// wrapper: reads a field of an opaque channel
/// The capacity `channel` was created with; a local channel never makes a sender wait, whatever it is.
///
/// Examples:
/// ---
/// auto channel = createLocal!int(3);
/// assert(capacity(channel) == 3);
/// free(channel);
/// ---
size_t capacity(T)(const LocalChannel!T* channel) { return channel.capacity; }

/// How many values `channel` holds.
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// assert(send(channel, 1) && length(channel) == 1);
/// free(channel);
/// ---
size_t length(T)(const LocalChannel!T* channel) @trusted { return fp.dynarray.length(channel.buffer) - channel.head; }

// wrapper: reads a field of an opaque channel
/// Whether `close` has been called on `channel`.
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// close(channel);
/// assert(isClosed(channel));
/// free(channel);
/// ---
bool isClosed(T)(const LocalChannel!T* channel) { return channel.closed; }

/// Creates an open, empty local channel, reserving room for `capacity` values unless it is `dynamicExtent`, the default. Returns null if allocation fails.
///
/// Examples:
/// ---
/// auto channel = createLocal!int(4);
/// assert(channel !is null);
/// free(channel);
/// ---
LocalChannel!T* createLocal(T)(size_t capacity = dynamicExtent) @trusted {
	assert(capacity > 0);
	auto channel = fp.pointer.allocate!(LocalChannel!T)(1);
	if(channel is null) return null;
	*channel = LocalChannel!T.init;
	channel.capacity = capacity;
	if(capacity != dynamicExtent && fp.dynarray.reserve(channel.buffer, capacity) is null) {
		fp.pointer.free(channel);
		return null;
	}
	return channel;
}

/// Adds `value` to `channel`. Returns false if `channel` is closed or could not grow, leaving it as it was.
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// assert(send(channel, 5));
/// free(channel);
/// ---
bool send(T)(LocalChannel!T* channel, T value) @trusted {
	if(channel.closed) return false;
	return fp.dynarray.pushBack(channel.buffer, value);
}

/// Removes and returns the oldest value in `channel`, or an empty `Nullable` if it holds none; it never waits. Each costs amortized O(1).
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// assert(receive(channel).isNull);
/// assert(send(channel, 7) && receive(channel).get == 7);
/// free(channel);
/// ---
Nullable!T receive(T)(LocalChannel!T* channel) @trusted {
	if(length(channel) == 0) return Nullable!T.init;
	return nullable(takeFront(channel.buffer, channel.head));
}

/// Closes `channel`: later sends fail, though values already in it can still be received.
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// close(channel);
/// assert(!send(channel, 1));
/// free(channel);
/// ---
void close(T)(LocalChannel!T* channel) { channel.closed = true; }

/// Frees `channel` and the values it holds; does nothing if `channel` is null.
///
/// Examples:
/// ---
/// auto channel = createLocal!int();
/// free(channel);
/// free!int(cast(LocalChannel!int*) null);
/// ---
void free(T)(LocalChannel!T* channel) @trusted {
	if(channel is null) return;
	fp.dynarray.free(channel.buffer);
	fp.pointer.free(channel);
}

static if(!bc.platform.threadingSupported) {
	/// Without threads every channel is a `LocalChannel`, made by `create` as by `createLocal`.
	alias Channel = LocalChannel;
	/// With no threads to share a channel between, `create` makes a `LocalChannel`, exactly as `createLocal` does.
	alias create = createLocal;
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
	free!int(cast(Channel!int*) null);
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

		static void sendTwo(Channel!int* channel, bool* ok) @nogc nothrow { *ok = send(channel, 2); }
		static void receiveOne(Channel!int* channel, bool* ok) @nogc nothrow { *ok = !receive(channel).isNull; }
		static size_t blocked(Channel!int* channel, bool senders) @nogc nothrow {
			bc.mutex.lockForWriting(channel.lock);
			immutable n = senders ? channel.sendersWaiting : channel.receiversWaiting;
			bc.mutex.unlockForWriting(channel.lock);
			return n;
		}

		auto channel = create!int(1);
		assert(channel !is null);
		scope(exit) free(channel);
		assert(send(channel, 1));

		// The sender waits on the full channel until a receive makes room; the receiver waits on the empty one until `close` wakes it.
		bool sent = false, received = true;
		auto t = bc.thread.create(&sendTwo, channel, &sent);
		assert(!t.isNull);
		while(blocked(channel, true) == 0) {}
		assert(receive(channel).get == 1);
		bc.thread.join(t.get);
		assert(sent && receive(channel).get == 2);

		t = bc.thread.create(&receiveOne, channel, &received);
		assert(!t.isNull);
		while(blocked(channel, false) == 0) {}
		close(channel);
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
		static void receiveThenMark(Channel!int* channel) @nogc nothrow { receive(channel); atomicOp!"+="(left, 1); }
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
		// Each receiver marks itself only after `receive` returns, so the count is whole once they are joined, not when `free` returns.
		foreach(ref waiter; blockedThreads) bc.thread.join(waiter.get);
		assert(atomicLoad(left) == waiters);
	}
}

unittest { // a local channel keeps order across the shifts that keep each receive O(1), in any build
	auto local = createLocal!int();
	assert(local !is null);
	scope(exit) free(local);
	foreach(round; 0 .. 3) {
		foreach(i; 0 .. 10) assert(send(local, round * 10 + i));
		foreach(i; 0 .. 10) assert(receive(local).get == round * 10 + i);
	}
	assert(receive(local).isNull && length(local) == 0);
	close(local);
	assert(isClosed(local) && !send(local, 1));
	debug foreach(i; 0 .. 2) {
		bc.platform.failAfter(i);
		assert(createLocal!int(4) is null);
	}
}
