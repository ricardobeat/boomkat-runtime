// The process module: arguments, environment, exit, and child processes.
module bkr;

import boomkat;
import std::io;
import std::collections::list;
import libc;

extern fn CInt pipe(CInt* fds);
extern fn CInt fcntl(CInt fd, CInt cmd, ...);
extern fn CInt posix_spawn_file_actions_init(void** actions);
extern fn CInt posix_spawn_file_actions_destroy(void** actions);
extern fn CInt posix_spawn_file_actions_adddup2(void** actions, CInt fd, CInt target);
extern fn CInt posix_spawn_file_actions_addopen(void** actions, CInt fd, ZString path, CInt flags, ushort mode);
extern fn CInt posix_spawn_file_actions_addchdir_np(void** actions, ZString path);
extern fn CInt posix_spawnp(CInt* pid, ZString file, void** actions, void* attr, ZString* argv, ZString* envp);
extern fn CInt waitpid(CInt pid, CInt* status, CInt options);
extern fn CInt kill(CInt pid, CInt sig);
extern fn CInt getpid();

const CInt F_SETFD    = 2;
const CInt FD_CLOEXEC = 1;

// ---- environment ----

fn void js_env_get(JsCtx ctx, void* udata) {
    @pool() {
        String name = ctx.arg(0).as_string() ?? "";
        if (!check_env(name)) {
            ctx.throw_coded(
                "PERMISSION_DENIED",
                string::tformat("env access to \"%s\" denied; run with --allow-env", name)
            );
            return;
        }
        ZString v = libc::getenv(name.zstr_tcopy());
        if (v) ctx.ret_string(v.str_view());
    };
}

fn void js_env_set(JsCtx ctx, void* udata) {
    @pool() {
        String name = ctx.arg(0).as_string() ?? "";
        if (!check_env(name)) {
            ctx.throw_coded(
                "PERMISSION_DENIED",
                string::tformat("env access to \"%s\" denied; run with --allow-env", name)
            );
            return;
        }
        String value = ctx.arg(1).as_string() ?? "";
        libc::setenv(name.zstr_tcopy(), value.zstr_tcopy(), 1);
    };
}

fn void js_env_delete(JsCtx ctx, void* udata) {
    @pool() {
        String name = ctx.arg(0).as_string() ?? "";
        if (!check_env(name)) {
            ctx.throw_coded(
                "PERMISSION_DENIED",
                string::tformat("env access to \"%s\" denied; run with --allow-env", name)
            );
            return;
        }
        libc::unsetenv(name.zstr_tcopy());
    };
}

// Whole environment as "K=V\n" lines; needs an unrestricted env grant.
fn void js_env_all(JsCtx ctx, void* udata) {
    @pool() {
        if (!check_env("*")) {
            ctx.throw_coded("PERMISSION_DENIED", "env access to the whole environment denied; run with --allow-env");
            return;
        }
        DString out = dstring::temp();
        for (ZString* e = environment(); *e; e++) out.appendf("%s\n", *e);
        ctx.ret_string(out.str_view());
    };
}

fn void js_args(JsCtx ctx, void* udata) {
    @pool() {
        DString out = dstring::temp();
        foreach (a : g_runtime.args) out.appendf("%s\n", a);
        ctx.ret_string(out.str_view());
    };
}

fn void js_main(JsCtx ctx, void* udata) => ctx.ret_string(g_runtime.main);

fn void js_pid(JsCtx ctx, void* udata) => ctx.ret_number(getpid());

extern fn CInt ns_get_executable_path(char* buf, uint* size) @cname("_NSGetExecutablePath") @if(env::DARWIN);

// The running binary, so scripts can start another bkr.
fn void js_exec_path(JsCtx ctx, void* udata) {
    char[1024] raw;
    $if env::DARWIN:
        uint size = raw.len;
        if (ns_get_executable_path(&raw, &size) != 0) raw[0] = 0;
    $else
        raw[..] = 0;
        mem::copy(&raw, "/proc/self/exe", 14);
    $endif
    char[1024] real;
    if (!raw[0] || !realpath((ZString)&raw, &real)) {
        ctx.ret_string("");
        return;
    }
    ctx.ret_string(((ZString)&real).str_view());
}

fn void js_exit(JsCtx ctx, void* udata) {
    g_runtime.exit_code = ctx.arg(0).as_int(0);
    exit_now();
}

// ---- children ----

struct WaitTask {
    inline Task task;
    uint op;
    CInt pid;
    CInt status;
    CInt err;
}

fn void wait_work(Task* t) {
    WaitTask* w = (WaitTask*)t;
    while (waitpid(w.pid, &w.status, 0) < 0) {
        if (libc::errno() == Errno.EINTR) continue;
        w.err = libc::errno();
        return;
    }
}

// run_inherit(argv) runs a child on this terminal and environment, and waits
// for it. Used by `bkr test --watch`, which needs no grant of its own.
fn void run_inherit(String[] argv) {
    @pool() {
        List{ZString} list;
        list.tinit();
        foreach (a : argv) list.push(a.zstr_tcopy());
        list.push(null);
        void* actions;
        posix_spawn_file_actions_init(&actions);
        defer posix_spawn_file_actions_destroy(&actions);
        CInt pid;
        if (posix_spawnp(&pid, argv[0].zstr_tcopy(), &actions, null, list.entries, environment())) {
            io::eprintfn("error: cannot run %s", argv[0]);
            return;
        }
        CInt status;
        while (waitpid(pid, &status, 0) < 0) {
            if (libc::errno() != Errno.EINTR) return;
        }
    };
}

fn void wait_done(Task* t) {
    WaitTask* w = (WaitTask*)t;
    defer free(w);
    if (w.err) {
        reject_errno(w.op, w.err, "wait");
        return;
    }
    int code = (w.status & 0x7f) == 0 ? (w.status >> 8) & 0xff : -(w.status & 0x7f);
    resolve_number(w.op, code);
}

// wait(op, pid) -> exit code, or minus the signal that ended it
fn void js_wait(JsCtx ctx, void* udata) {
    WaitTask* w = mem::new(WaitTask);
    *w = { .task = { .work = &wait_work, .done = &wait_done }, .op = ctx.arg(0).id(), .pid = ctx.arg(1).as_int(0) };
    submit(w);
}

fn void js_kill(JsCtx ctx, void* udata) => (void)kill(ctx.arg(0).as_int(0), ctx.arg(1).as_int(15));

// spawn(command, "arg\narg", "K=V\nK=V" or "", cwd or "", "ppp") -> "pid in out err"
// stdio is one char per stream: p piped, i inherited, n null.
fn void js_spawn(JsCtx ctx, void* udata) {
    @pool() {
        String cmd = ctx.arg(0).as_string() ?? "";
        if (!check(RUN, cmd)) {
            ctx.throw_coded(
                "PERMISSION_DENIED",
                string::tformat("run access to \"%s\" denied; run with --allow-run", cmd)
            );
            return;
        }
        String args  = ctx.arg(1).as_string() ?? "";
        String env   = ctx.arg(2).as_string() ?? "";
        String cwd   = ctx.arg(3).as_string() ?? "";
        String stdio = ctx.arg(4).as_string() ?? "iii";
        List{ZString} argv;
        argv.tinit();
        argv.push(cmd.zstr_tcopy());
        if (args.len) foreach (a : args.tsplit("\n")) argv.push(a.zstr_tcopy());
        argv.push(null);
        List{ZString} envp;
        envp.tinit();
        if (env.len) {
            foreach (e : env.tsplit("\n")) envp.push(e.zstr_tcopy());
            envp.push(null);
        }
        void* actions;
        posix_spawn_file_actions_init(&actions);
        defer posix_spawn_file_actions_destroy(&actions);
        if (cwd.len) posix_spawn_file_actions_addchdir_np(&actions, cwd.zstr_tcopy());
        CInt[3] parent = { -1, -1, -1 };
        CInt[3] child  = { -1, -1, -1 };
        for (int i = 0; i < 3; i++) {
            char mode = i < stdio.len ? stdio[i] : 'i';
            if (mode == 'i') continue;
            if (mode == 'n') {
                posix_spawn_file_actions_addopen(&actions, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0);
                continue;
            }
            CInt[2] fds;
            if (pipe(&fds) != 0) {
                ctx.throw_coded(errno_code(libc::errno()), "pipe");
                return;
            }
            parent[i] = i == 0 ? fds[1] : fds[0];
            child[i] = i == 0 ? fds[0] : fds[1];
            fcntl(parent[i], F_SETFD, FD_CLOEXEC);
            fcntl(child[i], F_SETFD, FD_CLOEXEC);
            posix_spawn_file_actions_adddup2(&actions, child[i], i);
        }
        CInt pid;
        CInt rc = posix_spawnp(
            &pid,
            cmd.zstr_tcopy(),
            &actions,
            null,
            argv.entries,
            env.len ? envp.entries : environment()
        );
        for (int i = 0; i < 3; i++) {
            if (child[i] >= 0) libc::close(child[i]);
        }
        if (rc) {
            for (int i = 0; i < 3; i++) {
                if (parent[i] >= 0) libc::close(parent[i]);
            }
            ctx.throw_coded(errno_code(rc), string::tformat("%s: %s", cmd, errno_text(rc)));
            return;
        }
        DString out = dstring::temp();
        out.appendf("%d", pid);
        for (int i = 0; i < 3; i++) {
            if (parent[i] < 0) {
                out.append(" -1");
                continue;
            }
            Res* r = res_new(PIPE);
            r.fd = parent[i];
            r.pid = pid;
            out.appendf(" %d", r.rid);
        }
        ctx.ret_string(out.str_view());
    };
}

const Native[] PROC_NATIVES = {
    { "envGet", &js_env_get, 1 },
    { "envSet", &js_env_set, 2 },
    { "envDelete", &js_env_delete, 1 },
    { "envAll", &js_env_all, 0 },
    { "args", &js_args, 0 },
    { "mainPath", &js_main, 0 },
    { "execPath", &js_exec_path, 0 },
    { "pid", &js_pid, 0 },
    { "exit", &js_exit, 1 },
    { "wait", &js_wait, 2 },
    { "kill", &js_kill, 2 },
    { "spawn", &js_spawn, 5 },
};
