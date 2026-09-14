module bc.platform;

// Single source of truth for whether OS threading primitives are available
// on the target platform.
version(linux) enum bool threadingSupported = true;
else version(OSX) enum bool threadingSupported = true;
else version(Windows) enum bool threadingSupported = true;
else enum bool threadingSupported = false;

// D's `version = Ident` declarations are module-local, so a custom version
// identifier set here would not be visible to importing modules - every
// module that needs to branch on `version(PthreadBackend)` must mixin this
// string to declare it for itself, keeping the linux/OSX condition in one
// place instead of copy-pasted per module.
enum string PthreadBackendMixin = q{
	version(linux) version = PthreadBackend;
	else version(OSX) version = PthreadBackend;
};
