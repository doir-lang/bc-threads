module runner;

import core.stdc.stdio : fprintf, printf, stderr;

private enum modules = [
	"bc.threadpool",
	"bc.channel",
	"bc.thread",
	"bc.semaphore",
	"bc.mutex",
	"bc.spinlock",
	"bc.platform",
];

private int runEveryTest() {
	size_t total = 0;

	static foreach(name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		cast(void) fprintf(stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach(i, test; tests) {
			cast(void) fprintf(stderr, "  [%d] ", cast(int) i);
			test();
			cast(void) fprintf(stderr, "ok\n");
			++total;
		}
	}}

	cast(void) printf("bc-threads: all %d tests passed.\n", cast(int) total);
	return 0;
}

version(BctCoverage) {
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
