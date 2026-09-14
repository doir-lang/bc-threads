module bct.channel;

import fp.dynarray;
import fp.pointer;
import core.atomic : atomicOp, atomicLoad, atomicStore, cas;
import std.typecons : Nullable, nullable;

@nogc nothrow:

version(linux) {
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
	enum bool threadingSupported = true;
} else version(OSX) {
	import core.stdc.errno : errno, EINTR;
	import core.sys.darwin.mach.kern_return : KERN_ABORTED;
	import core.sys.darwin.mach.semaphore :
		mach_task_self, semaphore_create, semaphore_destroy, semaphore_signal,
		semaphore_t, semaphore_wait, SYNC_POLICY_FIFO;
	enum bool threadingSupported = true;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, CreateSemaphoreA, ReleaseSemaphore, WaitForSingleObject, CloseHandle, INFINITE;
	enum bool threadingSupported = true;
} else {
	enum bool threadingSupported = false;
}

/// Pass this to `create()` for an unbounded channel - see the module doc
/// comment.
enum size_t dynamicExtent = size_t.max;


static if(threadingSupported) {

	version(linux) {
		private void semInit(ref sem_t s) @trusted @nogc nothrow { sem_init(&s, 0, 0); }
		private void semWait(ref sem_t s) @trusted @nogc nothrow { sem_wait(&s); }
		private void semPost(ref sem_t s) @trusted @nogc nothrow { sem_post(&s); }
		private void semDestroy(ref sem_t s) @trusted @nogc nothrow { sem_destroy(&s); }
	} else version(OSX) {
		private void semInit(ref semaphore_t s) @trusted @nogc nothrow {
			semaphore_create(mach_task_self(), &s, SYNC_POLICY_FIFO, 0);
		}
		private void semWait(ref semaphore_t s) @trusted @nogc nothrow {
			while(true) {
				immutable rc = semaphore_wait(s);
				if(!rc) return;
				if(rc == KERN_ABORTED && errno == EINTR) continue;
				return;
			}
		}
		private void semPost(ref semaphore_t s) @trusted @nogc nothrow { semaphore_signal(s); }
		private void semDestroy(ref semaphore_t s) @trusted @nogc nothrow { semaphore_destroy(mach_task_self(), s); }
	} else version(Windows) {
		private void semInit(ref HANDLE h) @trusted @nogc nothrow { h = CreateSemaphoreA(null, 0, int.max, null); }
		private void semWait(ref HANDLE h) @trusted @nogc nothrow { WaitForSingleObject(h, INFINITE); }
		private void semPost(ref HANDLE h) @trusted @nogc nothrow { ReleaseSemaphore(h, 1, null); }
		private void semDestroy(ref HANDLE h) @trusted @nogc nothrow { CloseHandle(h); }
	}

	struct Channel(T) {
		version(linux) sem_t itemAvailable;
		else version(OSX) semaphore_t itemAvailable;
		else version(Windows) HANDLE itemAvailable;

		version(linux) sem_t spaceAvailable;
		else version(OSX) semaphore_t spaceAvailable;
		else version(Windows) HANDLE spaceAvailable;

		T* buffer = null;
		size_t capacity = 0;
		size_t head = 0;
		size_t count = 0;
		shared uint lock = 0;

		shared bool closed = false;

		shared ptrdiff_t sendersWaiting = 0;
		shared ptrdiff_t receiversWaiting = 0;
	}

	private void acquire(T)(Channel!T* ch) @trusted @nogc nothrow {
		while(!cas(&ch.lock, cast(uint) 0, cast(uint) 1)) {}
	}
	private void release(T)(Channel!T* ch) @trusted @nogc nothrow {
		atomicStore(ch.lock, cast(uint) 0);
	}

	Channel!T* create(T)(size_t capacity) @trusted @nogc nothrow {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent)
			ch.buffer = fp.dynarray.create!(T)(capacity);
		semInit(ch.itemAvailable);
		semInit(ch.spaceAvailable);
		return ch;
	}

	size_t capacity(T)(const Channel!T* ch) @nogc nothrow { return ch.capacity; }

	size_t length(T)(Channel!T* ch) @trusted @nogc nothrow {
		acquire(ch);
		immutable n = ch.count;
		release(ch);
		return n;
	}

	bool isClosed(T)(const Channel!T* ch) @trusted @nogc nothrow { return atomicLoad(ch.closed); }

	bool send(T)(Channel!T* ch, T value) @trusted @nogc nothrow {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(atomicLoad(ch.closed)) { release(ch); return false; }
			if(dynamic) {
				fp.dynarray.pushBack(ch.buffer, value);
				ch.count++;
				release(ch);
				semPost(ch.itemAvailable);
				return true;
			}
			if(ch.count < ch.capacity) {
				ch.buffer[(ch.head + ch.count) % ch.capacity] = value;
				ch.count++;
				release(ch);
				semPost(ch.itemAvailable);
				return true;
			}
			atomicOp!"+="(ch.sendersWaiting, cast(ptrdiff_t) 1);
			release(ch);
			semWait(ch.spaceAvailable);
			atomicOp!"-="(ch.sendersWaiting, cast(ptrdiff_t) 1);
		}
	}

	Nullable!T receive(T)(Channel!T* ch) @trusted @nogc nothrow {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(ch.count > 0) {
				T value;
				if(dynamic) {
					value = *fp.dynarray.front(ch.buffer);
					fp.dynarray.removeAt(ch.buffer, 0);
				} else {
					value = ch.buffer[ch.head];
					ch.head =(ch.head + 1) % ch.capacity;
				}
				ch.count--;
				release(ch);
				if(!dynamic) semPost(ch.spaceAvailable);
				return nullable(value);
			}
			if(atomicLoad(ch.closed)) { release(ch); return Nullable!T.init; }
			atomicOp!"+="(ch.receiversWaiting, cast(ptrdiff_t) 1);
			release(ch);
			semWait(ch.itemAvailable);
			atomicOp!"-="(ch.receiversWaiting, cast(ptrdiff_t) 1);
		}
	}

	void close(T)(Channel!T* ch) @trusted @nogc nothrow {
		acquire(ch);
		atomicStore(ch.closed, true);
		immutable senders = atomicLoad(ch.sendersWaiting);
		immutable receivers = atomicLoad(ch.receiversWaiting);
		release(ch);
		foreach(_; 0 .. senders) semPost(ch.spaceAvailable);
		foreach(_; 0 .. receivers) semPost(ch.itemAvailable);
	}

	void free(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(ch is null) return;
		if(!isClosed(ch)) close(ch);
		semDestroy(ch.itemAvailable);
		semDestroy(ch.spaceAvailable);
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}

} else {

	/// Degenerate fallback for platforms without a real thread backend:
	/// there's nothing else running concurrently to ever fill an empty
	/// channel or drain a full one, so `send`/`receive` never block - they
	/// just report failure instead. Amounts to `dynamicExtent` behavior
	/// unconditionally, regardless of what `capacity` was requested.
	struct Channel(T) {
		T* buffer = null;
		size_t capacity = 0;
		bool closed = false;
	}

	Channel!T* create(T)(size_t capacity) @trusted @nogc nothrow {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent)
			fp.dynarray.reserve(ch.buffer, capacity);
		return ch;
	}

	size_t capacity(T)(const Channel!T* ch) @nogc nothrow { return ch.capacity; }
	size_t length(T)(Channel!T* ch) @trusted @nogc nothrow { return fp.dynarray.length(ch.buffer); }
	bool isClosed(T)(const Channel!T* ch) @nogc nothrow { return ch.closed; }

	bool send(T)(Channel!T* ch, T value) @trusted @nogc nothrow {
		if(ch.closed) return false;
		fp.dynarray.pushBack(ch.buffer, value);
		return true;
	}

	Nullable!T receive(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(fp.dynarray.length(ch.buffer) == 0) return Nullable!T.init;
		T value = *fp.dynarray.front(ch.buffer);
		fp.dynarray.removeAt(ch.buffer, 0);
		return nullable(value);
	}

	void close(T)(Channel!T* ch) @nogc nothrow { ch.closed = true; }

	void free(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(ch is null) return;
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}
}


unittest {
	auto ch = create!int(4);
	scope(exit) free(ch);

	assert(capacity(ch) == 4);
	assert(length(ch) == 0);
	assert(!isClosed(ch));

	foreach(i; 0 .. 3) assert(send(ch, i));
	assert(length(ch) == 3);

	close(ch);
	assert(isClosed(ch));
	assert(!send(ch, 99)); // closed: no new sends, even though there's room

	foreach(i; 0 .. 3) {
		auto v = receive(ch);
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(receive(ch).isNull); // drained and closed
}


unittest {
	auto ch = create!int(dynamicExtent);
	scope(exit) free(ch);

	assert(capacity(ch) == dynamicExtent);
	assert(length(ch) == 0);

	enum n = 500; // far more than any reasonable fixed ring buffer
	foreach(i; 0 .. n) assert(send(ch, i));
	assert(length(ch) == n);

	close(ch);
	assert(!send(ch, 99)); // closed: still no new sends

	foreach(i; 0 .. n) {
		auto v = receive(ch);
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(receive(ch).isNull); // drained and closed
}


unittest {
	// Exercises real cross-thread blocking: a single-slot channel forces the
	// producer to block on `send` until the consumer's `receive` catches up,
	// and vice versa - the pool's worker threads stand in for independent
	// goroutines here.
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct ProducerArg { Channel!int* ch; int count; }
	static void produce(void* arg) @nogc nothrow {
		auto a = cast(ProducerArg*) arg;
		foreach(i; 0 .. a.count) send(a.ch, i);
		close(a.ch);
	}

	static struct ConsumerArg { Channel!int* ch; int sum; int received; }
	static void consume(void* arg) @nogc nothrow {
		auto a = cast(ConsumerArg*) arg;
		while(auto v = receive(a.ch)) { a.sum += v.get(); a.received++; }
	}

	enum n = 50;
	auto producerArg = ProducerArg(ch, n);
	auto consumerArg = ConsumerArg(ch, 0, 0);

	bct.threadpool.Job[2] jobs = [bct.threadpool.Job(&produce, &producerArg), bct.threadpool.Job(&consume, &consumerArg)];
	pool.run(jobs[]);

	assert(consumerArg.received == n);
	int expectedSum = 0;
	foreach(i; 0 .. n) expectedSum += i;
	assert(consumerArg.sum == expectedSum);
}


unittest {
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct Result { Channel!int* ch; bool ok; }
	static void receiveOnce(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		r.ok = !receive(r.ch).isNull;
	}

	Result result = Result(ch, true);
	bct.threadpool.Job[1] jobs = [bct.threadpool.Job(&receiveOnce, &result)];
	pool.submit(jobs[]);

	close(ch);
	pool.wait();

	assert(!result.ok);
}


unittest {
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct Result { Channel!int* ch; bool ok; }
	static void sendTwice(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		send(r.ch, 1);          // fills the one slot, doesn't block
		r.ok = send(r.ch, 2);   // blocks: no room, no receiver
	}

	Result result = Result(ch, true);
	bct.threadpool.Job[1] jobs = [bct.threadpool.Job(&sendTwice, &result)];
	pool.submit(jobs[]);

	close(ch);
	pool.wait();

	assert(!result.ok);
}
