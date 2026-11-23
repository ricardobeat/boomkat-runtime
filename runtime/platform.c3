// The few places macOS and Linux libc differ: the monotonic clock, the
// environment block, and where stat keeps the modification time.
module bkr;

import libc;

extern fn ulong clock_gettime_nsec_np(CInt clock) @feat(DARWIN);
extern fn ZString** ns_environ() @cname("_NSGetEnviron") @feat(DARWIN);
const CInt CLOCK_MONOTONIC_RAW @feat(DARWIN) = 4;
const CInt EHOSTUNREACH_CODE = env::DARWIN ? 65 : 113;

struct ClockTimespec @feat(!DARWIN) {
    long sec;
    long nsec;
}
extern fn CInt clock_gettime(CInt clock, ClockTimespec* ts) @feat(!DARWIN);
extern ZString* environ @feat(!DARWIN);
const CInt CLOCK_MONOTONIC @feat(!DARWIN) = 1;

// open(2) flags and address families. Darwin and Linux number them
// differently; O_NOFOLLOW_ANY refuses a symlink in any path component on
// Darwin, and on Linux the closest open flag is O_NOFOLLOW (last component).
const CInt AF_INET     = 2;
const CInt AF_INET6    = env::DARWIN ? 30 : 10;
const CInt O_APPEND    = env::DARWIN ? 0x8 : 0x400;
const CInt O_CREAT     = env::DARWIN ? 0x200 : 0x40;
const CInt O_TRUNC     = env::DARWIN ? 0x400 : 0x200;
const CInt O_EXCL      = env::DARWIN ? 0x800 : 0x80;
const CInt O_CLOEXEC   = env::DARWIN ? 0x1000000 : 0x80000;
const CInt O_NOFOLLOW_ANY = env::DARWIN ? 0x20000000 : (env::ARCH_TYPE == ArchType.X86_64 || env::ARCH_TYPE == ArchType.X86 ? 0x20000 : 0x8000);

const String OPENSSL_HINT = env::DARWIN ? "brew install openssl@3" : "your package manager (libssl3 or openssl-libs)";

fn ulong monotonic_ns() {
    $if env::DARWIN:
        return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    $else
        ClockTimespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (ulong)ts.sec * 1000000000 + (ulong)ts.nsec;
    $endif
}

fn ZString* environment() {
    $if env::DARWIN:
        return *ns_environ();
    $else
        return environ;
    $endif
}

fn long mtime_seconds(Stat* st) {
    $if env::DARWIN:
        return (long)st.st_mtimespec.s;
    $else
        return (long)st.st_mtime;
    $endif
}

fn long mtime_nanos(Stat* st) {
    $if env::DARWIN:
        return (long)st.st_mtimespec.ns;
    $else
        return (long)st.st_mtime_nsec;
    $endif
}
