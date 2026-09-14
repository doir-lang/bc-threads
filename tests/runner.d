module runner;

import std.meta : AliasSeq;
import bct.threadpool;
import bct.channel;

private alias ModuleList = AliasSeq!(bct.threadpool, bct.channel);

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
