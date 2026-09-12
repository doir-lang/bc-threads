/// Manual unittest runner for -betterC: druntime's automatic test runner
/// (`core.runtime.runModuleUnitTests`) isn't available, so this discovers
/// and runs every `unittest {}` block in the package's modules itself.
module runner;

import std.meta : AliasSeq;
import ecrs.threadpool;

private alias ModuleList = AliasSeq!(ecrs.threadpool);

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
