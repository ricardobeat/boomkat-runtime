// The JS-backed HTTP server on uWebSockets, with a fetch-style handler: the
// script evaluates to `{ fetch(req) { ... } }` (or a bare function) taking a
// Request and returning a Response or a Promise of one, the shape Bun, Deno
// and Cloudflare Workers share.
//
// uWebSockets is C++, so it is reached through the extern "C" shim in
// shim/uws_shim.cpp; build it with scripts/build_uws.sh first. The shim is a
// set of pass-throughs. Everything that decides anything lives here: reading
// the request, buffering its body, tracking responses that finish later,
// writing the Response back, and timers. The Web API classes themselves are
// JS, in prelude.c3.
//
// With more than one thread each gets its own Worker -- its own runtime, heap
// and handler -- and the shim's cluster spreads accepted sockets across them.
// The engine has no locking, but two threads driving separate runtimes share
// nothing, and every runtime is opened and bootstrapped on the main thread
// before any worker starts, so the engine's process-global init and the
// compiler are never touched concurrently.
module test_server_uws;

import boomkat;
import std::io;
import std::io::file;
import std::core::mem;
import std::collections::list;
import std::thread;

const int DEFAULT_PORT = 8080;
const int MAX_THREADS = 64;

// Used when no script is given. Same output as the old (method, url) handler,
// so bodies still match node and bun in bench/run.sh.
const String DEFAULT_SCRIPT = `
({
    fetch(req) {
        return new Response(req.method + " " + new URL(req.url).pathname);
    }
})
`;

// Request bodies above this are refused with 413 rather than buffered.
const sz MAX_REQUEST_BODY = 16 * 1024 * 1024;

// ---- the shim ----

typedef UwsReq = void;
typedef UwsRes = void;

alias UwsReqCb = fn void(void* user, UwsReq* req, UwsRes* res);
alias UwsDataCb = fn void(void* user, char* chunk, sz len, CInt last);
alias UwsVoidCb = fn void(void* user);

extern fn sz uws_req_method(UwsReq* req, char** out);
extern fn sz uws_req_url(UwsReq* req, char** out);
extern fn sz uws_req_query(UwsReq* req, char** out);
struct UwsHeader
{
    char* key;
    sz key_len;
    char* val;
    sz val_len;
}
extern fn CInt uws_req_headers(UwsReq* req, UwsHeader* out, CInt cap);

extern fn void uws_res_on_data(UwsRes* res, UwsDataCb cb, void* user);
extern fn void uws_res_on_aborted(UwsRes* res, UwsVoidCb cb, void* user);
extern fn void uws_res_write_status(UwsRes* res, char* status, sz len);
extern fn void uws_res_write_header(UwsRes* res, char* key, sz key_len, char* val, sz val_len);
extern fn void uws_res_end(UwsRes* res, char* body, sz len);
extern fn void uws_res_cork(UwsRes* res, UwsVoidCb cb, void* user);

extern fn void* uws_timer_start(CInt ms, UwsVoidCb cb, void* user);
extern fn void uws_timer_cancel(void* timer);

// Runs one event loop on the calling thread and blocks. `index` and `nthreads`
// place this loop in the cluster that redistributes accepted sockets; see the
// shim for why that is needed on macOS.
extern fn CInt uws_run_one(CInt port, UwsReqCb cb, void* user, CInt index, CInt nthreads);

// ---- state ----

// A request in flight: from arrival until JS responds. It outlives the uWS
// callback whenever the body has to be read or the handler is async, which is
// why it is heap-allocated and found again by id from JS.
struct Conn
{
    Worker* w;
    uint id;
    UwsRes* res;
    bool aborted;     // the client went away; res must not be touched again
    bool in_request;  // inside the uWS request callback, which corks for us

    // The request's parts, read lazily: JS asks for the URL and headers only
    // when the handler touches them. While the request callback runs they
    // come straight from uWS through `req` and `hdrs`. A Conn that outlives
    // the callback captures them onto the heap first, since uWS recycles the
    // request as soon as the callback returns.
    UwsReq* req;
    UwsHeader[] hdrs;
    String path;
    String query;
    String method;    // heap copies, once captured
    String url;
    String blob;
    List{char} body;
}

// One per thread. Never shared: the thread that owns a Worker is the only one
// that touches its runtime.
struct Worker
{
    int index;
    JsRuntime rt;
    JsValue dispatch;                         // __dispatch, rooted for the process
    JsValue timer_fire;                       // __timer_fire, ditto
    JsValue[METHODS.len] methods;             // interned once, indexed like METHODS

    // Live Conns by slot. A Conn's id is its slot plus a generation in the
    // high bits, so a stale id from JS can never reach a recycled slot.
    List{Conn*} conns;
    List{uint} free_slots;
    List{Conn*} spare;
    uint generation;
}

Worker[MAX_THREADS] g_workers;
int g_port;
int g_threads;
String g_script;

// Skips the JS engine entirely and answers in C3. Not a mode to serve with --
// it exists to attribute cost, by showing what the HTTP frontend alone can do.
bool g_no_js;

// uWS reports methods lowercase. These are matched against that and handed to
// JS uppercase, as the Fetch spec normalises them.
const String[] METHODS = { "GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH" };
const String[] METHODS_LOWER = { "get", "post", "head", "put", "delete", "options", "patch" };

// Size of a worker's temp arena. Each request resets it, so this only has to
// hold one request's strings, but it is the thread's whole budget for tmem.
const sz WORKER_POOL = 256 * 1024;

const uint SLOT_BITS = 20;
const uint SLOT_MASK = (1u << SLOT_BITS) - 1;

// ---- conn table ----

fn Conn* Worker.conn_new(&self, UwsRes* res)
{
    // Recycled rather than malloc'd: one per request adds up.
    Conn* c = self.spare.len() ? self.spare.pop()!! : mem::new(Conn);
    c.w = self;
    c.res = res;
    uint slot;
    if (self.free_slots.len())
    {
        slot = self.free_slots.pop()!!;
        self.conns[slot] = c;
    }
    else
    {
        slot = (uint)self.conns.len();
        self.conns.push(c);
    }
    self.generation = (self.generation + 1) & ((1u << (32 - SLOT_BITS)) - 1);
    c.id = (self.generation << SLOT_BITS) | slot;
    return c;
}

fn Conn* Worker.conn_find(&self, uint id)
{
    uint slot = id & SLOT_MASK;
    if (slot >= self.conns.len()) return null;
    Conn* c = self.conns[slot];
    if (c == null || c.id != id) return null;
    return c;
}

fn void Worker.conn_free(&self, Conn* c)
{
    uint slot = c.id & SLOT_MASK;
    self.conns[slot] = null;
    self.free_slots.push(slot);
    if (c.method.len) free(c.method.ptr);
    if (c.url.len) free(c.url.ptr);
    if (c.blob.len) free(c.blob.ptr);
    if (c.body.is_initialized()) c.body.free();
    *c = {};
    if (self.spare.len() < 1024)
    {
        self.spare.push(c);
    }
    else
    {
        free(c);
    }
}

// ---- reading the request ----

fn String upper_method(String lower) @inline
{
    foreach (i, m : METHODS_LOWER) if (m == lower) return METHODS[i];
    char[] up = mem::temp_array(char, lower.len);
    foreach (i, ch : lower) up[i] = ch >= 'a' && ch <= 'z' ? ch - 'a' + 'A' : ch;
    return (String)up;
}

// Most requests carry a handful of headers; anything past this is not seen.
const int MAX_HEADERS = 64;

fn bool has_body(UwsHeader[] hdrs)
{
    foreach (h : hdrs)
    {
        String key = (String)h.key[:h.key_len];
        if (key == "content-length") return (String)h.val[:h.val_len] != "0";
        if (key == "transfer-encoding") return true;
    }
    return false;
}

fn String host_of(UwsHeader[] hdrs)
{
    foreach (h : hdrs)
    {
        if ((String)h.key[:h.key_len] == "host") return (String)h.val[:h.val_len];
    }
    return "localhost";
}

// Headers as a "name\nvalue\n" blob, in tmem.
fn String headers_blob(UwsHeader[] hdrs)
{
    sz n = 0;
    foreach (h : hdrs) n += h.key_len + h.val_len + 2;
    char[] out = mem::temp_array(char, n);
    sz at = 0;
    foreach (h : hdrs)
    {
        mem::copy(&out[at], h.key, h.key_len);
        at += h.key_len;
        out[at++] = '\n';
        mem::copy(&out[at], h.val, h.val_len);
        at += h.val_len;
        out[at++] = '\n';
    }
    return (String)out;
}

fn String Conn.url_now(&self)
{
    if (self.url.len) return self.url;
    if (self.req == null) return "";
    return join_url(host_of(self.hdrs), self.path, self.query);
}

fn String Conn.blob_now(&self)
{
    if (self.req == null) return self.blob;
    return headers_blob(self.hdrs);
}

// Copies everything still pointing into uWS onto the heap. Called before the
// request callback returns on any Conn that will outlive it.
fn void Conn.capture(&self, String method)
{
    if (self.req == null) return;
    self.method = method.copy(mem);
    self.url = self.url_now().copy(mem);
    self.blob = self.blob_now().copy(mem);
    self.req = null;
    self.hdrs = {};
}

// "http://" + host + path ["?" + query], in tmem. Plain copies: the
// formatter is measurably slower for this on the per-request path.
fn String join_url(String host, String path, String query)
{
    sz n = 7 + host.len + path.len + (query.len ? query.len + 1 : 0);
    char[] out = mem::temp_array(char, n);
    sz at = 0;
    out[at:7] = "http://"[..];
    at += 7;
    out[at:host.len] = host[..];
    at += host.len;
    out[at:path.len] = path[..];
    at += path.len;
    if (query.len)
    {
        out[at] = '?';
        out[at + 1:query.len] = query[..];
    }
    return (String)out;
}

// ---- calling JS ----

fn void Worker.call_dispatch(&self, Conn* c, String method, String body, bool has_body)
{
    JsValue m = {};
    bool m_cached = false;
    foreach (i, name : METHODS)
    {
        if (name == method) { m = self.methods[i]; m_cached = true; break; }
    }

    JsValue[3] args;
    bool ok = true;
    do
    {
        if (!m_cached)
        {
            JsValue? mv = self.rt.string(method);
            if (catch mv) { ok = false; break; }
            m = mv;
        }
        args[0] = self.rt.number((double)c.id) ?? (JsValue){};
        args[1] = m;
        // An empty handle reaches JS as undefined, which Request reads as no body.
        args[2] = has_body ? self.rt.string(body) ?? (JsValue){} : (JsValue){};
    };

    if (ok)
    {
        JsValue? r = self.rt.call(self.dispatch, args[..]);
        if (catch err = r)
        {
            io::eprintfn("dispatch failed: %s: %s", err, self.rt.last_error());
            ok = false;
        }
        else
        {
            self.rt.release(r);
        }
    }
    for (int i = 2; i < 3; i++) if (!args[i].is_empty()) self.rt.release(args[i]);
    if (!args[0].is_empty()) self.rt.release(args[0]);
    if (!m_cached && !m.is_empty()) self.rt.release(m);

    // __dispatch catches everything the handler does, so this is the engine
    // itself failing. Answer anyway rather than leave the client hanging.
    if (!ok && self.conn_find(c.id) == c) self.finish_plain(c, 500, "Internal Server Error");
}

// ---- writing the response ----

// What one response needs, held while the write runs inside a cork.
struct Reply
{
    Conn* c;
    int status;
    String status_text;
    String blob;
    String body;
}

fn void write_reply(void* user)
{
    Reply* r = (Reply*)user;
    UwsRes* res = r.c.res;

    // 200 is uWS's default, so only another status writes a status line.
    if (r.status != 200)
    {
        String line = string::tformat("%d %s", r.status, r.status_text);
        uws_res_write_status(res, line.ptr, line.len);
    }

    String rest = r.blob;
    while (rest.len)
    {
        sz? nl = rest.index_of_char('\n');
        if (catch nl) break;
        String key = rest[:nl];
        rest = rest[nl + 1..];
        sz? nl2 = rest.index_of_char('\n');
        String val = rest;
        if (try nl2)
        {
            val = rest[:nl2];
            rest = rest[nl2 + 1..];
        }
        else
        {
            rest = "";
        }
        // uWS writes Content-Length itself from the body; a second one would
        // make the response invalid. Transfer-Encoding likewise belongs to it.
        if (key == "content-length" || key == "transfer-encoding") continue;
        uws_res_write_header(res, key.ptr, key.len, val.ptr, val.len);
    }
    uws_res_end(res, r.body.ptr, r.body.len);
}

fn void Worker.finish(&self, Conn* c, int status, String status_text, String blob, String body)
{
    if (!c.aborted)
    {
        Reply r = { c, status, status_text, blob, body };
        // Inside the request callback uWS has already corked the socket.
        // Anywhere else -- a timer, a body read -- the status, headers and
        // body would leave as separate packets without one.
        if (c.in_request)
        {
            write_reply(&r);
        }
        else
        {
            uws_res_cork(c.res, &write_reply, &r);
        }
    }
    // In the request callback the caller still holds c, and frees it on the
    // way out once it sees the response finished.
    if (c.in_request)
    {
        c.res = null;
    }
    else
    {
        self.conn_free(c);
    }
}

fn void Worker.finish_plain(&self, Conn* c, int status, String body)
{
    String text = status == 413 ? "Payload Too Large" : "Internal Server Error";
    self.finish(c, status, text, "content-type\ntext/plain;charset=UTF-8\n", body);
}

// The bytes of a string argument, without copying when that is possible.
//
// Engine strings are CESU-8, which is already UTF-8 for ASCII, so those are
// viewed in place -- valid only for the rest of the host call, which is all
// __respond needs since it writes before returning. Anything else is
// transcoded into tmem.
fn String arg_bytes(JsArg a) @inline
{
    if (!a.tv.is_string()) return "";
    HString* hs = (HString*)a.tv.get_heapptr();
    if (hs.is_ascii()) return (String)hs.get_data();
    return a.as_string() ?? "";
}

// __req_url(id), __req_headers(id): the parts of a request JS reads lazily.
// After the response is sent the Conn is gone and these return "".
fn void host_req_url(JsCtx ctx, void* udata)
{
    Worker* w = (Worker*)udata;
    Conn* c = w.conn_find((uint)(ctx.arg(0).as_number() ?? 0));
    @pool() { ctx.ret_string(c == null ? "" : c.url_now()); };
}

fn void host_req_headers(JsCtx ctx, void* udata)
{
    Worker* w = (Worker*)udata;
    Conn* c = w.conn_find((uint)(ctx.arg(0).as_number() ?? 0));
    @pool() { ctx.ret_string(c == null ? "" : c.blob_now()); };
}

// __respond(id, status, statusText, headerBlob, body)
fn void host_respond(JsCtx ctx, void* udata)
{
    Worker* w = (Worker*)udata;
    @pool()
    {
        double? idn = ctx.arg(0).as_number();
        if (catch idn) { ctx.throw_error(JsErrorKind.TYPE, "__respond: bad id"); return; }
        Conn* c = w.conn_find((uint)idn);
        if (c == null || c.res == null) return;   // already answered

        double status = ctx.arg(1).as_number() ?? 200;
        String text = arg_bytes(ctx.arg(2));
        String blob = arg_bytes(ctx.arg(3));
        String body = arg_bytes(ctx.arg(4));
        w.finish(c, (int)status, text, blob, body);
    };
}

// ---- timers ----

struct Timer
{
    Worker* w;
    void* handle;
    double id;
}

fn void on_timer(void* user)
{
    Timer* t = (Timer*)user;
    Worker* w = t.w;
    double id = t.id;
    free(t);
    @pool()
    {
        JsValue? idv = w.rt.number(id);
        if (catch idv) return;
        defer w.rt.release(idv);
        JsValue[1] args = { idv };
        JsValue? r = w.rt.call(w.timer_fire, args[..]);
        if (catch err = r) { io::eprintfn("timer callback failed: %s: %s", err, w.rt.last_error()); return; }
        w.rt.release(r);
    };
}

// __timer_start(ms, id) -> handle. The handle is the Timer's address, which
// a double holds exactly; JS only ever hands it back to __timer_cancel.
fn void host_timer_start(JsCtx ctx, void* udata)
{
    double ms = ctx.arg(0).as_number() ?? 0;
    double id = ctx.arg(1).as_number() ?? 0;
    Timer* t = mem::new(Timer);
    t.w = (Worker*)udata;
    t.id = id;
    if (ms > 2147483647.0) ms = 2147483647.0;
    t.handle = uws_timer_start((CInt)ms, &on_timer, t);
    ctx.ret_number((double)(uptr)t);
}

// __timer_cancel(handle). Only called for timers that have not fired: JS
// forgets a one-shot before firing it and re-arms an interval with a new one.
fn void host_timer_cancel(JsCtx ctx, void* udata)
{
    double h = ctx.arg(0).as_number() ?? 0;
    if (h == 0) return;
    Timer* t = (Timer*)(uptr)h;
    uws_timer_cancel(t.handle);
    free(t);
}

// ---- request callbacks ----

fn void on_aborted(void* user)
{
    Conn* c = (Conn*)user;
    // JS may still respond later; the Conn stays until it does, and is then
    // freed without writing.
    c.aborted = true;
}

fn void on_data(void* user, char* chunk, sz len, CInt last)
{
    Conn* c = (Conn*)user;
    Worker* w = c.w;
    if (c.res == null) return;   // already refused
    if (c.body.len() + len > MAX_REQUEST_BODY)
    {
        w.finish_plain(c, 413, "Payload Too Large");
        return;
    }
    c.body.push_all(chunk[:len]);
    if (!last) return;

    @pool()
    {
        w.call_dispatch(c, c.method, (String)c.body.array_view(), true);
    };
}

fn void on_request(void* user, UwsReq* req, UwsRes* res)
{
    Worker* w = (Worker*)user;

    char* mp; sz ml = uws_req_method(req, &mp);
    char* up; sz ul = uws_req_url(req, &up);

    if (g_no_js)
    {
        @pool()
        {
            String body = string::tformat("%s %s", upper_method((String)mp[:ml]), (String)up[:ul]);
            uws_res_write_header(res, "content-type", 12, "text/plain;charset=UTF-8", 24);
            uws_res_end(res, body.ptr, body.len);
        };
        return;
    }

    char* qp; sz ql = uws_req_query(req, &qp);

    @pool()
    {
        String method = upper_method((String)mp[:ml]);
        UwsHeader[MAX_HEADERS] hbuf;
        CInt nh = uws_req_headers(req, &hbuf, MAX_HEADERS);

        Conn* c = w.conn_new(res);
        c.req = req;
        c.hdrs = hbuf[:nh];
        c.path = (String)up[:ul];
        c.query = (String)qp[:ql];

        if (has_body(c.hdrs))
        {
            // The body arrives after this callback returns.
            c.capture(method);
            c.body.init(mem, 1024);
            uws_res_on_aborted(res, &on_aborted, c);
            uws_res_on_data(res, &on_data, c);
            return;
        }

        c.in_request = true;
        w.call_dispatch(c, method, "", false);
        c.in_request = false;

        if (c.res == null)
        {
            // Answered synchronously, the common case.
            w.conn_free(c);
            return;
        }
        c.capture(method);
        // Still pending: uWS requires an abort handler on any response that
        // outlives its request callback.
        uws_res_on_aborted(res, &on_aborted, c);
    };
}

// Entry point for every listener thread, including the main one.
//
// The temp allocator is thread-local and is only created implicitly on the
// main thread, so each worker has to bring up its own around the entire loop:
// @pool() inside the callbacks derives from this.
fn int worker_main(void* arg)
{
    Worker* w = (Worker*)arg;
    int rc;
    @pool_init(mem, WORKER_POOL)
    {
        rc = uws_run_one(g_port, &on_request, (void*)w, w.index, g_threads);
    };
    return rc;
}

// ---- startup ----

fn void? Worker.boot(&self)
{
    // A zeroed List allocates from tmem, which every request resets.
    self.conns.init(mem, 256);
    self.free_slots.init(mem, 256);
    self.spare.init(mem, 256);
    self.rt.open()!;
    self.rt.register_fn("__respond", &host_respond, self, 5)!;
    self.rt.register_fn("__timer_start", &host_timer_start, self, 2)!;
    self.rt.register_fn("__req_url", &host_req_url, self, 1)!;
    self.rt.register_fn("__req_headers", &host_req_headers, self, 1)!;
    self.rt.register_fn("__timer_cancel", &host_timer_cancel, self, 1)!;
    self.rt.exec(PRELUDE, "<prelude>")!;

    JsValue handler = self.rt.eval(g_script, "<handler>")!;
    defer self.rt.release(handler);
    JsValue install = self.rt.eval("__install", "<boot>")!;
    defer self.rt.release(install);
    JsValue[1] args = { handler };
    JsValue r = self.rt.call(install, args[..])!;
    self.rt.release(r);

    self.dispatch = self.rt.eval("__dispatch", "<boot>")!;
    self.timer_fire = self.rt.eval("__timer_fire", "<boot>")!;
    foreach (i, name : METHODS) self.methods[i] = self.rt.string(name)!;
}

fn int main(String[] args)
{
    String usage = "usage: %s [port] [threads] [script.js | nojs]";
    int port = DEFAULT_PORT;
    int threads = 1;
    if (args.len > 1)
    {
        int? parsed = args[1].to_int();
        if (catch parsed) { io::eprintfn(usage, args[0]); return 1; }
        port = parsed;
    }
    if (args.len > 2)
    {
        int? parsed = args[2].to_int();
        if (catch parsed) { io::eprintfn(usage, args[0]); return 1; }
        threads = parsed;
    }
    g_script = DEFAULT_SCRIPT;
    if (args.len > 3)
    {
        if (args[3] == "nojs")
        {
            g_no_js = true;
        }
        else
        {
            char[]? src = file::load(mem, args[3]);
            if (catch err = src)
            {
                io::eprintfn("cannot read %s: %s", args[3], err);
                return 1;
            }
            g_script = (String)src;
        }
    }
    if (threads < 1 || threads > MAX_THREADS)
    {
        io::eprintfn("threads must be 1..%d", MAX_THREADS);
        return 1;
    }

    g_port = port;
    g_threads = threads;

    // Every runtime is opened and bootstrapped here, on the main thread,
    // before any worker thread starts.
    for (int i = 0; i < threads; i++)
    {
        Worker* w = &g_workers[i];
        w.index = i;
        if (catch err = w.boot())
        {
            io::eprintfn("bootstrap failed on runtime %d: %s: %s", i, err, w.rt.last_error());
            return 1;
        }
    }
    defer for (int i = 0; i < threads; i++) g_workers[i].rt.close();

    io::printfn("test-server-uws listening on http://127.0.0.1:%d (%d thread%s)",
                port, threads, threads == 1 ? "" : "s");

    // Workers 1..n-1 get their own thread; worker 0 runs on this one, so a
    // single-threaded run spawns nothing at all.
    Thread[MAX_THREADS] pool;
    for (int i = 1; i < threads; i++)
    {
        if (catch err = pool[i].create(&worker_main, (void*)&g_workers[i]))
        {
            io::eprintfn("failed to start thread %d: %s", i, err);
            return 1;
        }
    }

    // Blocks in the uWS event loop; only returns if the port could not be bound.
    int rc = worker_main((void*)&g_workers[0]);
    if (rc != 0) io::eprintfn("failed to bind port %d", port);
    for (int i = 1; i < threads; i++) pool[i].join()!!;
    return rc == 0 ? 0 : 1;
}
