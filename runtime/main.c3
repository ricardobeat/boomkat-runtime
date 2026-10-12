// bkr: a JavaScript runtime on boomkat and uWebSockets.
// 
//     bkr [permission flags] script.js [args...]
module bkr;

import boomkat;
import boomkat::hstring;
import std::io;
import std::collections::list;
import libc;

const String PRELUDE = $embed("js/prelude.js");
const String FETCH   = $embed("js/fetch.js");

struct Builtin {
    String name;
    String source;
}

const Builtin[] BUILTINS = {
    { "http", $embed("js/http.js") },
    { "path", $embed("js/path.js") },
    { "net", $embed("js/net.js") },
    { "file", $embed("js/file.js") },
    { "process", $embed("js/process.js") },
    { "permissions", $embed("js/permissions.js") },
};

List{String} g_args;
long g_time_limit_ms;
String g_main;

fn void exit_now() {
    close_sqlite();
    $if $feat(OP_PROFILE):
        boomkat::vm::opprof_dump();
    $endif
    libc::exit(g_exit_code);
}

// ---- core natives ----

JsValue g_immediate_fire;
bool g_immediate_armed;

fn void on_immediates(void* user) {
    g_immediate_armed = false;
    unhold();
    (void)call_js(g_immediate_fire, { });
}

// immediateArm(): run __bk.immediateFire on the next loop turn.
fn void js_immediate_arm(JsCtx ctx, void* udata) {
    if (g_immediate_armed) return;
    g_immediate_armed = true;
    hold();
    uws_loop_defer(g_loop, &on_immediates, null);
}

extern fn ulong clock_gettime_nsec_np(CInt clock);
const CInt CLOCK_MONOTONIC_RAW = 4;

fn void js_now(JsCtx ctx, void* udata) => ctx.ret_number((double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6);

fn bool url_char(char c) {
    if (c.is_alnum()) return true;
    return !@catch("-._~!$&'()*+,;=:@/?".index_of_char(c));
}

// Plain http(s) URLs only. Returns slash | query << 16 | colon << 32, with
// 0xFFFF for an absent part, or -1 for anything the general parser must see.
fn long url_fast_flags(String u) {
    usz lead = u.starts_with("http://") ? 7 : u.starts_with("https://") ? 8 : 0;
    if (!lead || u.len >= 0xFFFF) return -1;
    usz slash = u.len;
    usz query = 0xFFFF;
    usz colon = 0xFFFF;
    for (usz i = lead; i < u.len; i++) {
        char c = u[i];
        if (!url_char(c)) return -1;
        if (slash == u.len) {
            if (c == '/') {
                slash = i;
                continue;
            }
            if (c == '@' || c == '?' || c.is_upper()) return -1;
            if (c == ':') {
                colon = i;
                continue;
            }
            if (colon != 0xFFFF && !c.is_digit()) return -1;
            continue;
        }
        if (c == '?' && query == 0xFFFF) query = i;
        if (c == '.' && query == 0xFFFF && u[i - 1] == '/') {
            bool one = i + 1 == u.len || u[i + 1] == '/' || u[i + 1] == '?';
            bool two = i + 1 < u.len && u[i + 1] == '.' && (i + 2 == u.len || u[i + 2] == '/' || u[i + 2] == '?');
            if (one || two) return -1;
        }
    }
    if (slash == lead || (colon != 0xFFFF && colon + 1 == slash) || colon == lead) return -1;
    return (long)(slash | query << 16 | colon << 32);
}

fn void js_url_fast(JsCtx ctx, void* udata) {
    ctx.ret_number((double)url_fast_flags((String)ctx.arg(0).bytes()));
}

extern fn void arc4random_buf(void* buf, usz n);

fn void js_random(JsCtx ctx, void* udata) {
    char[] b = ctx.arg(0).bytes();
    if (b.len) arc4random_buf(b.ptr, b.len);
}

fn void js_encode(JsCtx ctx, void* udata) {
    @pool() {
        String s = ctx.arg(0).as_string() ?? "";
        ctx.ret_bytes(copy_bytes(s));
    };
}

// decode(bytes, fatal) -> string, or null when fatal and the bytes are not
// UTF-8. Invalid sequences otherwise become U+FFFD.
fn void js_decode(JsCtx ctx, void* udata) {
    char[] b = ctx.arg(0).bytes();
    @pool() {
        String? s = utf8_clean(b, ctx.arg(1).as_bool() ?? false);
        if (catch s) {
            ctx.ret_null();
            return;
        }
        ctx.ret_string(s);
    };
}

faultdef INVALID_UTF8;

fn String? utf8_clean(char[] b, bool fatal) {
    usz bad = utf8_valid_prefix(b);
    if (bad == b.len) return (String)b;
    if (fatal) return INVALID_UTF8~;
    DString out = dstring::temp_with_capacity(b.len + 8);
    while (b.len) {
        usz ok = utf8_valid_prefix(b);
        out.append((String)b[:ok]);
        if (ok == b.len) break;
        out.append("\xEF\xBF\xBD");
        b = b[ok + utf8_bad_len(b[ok..])..];
    }
    return out.str_view();
}

fn usz utf8_seq_len(char[] b) {
    char c  = b[0];
    usz n;
    uint lo = 0x80;
    uint hi = 0xBF;
    switch {
        case c < 0x80: return 1;
        case c >= 0xC2 && c < 0xE0: n = 2;
        case c == 0xE0: n = 3; lo = 0xA0;
        case c == 0xED: n = 3; hi = 0x9F;
        case c > 0xE0 && c < 0xF0: n = 3;
        case c == 0xF0: n = 4; lo = 0x90;
        case c == 0xF4: n = 4; hi = 0x8F;
        case c > 0xF0 && c < 0xF4: n = 4;
        default: return 0;
    }
    if (b.len < n || b[1] < lo || b[1] > hi) return 0;
    for (usz i = 2; i < n; i++) if (b[i] & 0xC0 != 0x80) return 0;
    return n;
}

fn usz utf8_valid_prefix(char[] b) {
    if (hstring::check_is_ascii(b)) return b.len;
    usz i = 0;
    while (i < b.len) {
        if (b[i] < 0x80) {
            i++;
            continue;
        }
        usz n = utf8_seq_len(b[i..]);
        if (!n) return i;
        i += n;
    }
    return i;
}

// One U+FFFD per maximal invalid subpart, as the Encoding spec has it.
fn usz utf8_bad_len(char[] b) {
    usz i = 1;
    while (i < b.len && i < 4 && b[i] & 0xC0 == 0x80 && !utf8_seq_len(b[i..])) i++;
    return b[0] >= 0xC2 && b[0] < 0xF5 ? i : 1;
}

fn void js_cwd(JsCtx ctx, void* udata) {
    @pool() {
        ctx.ret_string((String)(path::tcwd() ?? (Path)"/"));
    };
}

fn void js_print(JsCtx ctx, void* udata) {
    char[] b = ctx.arg(1).bytes();
    CInt fd  = ctx.arg(0).as_int(1) == 2 ? 2 : 1;
    while (b.len) {
        sz n = libc::write(fd, b.ptr, b.len);
        if (n <= 0) break;
        b = b[n..];
    }
}

fn Perm? JsArg.perm(self) => perm_named(self.as_string() ?? "");

fn String JsArg.perm_item(self, Perm p) {
    String item = self.as_string() ?? "";
    if (item.len && (p == READ || p == WRITE)) return canonical(item);
    return item;
}

fn void js_perm_query(JsCtx ctx, void* udata) {
    @pool() {
        Perm? p = ctx.arg(0).perm();
        if (catch p) return;
        String item =  ctx.arg(1).perm_item(p);
        int port    = -1;
        if (p == NET) {
            HostPort hp = split_host_port(item);
            item = hp.host;
            port = hp.port;
        }
        ctx.ret_number(query(p, item, port).ordinal);
    };
}

fn void js_perm_request(JsCtx ctx, void* udata) {
    @pool() {
        Perm? p = ctx.arg(0).perm();
        if (catch p) return;
        String item =  ctx.arg(1).perm_item(p);
        int port    = -1;
        if (p == NET) {
            HostPort hp = split_host_port(item);
            item = hp.host;
            port = hp.port;
        }
        PermState s = query(p, item, port);
        if (s == PROMPT) s = ask(p, item.len ? item : "*", port) ? GRANTED : DENIED;
        ctx.ret_number(s.ordinal);
    };
}

fn void js_perm_revoke(JsCtx ctx, void* udata) {
    @pool() {
        Perm? p = ctx.arg(0).perm();
        if (catch p) return;
        revoke(p, ctx.arg(1).perm_item(p));
    };
}

struct HostPort {
    String host;
    int port;
}

fn HostPort split_host_port(String s) {
    if (try colon = s.rindex_of_char(':')) {
        if (try port = s[colon + 1..].to_int()) return { s[:colon], port };
    }
    return { s, -1 };
}

const Native[] CORE_NATIVES = {
    { "immediateArm", &js_immediate_arm, 0 },
    { "now", &js_now, 0 },
    { "urlFast", &js_url_fast, 1 },
    { "random", &js_random, 1 },
    { "encode", &js_encode, 1 },
    { "decode", &js_decode, 2 },
    { "cwd", &js_cwd, 0 },
    { "print", &js_print, 2 },
    { "permQuery", &js_perm_query, 2 },
    { "permRequest", &js_perm_request, 2 },
    { "permRevoke", &js_perm_revoke, 2 },
};

// ---- modules ----

// Built-ins are defined up front; anything else is a file, by path or
// relative to its importer. A bare name that is not a built-in is an error.
fn char[]? read_module(String name, void* udata) {
    if (!name.starts_with("/")) return MODULE_NOT_FOUND~;
    return boomkat::read_module_file(name);
}

faultdef MODULE_NOT_FOUND, USAGE;

fn JsValue? bk_get(String name) => g_rt.get(g_bk, name);

fn void? boot() {
    g_loop = uws_loop();
    g_rt.set_module_reader(&read_module);
    g_rt.open()!;
    install_natives(CORE_NATIVES)!;
    install_natives(WEB_NATIVES)!;
    install_natives(HTTP_NATIVES)!;
    install_natives(RES_NATIVES)!;
    install_natives(NET_NATIVES)!;
    install_natives(FS_NATIVES)!;
    install_natives(PROC_NATIVES)!;
    install_natives(TIMER_NATIVES)!;
    install_natives(IMMEDIATE_NATIVES)!;
    g_rt.exec(PRELUDE, "<prelude>")!;
    g_rt.exec(FETCH, "<fetch>")!;
    foreach (b : BUILTINS) g_rt.define_module(b.name, b.source)!;
    if (init_sqlite()) {
        install_natives(SQLITE_NATIVES)!;
        g_rt.define_module("sqlite", $embed("js/sqlite.js"))!;
    }
    g_settle = bk_get("settle")!;
    g_immediate_fire = bk_get("immediateFire")!;
    g_dispatch = bk_get("dispatch")!;
    g_handled = bk_get("handled")!;
    g_failed = bk_get("failed")!;
    g_pump = bk_get("pump")!;
    g_drain = bk_get("drain")!;
    g_aborted = bk_get("aborted")!;
    g_unhandled = bk_get("unhandled")!;
    g_describe = bk_get("describe")!;
    init_guard();
    init_timers();
    init_immediates();
    init_res();
    init_http()!;
}

fn void usage() {
    io::eprintn(
        "usage: bkr check script.js | bkr [--allow-<perm>[=list]] [--deny-<perm>=list] [-A] [--no-prompt] [--no-sandbox] [--config file] [--time-limit=ms] script.js [args...]"
    );
    io::eprintn("permissions: net read write env run ffi sys import");
}

fn void? parse_args(String[] argv) {
    String config = "";
    usz i         = 1;
    for (; i < argv.len; i++) {
        String a = argv[i];
        if (!a.starts_with("-")) break;
        if (a == "--config" && i + 1 < argv.len) {
            config = argv[++i];
            continue;
        }
        if (a == "--no-sandbox") {
            g_sandbox = false;
            continue;
        }
        if (a.starts_with("--time-limit=")) {
            g_time_limit_ms = a[13..].to_long() ?? USAGE~!;
            continue;
        }
        if (!parse_perm_flag(a)!) return USAGE~;
    }
    if (i >= argv.len) return USAGE~;
    g_main = absolute(argv[i]).copy(mem);
    g_args.init(mem);
    foreach (a : argv[i + 1..]) g_args.push(a);

    if (!config.len) {
        String beside = string::tformat("%s/boomkat.toml", g_main[:g_main.rindex_of_char('/')!!]);
        if (file::is_file(beside)) config = beside;
    }
    if (config.len) {
        // Flags win: they are applied again on top of the file.
        if (catch err = load_config(config)) {
            io::eprintfn("error: bad config %s: %s", config, err);
            return USAGE~;
        }
        for (usz j = 1; j < i; j++) (void)parse_perm_flag(argv[j]);
    }
}

fn int main(String[] argv) {
    defer close_sqlite();
    if (argv.len == 3 && argv[1] == "check") {
        init_perms();
        return check_main(argv[2]);
    }
    init_perms();
    g_perms.prompt = libc::isatty(0) != 0 && libc::isatty(2) != 0;
    if (catch parse_args(argv)) {
        usage();
        return 2;
    }
    if (catch err = boot()) {
        io::eprintfn("error: bootstrap failed: %s: %s", err, g_rt.last_error());
        return 1;
    }
    char[]? src = file::load(mem, g_main);
    if (catch err = src) {
        io::eprintfn("error: cannot read %s: %s", g_main, err);
        return 1;
    }
    apply_sandbox();
    g_depth++;
    JsValue? ns = g_rt.eval_module((String)src, g_main);
    g_depth--;
    if (catch err = ns) {
        io::eprintfn("error: %s", g_rt.last_error());
        return 1;
    }
    g_rt.release(ns);
    flush_rejections();
    if (g_time_limit_ms) start_watchdog(g_time_limit_ms);
    uws_loop_run();
    return g_exit_code;
}
