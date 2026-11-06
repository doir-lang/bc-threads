module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"bc.threadpool",
	"bc.channel",
	"bc.thread",
	"bc.semaphore",
	"bc.mutex",
	"bc.spinlock",
	"bc.spinlock.readerlock",
	"bc.monitor",
	"bc.platform",
	"bc.spinlock.striped",
	"bc.gate",
	"bc.interner",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("bc-threads");
	return 0;
}

version(BctCoverage) {
	shared static this() {
		static import core.runtime;
		core.runtime.Runtime.extendedModuleUnitTester = () => core.runtime.UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
