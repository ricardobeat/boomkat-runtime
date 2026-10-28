// `bkr test [flags] [--filter=text] [paths...]`: finds test files natively,
// so discovery needs no read grant, and runs them through the embedded
// runner module, which imports each one and runs what it registered.
module bkr;

import boomkat;
import std::io;
import std::collections::list;
import std::sort;
import std::thread;
import std::time;
import libc;

const String TEST_RUNNER = `import { __run } from "test";
import { args } from "process";
await __run(args);
`;

// The runner's module path. It sits in the working directory, so a
// boomkat.toml there configures the run as it would a script beside it.
const String TEST_ENTRY_NAME = "[bkr test]";

tlocal bool g_testing;

fn bool is_test_file(String name) {
    foreach (ext : (String[]) { ".js", ".mjs", ".jsx", ".ts", ".mts", ".tsx" }) {
        if (!name.ends_with(ext)) continue;
        String stem = name[:name.len - ext.len];
        return stem.ends_with(".test") || stem.ends_with("_test") || stem.ends_with(".spec");
    }
    return false;
}

// find_tests appends the test files under path. With `every`, every regular
// file counts, which is what the watcher stamps.
fn void find_tests(String path, List{String}* out, bool every) {
    Stat st;
    if (libc::stat(path.zstr_tcopy(), &st) != 0) return;
    if ((st.st_mode & libc::S_IFMT) != libc::S_IFDIR) {
        out.push(path.copy(mem));
        return;
    }
    void* dir = opendir(path.zstr_tcopy());
    if (!dir) return;
    defer closedir(dir);
    for (Dirent* e = readdir(dir); e; e = readdir(dir)) {
        String name = ((ZString)&e.name).str_view();
        if (name.starts_with(".") || name == "node_modules") continue;
        String child = string::tformat("%s/%s", path, name);
        if (e.type == DT_DIR) {
            find_tests(child, out, every);
        } else if (every || is_test_file(name)) {
            out.push(child.copy(mem));
        }
    }
}

fn int compare_paths(String a, String b) {
    sz n = min(a.len, b.len);
    for (sz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.len < b.len ? -1 : a.len > b.len ? 1 : 0;
}

// The argv a test run boots with: runtime flags, the runner entry, then the
// runner's own arguments (a filter, then the files).
fn String[]? test_argv(String[] argv) {
    List{String} flags;
    flags.init(mem);
    List{String} paths;
    paths.tinit();
    String filter;
    foreach (a : argv[2..]) {
        if (a.starts_with("--filter=")) {
            filter = a;
        } else if (a.starts_with("-")) {
            flags.push(a);
        } else {
            paths.push(a);
        }
    }
    if (!paths.len()) paths.push(".");
    List{String} files;
    files.init(mem);
    foreach (p : paths) {
        String abs = absolute(p);
        if (!file::exists(abs)) {
            io::eprintfn("error: %s does not exist", p);
            return USAGE~;
        }
        find_tests(abs, &files, false);
    }
    String[] found = files.array_view();
    sort::quicksort(found, &compare_paths);
    g_testing = true;
    flags.push_front(argv[0]);
    flags.push(absolute(TEST_ENTRY_NAME).copy(mem));
    if (filter.len) flags.push(filter);
    foreach (f : found) flags.push(f);
    return flags.array_view();
}

// watch_stamp hashes the path, size and mtime of every file under the paths.
// It changes when a file is edited, added or removed.
fn ulong watch_stamp(String[] paths) {
    @pool() {
        ulong hash = 1469598103934665603;
        List{String} files;
        files.tinit();
        foreach (p : paths) find_tests(absolute(p), &files, true);
        foreach (f : files) {
            for (usz i = 0; i < f.len; i++) hash = (hash ^ (ulong)f[i]) * 1099511628211;
            Stat st;
            if (libc::stat(f.zstr_tcopy(), &st) != 0) continue;
            hash = (hash ^ (ulong)st.st_size) * 1099511628211;
            hash = (hash ^ (ulong)st.st_mtimespec.s) * 1099511628211;
            hash = (hash ^ (ulong)st.st_mtimespec.ns) * 1099511628211;
        }
        return hash;
    };
}

fn bool watch_requested(String[] argv) {
    foreach (a : argv) {
        if (a == "--watch") return true;
    }
    return false;
}

// `bkr test --watch`: runs the tests, then reruns them whenever a file under
// the paths changes. Each run is a fresh bkr, so edited modules reload.
fn void watch_tests(String[] argv) {
    List{String} child;
    child.init(mem);
    List{String} paths;
    paths.init(mem);
    foreach (a : argv) {
        if (a != "--watch") child.push(a);
    }
    foreach (a : argv[2..]) {
        if (!a.starts_with("-")) paths.push(a);
    }
    if (!paths.len()) paths.push(".");
    for (;;) {
        io::eprintn("\n[watch] running tests");
        run_inherit(child.array_view());
        io::eprintn("[watch] waiting for changes, Ctrl-C to stop");
        ulong stamp = watch_stamp(paths.array_view());
        while (watch_stamp(paths.array_view()) == stamp) {
            thread::sleep_ns((NanoDuration)250000000);
        }
    }
}

fn void js_isatty(JsCtx ctx, void* udata) => ctx.ret_bool(libc::isatty(ctx.arg(0).as_int(1)) != 0);

const Native[] TEST_NATIVES = {
    { "isatty", &js_isatty, 1 },
};
