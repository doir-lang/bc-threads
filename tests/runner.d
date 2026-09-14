module runner;

import std.meta : AliasSeq;
import bc.threadpool;
import bc.channel;
import bc.thread;
import bc.semaphore;
import bc.mutex;

private alias ModuleList = AliasSeq!(
	bc.threadpool, bc.channel, bc.thread, bc.semaphore, bc.mutex
);

extern (C) void main() {
	import core.stdc.stdio : printf;

	size_t count = 0;
	static foreach (m; ModuleList) {
		static foreach (u; __traits(getUnitTests, m)) {
			u();
			count++;
		}
	}
	printf("bc-threads: %zu unittests passed\n", count);
}
