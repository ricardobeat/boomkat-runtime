// The file module: whole-file reads and writes, open files as resources,
// directories and metadata. Blocking work runs on the pool; permission
// checks run on the loop thread against the canonical path.
module bkr;

import boomkat;
import std::io;
import libc;
import std::collections::list;

// struct dirent: Darwin puts a 16-bit name length before the type byte, Linux
// does not, so the fields after reclen are read through the accessors.
struct Dirent {
    ulong ino;
    ulong seekoff;
    ushort reclen;
    char[1027] tail;
}

fn char dirent_type(Dirent* e) => e.tail[env::DARWIN ? 2 : 0];
fn String dirent_name(Dirent* e) => ((ZString)&e.tail[env::DARWIN ? 3 : 1]).str_view();

extern fn CInt fstat(CInt fd, Stat* st) @cname("fstat64");
extern fn CInt open(ZString path, CInt flags, ...);
extern fn CInt mkdir(ZString path, ushort mode);
extern fn CInt rmdir(ZString path);
extern fn CInt unlink(ZString path);
extern fn void* opendir(ZString path);
extern fn Dirent* readdir(void* dir);
extern fn CInt closedir(void* dir);

const CInt O_RDONLY       = 0;
const CInt O_WRONLY       = 1;
const CInt O_RDWR         = 2;
const char DT_DIR         = 4;
const char DT_LNK         = 10;

enum FsOp {
    READ_FILE,
    READ_TEXT,
    WRITE_FILE,
    OPEN,
    STAT,
    LIST,
    MKDIR,
    REMOVE,
    RENAME,
}

struct FsTask {
    inline Task task;
    FsOp kind;
    uint op;
    String path;
    String path2;
    char[] data;
    CInt flags;
    bool flag;
    CInt err;
    CInt fd;
    String text;
}

fn String kind_name(uint mode) {
    switch (mode & libc::S_IFMT) {
        case libc::S_IFDIR: return "dir";
        case 0o120000: return "symlink";
        case libc::S_IFREG: return "file";
        default: return "other";
    }
}

fn void read_all(FsTask* f) {
    CInt fd = open(f.path.zstr_tcopy(), O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC);
    if (fd < 0) {
        f.err = libc::errno();
        return;
    }
    defer libc::close(fd);
    Stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 0) {
        f.data = mem::alloc_array(char, st.st_size + (f.kind == READ_TEXT ? 1 : 0))[:st.st_size];
        usz at;
        while (at < f.data.len) {
            sz n = libc::read(fd, f.data.ptr + at, f.data.len - at);
            if (n < 0) {
                f.err = libc::errno();
                free(f.data.ptr);
                f.data = { };
                return;
            }
            if (n == 0) break;
            at += (usz)n;
        }
        if (f.kind == READ_TEXT) f.data.ptr[at] = 0;
        f.data = f.data[:at];
        return;
    }
    DString acc;
    acc.init(mem);
    defer acc.free();
    char[32768] buf;
    while (true) {
        sz n = libc::read(fd, &buf, buf.len);
        if (n < 0) {
            f.err = libc::errno();
            return;
        }
        if (n == 0) break;
        acc.append_bytes(buf[:n]);
    }
    if (f.kind == READ_TEXT) {
        String text = acc.str_view();
        f.data = mem::alloc_array(char, text.len + 1)[:text.len];
        f.data[..] = ((char[])text)[..];
        f.data.ptr[text.len] = 0;
    } else {
        f.data = copy_bytes((char[])acc.str_view());
    }
}

fn void write_all(FsTask* f) {
    CInt fd = open(f.path.zstr_tcopy(), f.flags | O_NOFOLLOW_ANY | O_CLOEXEC, 0o666);
    if (fd < 0) {
        f.err = libc::errno();
        return;
    }
    defer libc::close(fd);
    char[] b = f.data;
    while (b.len) {
        sz n = libc::write(fd, b.ptr, b.len);
        if (n < 0) {
            if (libc::errno() == Errno.EINTR) continue;
            f.err = libc::errno();
            return;
        }
        b = b[n..];
    }
}

fn void stat_path(FsTask* f) {
    Stat st;
    if (libc::lstat(f.path.zstr_tcopy(), &st) != 0) {
        f.err = libc::errno();
        return;
    }
    f.text = string::format(
        mem,
        "%s %d %d %d",
        kind_name(st.st_mode),
        (long)st.st_size,
        mtime_seconds(&st) * 1000 + mtime_nanos(&st) / 1000000,
        st.st_mode & 0o7777
    );
}

fn void list_dir(FsTask* f) {
    void* dir = opendir(f.path.zstr_tcopy());
    if (!dir) {
        f.err = libc::errno();
        return;
    }
    defer closedir(dir);
    DString out;
    out.init(mem);
    for (Dirent* e = readdir(dir); e; e = readdir(dir)) {
        String name = dirent_name(e);
        if (name == "." || name == "..") continue;
        out.appendf("%s %s\n", dirent_type(e) == DT_DIR ? "dir" : dirent_type(e) == DT_LNK ? "symlink" : "file", name);
    }
    f.text = out.copy_str(mem);
    out.free();
}

fn CInt mkdir_all(String path) {
    if (mkdir(path.zstr_tcopy(), 0o777) == 0) return 0;
    CInt err = libc::errno();
    if (err == Errno.EEXIST) {
        Stat st;
        return libc::stat(path.zstr_tcopy(), &st) == 0 && (st.st_mode & libc::S_IFMT) == libc::S_IFDIR ? 0 : err;
    }
    if (err != Errno.ENOENT) return err;
    sz slash = path.rindex_of_char('/') ?? 0;
    if (slash <= 0) return err;
    CInt up = mkdir_all(path[:slash]);
    if (up) return up;
    return mkdir(path.zstr_tcopy(), 0o777) == 0 ? 0 : libc::errno();
}

fn CInt remove_all(String path, bool recursive) {
    Stat st;
    if (libc::lstat(path.zstr_tcopy(), &st) != 0) return libc::errno();
    if ((st.st_mode & libc::S_IFMT) != libc::S_IFDIR) return unlink(path.zstr_tcopy()) == 0 ? 0 : libc::errno();
    if (recursive) {
        void* dir = opendir(path.zstr_tcopy());
        if (!dir) return libc::errno();
        List{String} names;
        names.init(mem);
        for (Dirent* e = readdir(dir); e; e = readdir(dir)) {
            String name = dirent_name(e);
            if (name != "." && name != "..") names.push(name.copy(mem));
        }
        closedir(dir);
        CInt err;
        foreach (n : names) {
            if (!err) err = remove_all(string::format(mem, "%s/%s", path, n), true);
            free(n.ptr);
        }
        names.free();
        if (err) return err;
    }
    return rmdir(path.zstr_tcopy()) == 0 ? 0 : libc::errno();
}

fn void fs_work(Task* t) {
    FsTask* f = (FsTask*)t;
    switch (f.kind) {
        case READ_FILE:
        case READ_TEXT: read_all(f);
        case WRITE_FILE: write_all(f);
        case OPEN:
            f.fd = open(f.path.zstr_tcopy(), f.flags | O_NOFOLLOW_ANY | O_CLOEXEC, 0o666);
            if (f.fd < 0) f.err = libc::errno();
        case STAT: stat_path(f);
        case LIST: list_dir(f);
        case MKDIR: f.err = f.flag ? mkdir_all(f.path) : (mkdir(f.path.zstr_tcopy(), 0o777) == 0 ? 0 : libc::errno());
        case REMOVE: f.err = remove_all(f.path, f.flag);
        case RENAME: f.err = libc::rename(f.path.zstr_tcopy(), f.path2.zstr_tcopy()) == 0 ? 0 : libc::errno();
    }
}

fn void fs_done(Task* t) {
    FsTask* f = (FsTask*)t;
    defer {
        free(f.path.ptr);
        if (f.path2.len) free(f.path2.ptr);
        if (f.data.len && f.kind == WRITE_FILE) free(f.data.ptr);
        if (f.text.len) free(f.text.ptr);
        free(f);
    }
    if (f.err) {
        if (f.data.ptr && (f.kind == READ_FILE || f.kind == READ_TEXT)) free(f.data.ptr);
        reject_errno(f.op, f.err, f.path);
        return;
    }
    switch (f.kind) {
        case READ_FILE: resolve_bytes(f.op, f.data);
        case READ_TEXT:
            g_runtime.rt.@scope() {
                JsValue? value = owned_text_value(f.data);
                if (catch value) {
                    reject(f.op, "ENOMEM", "cannot allocate file text");
                } else {
                    resolve(f.op, value);
                }
            };
        case OPEN:
            Res* r = res_new(FILE);
            r.fd = f.fd;
            resolve_number(f.op, r.rid);
        case STAT:
        case LIST: resolve_string(f.op, f.text);
        case WRITE_FILE:
        case MKDIR:
        case REMOVE:
        case RENAME: resolve(f.op, g_runtime.rt.null_value() ?? { });
    }
}

fn void fs_submit(
    FsOp kind,
    uint op,
    String path,
    String path2 = "",
    char[] data = { },
    CInt flags = 0,
    bool flag = false
) {
    FsTask* f = mem::new(FsTask);
    *f = {
        .task = { .work = &fs_work, .done = &fs_done },
        .kind = kind,
        .op = op,
        .path = path.copy(mem),
        .path2 = path2.len ? path2.copy(mem) : "",
        .data = data,
        .flags = flags,
        .flag = flag,
    };
    submit(f);
}

fn String denied_path(
    Perm p,
    String path
) => string::tformat("%s access to \"%s\" denied; run with --allow-%s", p.name, path, p.name);

// Resolves arg i to its canonical path after the permission check; settles the op with an error otherwise.
fn bool guarded(uint op, Perm p, String raw, String* out) {
    String path = canonical(raw, (String)(path::tcwd() ?? (Path)"/"));
    if (!check_path(p, path)) {
        reject(op, "PERMISSION_DENIED", denied_path(p, raw));
        return false;
    }
    *out = path;
    return true;
}

fn int open_flags(String mode) {
    switch (mode) {
        case "r": return O_RDONLY;
        case "w": return O_WRONLY | O_CREAT | O_TRUNC;
        case "a": return O_WRONLY | O_CREAT | O_APPEND;
        case "x": return O_WRONLY | O_CREAT | O_EXCL;
        case "rw": return O_RDWR | O_CREAT;
        default: return -1;
    }
}

// readFile(op, path)
fn void js_read_file(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (guarded(op, READ, ctx.arg(1).as_string() ?? "", &path)) fs_submit(READ_FILE, op, path);
    };
}

fn void js_read_text(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (guarded(op, READ, ctx.arg(1).as_string() ?? "", &path)) fs_submit(READ_TEXT, op, path);
    };
}

// writeFile(op, path, bytes, append)
fn void js_write_file(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (!guarded(op, WRITE, ctx.arg(1).as_string() ?? "", &path)) return;
        bool append = ctx.arg(3).as_bool() ?? false;
        fs_submit(WRITE_FILE, op, path, data: copy_bytes(ctx.arg(2)
            .bytes()), flags: O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC));
    };
}

// open(op, path, mode)
fn void js_open(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String mode = ctx.arg(2).as_string() ?? "r";
        int flags   = open_flags(mode);
        if (flags < 0) {
            reject(op, "EINVAL", "invalid open mode");
            return;
        }
        String path;
        if (guarded(op, mode == "r" ? READ : WRITE, ctx.arg(1).as_string() ?? "", &path)) {
            if (mode == "rw" && !check_path(READ, path)) {
                reject(op, "PERMISSION_DENIED", denied_path(READ, path));
                return;
            }
            fs_submit(OPEN, op, path, flags: flags);
        }
    };
}

// libc::stat(op, path) -> "kind size mtimeMs mode"
fn void js_stat(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (guarded(op, READ, ctx.arg(1).as_string() ?? "", &path)) fs_submit(STAT, op, path);
    };
}

// list(op, path) -> "kind name\n..."
fn void js_list(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (guarded(op, READ, ctx.arg(1).as_string() ?? "", &path)) fs_submit(LIST, op, path);
    };
}

// mkdir(op, path, recursive)
fn void js_mkdir(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (guarded(op, WRITE, ctx.arg(1)
            .as_string() ?? "", &path)) fs_submit(MKDIR, op, path, flag: ctx.arg(2).as_bool() ?? false);
    };
}

// remove(op, path, recursive)
fn void js_remove(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String path;
        if (!guarded(op, WRITE, ctx.arg(1).as_string() ?? "", &path)) return;
        if (path == "/") {
            reject(op, "EINVAL", "refusing to remove the root");
            return;
        }
        fs_submit(REMOVE, op, path, flag: ctx.arg(2).as_bool() ?? false);
    };
}

// rename(op, from, to)
fn void js_rename(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    @pool() {
        String from;
        String to;
        if (guarded(op, WRITE, ctx.arg(1)
            .as_string() ?? "", &from) && guarded(op, WRITE, ctx.arg(2)
                .as_string() ?? "", &to)) fs_submit(RENAME, op, from, to);
    };
}

const Native[] FS_NATIVES = {
    { "readFile", &js_read_file, 2 },
    { "readText", &js_read_text, 2 },
    { "writeFile", &js_write_file, 4 },
    { "open", &js_open, 3 },
    { "stat", &js_stat, 2 },
    { "list", &js_list, 2 },
    { "mkdir", &js_mkdir, 3 },
    { "remove", &js_remove, 3 },
    { "rename", &js_rename, 3 },
};
