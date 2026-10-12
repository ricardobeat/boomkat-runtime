// macOS fixtures simulate absent libraries and missing required entry points.
#include <dlfcn.h>
#include <string.h>

#ifdef SQLITE_TEST_MISSING
static void *test_dlopen(const char *path, int flags) {
    if (path && strstr(path, "libsqlite3")) return 0;
    return dlopen(path, flags);
}
#define REPLACEMENT test_dlopen
#define ORIGINAL dlopen
#else
static void *test_dlsym(void *handle, const char *name) {
    if (name && !strcmp(name, "sqlite3_prepare_v2")) return 0;
    return dlsym(handle, name);
}
#define REPLACEMENT test_dlsym
#define ORIGINAL dlsym
#endif

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} interpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)REPLACEMENT, (const void *)ORIGINAL
};
