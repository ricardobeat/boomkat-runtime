// File responses keep one bounded buffer and one outstanding pool read.
module bkr;

import boomkat;
import libc;
import std::io;

struct NativeFile {
    inline Task task;
    ulong id;
    String path;
    String headers;
    String status_text;
    int status;
    CInt fd;
    CInt err;
    char[] buffer;
    usz length;
    long remaining;
    bool head;
    bool last;
    bool started;
    bool reading;
    bool canceled;
}

fn void native_file_free(NativeFile* f) {
    if (f.fd >= 0) libc::close(f.fd);
    free(f.buffer.ptr);
    free(f.path.ptr);
    free(f.headers.ptr);
    free(f.status_text.ptr);
    free(f);
}

fn void native_file_abort(NativeFile* f) {
    f.canceled = true;
    if (!f.reading) native_file_free(f);
}

fn void native_file_work(Task* task) {
    NativeFile* f = (NativeFile*)task;
    if (f.fd < 0) {
        f.fd = open(f.path.zstr_tcopy(), O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC);
        if (f.fd < 0) {
            f.err = libc::errno();
            return;
        }
        Stat st;
        if (fstat(f.fd, &st) < 0) {
            f.err = libc::errno();
            return;
        }
        if ((st.st_mode & libc::S_IFMT) != libc::S_IFREG) {
            f.err = Errno.EINVAL;
            return;
        }
        f.remaining = st.st_size;
        if (f.head || f.remaining == 0) {
            f.last = true;
            return;
        }
        f.buffer = mem::alloc_array(char, (usz)min(f.remaining, (long)65536));
    }
    f.length = 0;
    usz limit = (usz)min(f.remaining, (long)f.buffer.len);
    while (f.length < limit) {
        sz n = libc::read(f.fd, f.buffer.ptr + f.length, limit - f.length);
        if (n < 0) {
            if (libc::errno() == Errno.EINTR) continue;
            f.err = libc::errno();
            return;
        }
        if (n == 0) {
            f.last = true;
            break;
        }
        f.length += (usz)n;
    }
    f.remaining -= (long)f.length;
    if (f.remaining == 0) f.last = true;
}

fn void native_file_read(NativeFile* f) {
    f.reading = true;
    submit(f);
}

fn CInt native_file_writable(void* user, ulong offset) {
    NativeFile* f = user;
    if (!f.reading && !f.canceled) native_file_read(f);
    return 1;
}

fn void native_file_done(Task* task) {
    NativeFile* f = (NativeFile*)task;
    f.reading = false;
    Conn* c = conn_find(f.id);
    if (f.canceled || !c || c.aborted || !c.res) {
        native_file_free(f);
        return;
    }
    if (f.err) {
        c.file_body = null;
        defer native_file_free(f);
        if (f.started) {
            // Once headers are sent, an I/O error must terminate the transfer.
            uws_res_close(c.res);
        } else {
            response_error(c, errno_code(f.err), string::tformat("%s: %s", f.path, errno_text(f.err)));
        }
        return;
    }
    if (!f.started && f.last) {
        c.file_body = null;
        defer native_file_free(f);
        finish(c, f.status, f.status_text, f.headers, f.buffer[:f.length]);
        return;
    }
    if (!f.started) {
        Reply reply = { c, f.status, f.status_text, f.headers, { }, false };
        corked(c, &write_reply, &reply);
        f.started = true;
        uws_res_on_writable(c.res, &native_file_writable, f);
    }
    Chunk chunk = { c.res, f.buffer[:f.length], false };
    corked(c, &write_chunk, &chunk);
    if (f.last) {
        c.file_body = null;
        defer native_file_free(f);
        corked(c, &end_stream, c);
        done(c);
    } else if (chunk.ok) {
        native_file_read(f);
    }
}

fn void native_file_start(Conn* c, String raw_path, int status, String status_text, String headers) {
    // absolute() resolves cwd only when the supplied path is relative.
    String path = canonical(raw_path);
    if (!check_path(READ, path)) {
        response_error(c, "PERMISSION_DENIED", denied_path(READ, raw_path));
        return;
    }
    NativeFile* f = mem::new(NativeFile);
    *f = {
        .task = { .work = &native_file_work, .done = &native_file_done },
        .id = c.id,
        .path = path.copy(mem),
        .headers = headers.copy(mem),
        .status_text = status_text.copy(mem),
        .status = status,
        .fd = -1,
        .head = c.head || status == 204 || status == 304
    };
    c.file_body = f;
    native_file_read(f);
}