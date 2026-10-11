module bkr;

import libc;

extern fn ZString strerror(CInt err);

fn String errno_text(CInt err) => strerror(err).str_view();

fn String errno_code(CInt err) {
    switch (err) {
        case Errno.ENOENT: return "ENOENT";
        case Errno.EACCES: return "EACCES";
        case Errno.EPERM: return "EPERM";
        case Errno.EEXIST: return "EEXIST";
        case Errno.ENOTDIR: return "ENOTDIR";
        case Errno.EISDIR: return "EISDIR";
        case Errno.ENOTEMPTY: return "ENOTEMPTY";
        case Errno.EBADF: return "EBADF";
        case Errno.EINVAL: return "EINVAL";
        case Errno.EMFILE: return "EMFILE";
        case Errno.ELOOP: return "ELOOP";
        case Errno.EPIPE: return "EPIPE";
        case Errno.EAGAIN: return "EAGAIN";
        case Errno.EADDRINUSE: return "EADDRINUSE";
        case Errno.ECONNREFUSED: return "ECONNREFUSED";
        case Errno.ECONNRESET: return "ECONNRESET";
        case Errno.ETIMEDOUT: return "ETIMEDOUT";
        case Errno.EHOSTUNREACH: return "EHOSTUNREACH";
        case Errno.ENOSPC: return "ENOSPC";
        case Errno.EXDEV: return "EXDEV";
        case Errno.ESRCH: return "ESRCH";
        default: return "EIO";
    }
}