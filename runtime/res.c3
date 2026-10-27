// The resource table. A rid names a stream JS can read, write and close:
// stdio, files, TCP and TLS connections, listeners. Rids carry a generation
// so a stale one never reaches a recycled slot.
module bkr;

import boomkat;
import std::collections::list;
import libc;

enum ResKind {
    STDIO,
    FILE,
    SOCKET,
    LISTENER,
    PIPE,
}

struct Res {
    ResKind kind;
    uint rid;
    bool closed; // JS called close
    bool gone; // the OS side is gone: socket closed, fd closed
    bool eof;
    CInt error;
    uint read_op;
    uint write_op;
    usz write_len;
    List{char} inbox;
    List{char} outbox;

    CInt fd;
    bool busy; // a pool task holds the fd

    UsSocket* sock;
    CInt ssl;
    bool paused;
    bool weak; // keeps the loop alive only while a read is pending
    bool unrefd; // its poll is out of the loop's count
    String host; // for TLS verification
    bool cert_failed;
    uint connect_op;

    UsListenSocket* listener;
    UsContext* ctx;
    List{uint} backlog;
    uint accept_op;

    int pid; // PIPE: the child it belongs to
}


const usz READ_CHUNK = 64 * 1024;
const usz INBOX_HIGH = 256 * 1024;

fn void init_res() {
    g_runtime.res.init(mem, 64);
    g_runtime.res_free.init(mem, 64);
    for (CInt fd = 0; fd < 3; fd++) res_new(STDIO).fd = fd;
}

fn Res* res_new(ResKind kind) {
    Res* r = mem::new(Res);
    r.kind = kind;
    r.fd = -1;
    r.inbox.init(mem);
    r.outbox.init(mem);
    r.backlog.init(mem);
    uint slot;
    if (g_runtime.res_free.len()) {
        slot = g_runtime.res_free.pop()!!;
        g_runtime.res[slot] = r;
    } else {
        slot = (uint)g_runtime.res.len();
        g_runtime.res.push(r);
    }
    g_runtime.res_gen = (g_runtime.res_gen + 1) & 0xFFF;
    r.rid = g_runtime.res_gen << SLOT_BITS | slot;
    // stdio keeps rids 0, 1 and 2.
    if (slot < 3) r.rid = slot;
    return r;
}

fn Res* res_find(uint rid) {
    uint slot = rid & SLOT_MASK;
    if (slot >= g_runtime.res.len()) return null;
    Res* r = g_runtime.res[slot];
    return r && r.rid == rid ? r : null;
}

// Freed once both JS and the OS are done with it.
fn void res_release(Res* r) {
    if (!r.closed || !r.gone || r.busy) return;
    uint slot = r.rid & SLOT_MASK;
    g_runtime.res[slot] = null;
    g_runtime.res_free.push(slot);
    r.inbox.free();
    r.outbox.free();
    r.backlog.free();
    if (r.host.len) free(r.host.ptr);
    free(r);
}

fn Res* JsCtx.res(self, uint i = 0) {
    Res* r = res_find(self.arg(i).id());
    if (!r || r.closed) self.throw_coded("EBADF", "bad resource id");
    return r && !r.closed ? r : null;
}

// ---- delivering reads ----

// Settles a pending read from the inbox or the end state.
fn void Res.deliver(&self) {
    defer self.update_ref();
    if (!self.read_op) return;
    uint op = self.read_op;
    if (self.inbox.len()) {
        self.read_op = 0;
        char[] data = copy_bytes(self.inbox.array_view());
        self.inbox.clear();
        if (self.paused) self.resume();
        resolve_bytes(op, data);
        return;
    }
    if (self.cert_failed && self.gone) {
        self.read_op = 0;
        reject(op, "CERT_INVALID", string::tformat("TLS certificate for %s failed verification", self.host));
        return;
    }
    if (self.error) {
        self.read_op = 0;
        reject_errno(op, self.error, "read");
        return;
    }
    if (self.eof || self.gone) {
        self.read_op = 0;
        resolve(op, g_runtime.rt.null_value() ?? { });
    }
}

// A weak socket counts toward the loop's liveness only while JS waits on it,
// so an unread fetch body does not keep the process running.
fn void Res.update_ref(&self) {
    bool want = !self.weak || self.read_op || self.write_op || !self.sock;
    if (want == !self.unrefd) return;
    self.unrefd = !want;
    uws_loop_ref_delta(g_runtime.loop, want ? 1 : -1);
}

// ---- pool reads and writes on fds ----

struct FdTask {
    inline Task task;
    Res* res;
    uint op;
    char[] buf;
    sz n;
    CInt err;
}

fn void fd_finish(Res* r) {
    if (!r.closed || r.gone) return;
    libc::close(r.fd);
    r.gone = true;
}

fn void fd_read_work(Task* t) {
    FdTask* f = (FdTask*)t;
    f.buf = mem::alloc_array(char, READ_CHUNK);
    f.n = libc::read(f.res.fd, f.buf.ptr, f.buf.len);
    if (f.n < 0) f.err = libc::errno();
}

fn void fd_read_done(Task* t) {
    FdTask* f = (FdTask*)t;
    Res* r    = f.res;
    r.busy = false;
    fd_finish(r);
    defer free(f);
    if (f.n < 0) {
        free(f.buf.ptr);
        reject_errno(f.op, f.err, "read");
    } else if (f.n == 0) {
        free(f.buf.ptr);
        resolve(f.op, g_runtime.rt.null_value() ?? { });
    } else {
        resolve_bytes(f.op, f.buf[:f.n]);
    }
    res_release(r);
}

fn void fd_write_work(Task* t) {
    FdTask* f = (FdTask*)t;
    char[] b  = f.buf;
    while (b.len) {
        sz n = libc::write(f.res.fd, b.ptr, b.len);
        if (n < 0) {
            if (libc::errno() == Errno.EINTR) continue;
            f.err = libc::errno();
            return;
        }
        b = b[n..];
        f.n += n;
    }
}

fn void fd_write_done(Task* t) {
    FdTask* f = (FdTask*)t;
    Res* r    = f.res;
    r.busy = false;
    fd_finish(r);
    free(f.buf.ptr);
    defer free(f);
    if (f.err) {
        reject_errno(f.op, f.err, "write");
    } else {
        resolve_number(f.op, f.n);
    }
    res_release(r);
}

fn void fd_task(Res* r, uint op, TaskFn work, TaskFn done, char[] buf = { }) {
    FdTask* f = mem::new(FdTask);
    *f = { .task = { .work = work, .done = done }, .res = r, .op = op, .buf = buf };
    r.busy = true;
    submit(f);
}

// ---- natives ----

// read(op, rid) -> Uint8Array, or null at the end
fn void js_read(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    Res* r  = res_find(ctx.arg(1).id());
    if (!r || r.closed) {
        reject(op, "EBADF", "bad resource id");
        return;
    }
    if (r.read_op || r.busy) {
        reject(op, "EBUSY", "a read is already pending");
        return;
    }
    switch (r.kind) {
        case SOCKET:
            r.read_op = op;
            r.deliver();
        case STDIO:
        case FILE:
        case PIPE:
            fd_task(r, op, &fd_read_work, &fd_read_done);
        case LISTENER:
            reject(op, "EINVAL", "cannot read a listener");
    }
}

// write(op, rid, bytes) -> bytes written, once all of them are
fn void js_write(JsCtx ctx, void* udata) {
    uint op = ctx.arg(0).id();
    Res* r  = res_find(ctx.arg(1).id());
    if (!r || r.closed) {
        reject(op, "EBADF", "bad resource id");
        return;
    }
    char[] data = ctx.arg(2).bytes();
    switch (r.kind) {
        case SOCKET:
            r.socket_write(op, data);
        case STDIO:
        case FILE:
        case PIPE:
            if (r.busy) {
                reject(op, "EBUSY", "a write is already pending");
                return;
            }
            fd_task(r, op, &fd_write_work, &fd_write_done, copy_bytes(data));
        case LISTENER:
            reject(op, "EINVAL", "cannot write a listener");
    }
}

fn void close_resource(Res* r) {
    if (!r || r.closed) return;
    r.closed = true;
    switch (r.kind) {
        case SOCKET:
            if (!r.gone) {
                us_socket_close(r.ssl, r.sock, 0, null);
                return;
            }
        case LISTENER:
            if (!r.gone) us_listen_socket_close(0, r.listener);
            r.gone = true;
            foreach (rid : r.backlog) {
                Res* c = res_find(rid);
                if (c) us_socket_close(c.ssl, c.sock, 0, null);
            }
            if (r.accept_op) resolve(r.accept_op, g_runtime.rt.null_value() ?? { });
            r.accept_op = 0;
        case STDIO:
            r.gone = true;
        case FILE:
        case PIPE:
            if (r.busy) break;
            libc::close(r.fd);
            r.gone = true;
    }
    res_release(r);
}

fn void js_close(JsCtx ctx, void* udata) => close_resource(res_find(ctx.arg(0).id()));

// unref(rid): the socket stops keeping the process alive while idle
fn void js_unref(JsCtx ctx, void* udata) {
    Res* r = ctx.res();
    if (!r || r.kind != SOCKET) return;
    r.weak = true;
    r.update_ref();
}

const Native[] RES_NATIVES = {
    { "read", &js_read, 2 },
    { "write", &js_write, 3 },
    { "close", &js_close, 1 },
    { "unref", &js_unref, 1 },
};
