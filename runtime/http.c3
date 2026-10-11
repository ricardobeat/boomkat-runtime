// serve(): uWebSockets apps on the main loop, dispatching to JS fetch
// handlers. A request is a Conn from arrival until JS finishes the response.
module bkr;

import boomkat;
import std::io;
import std::collections::list;

typedef UwsApp = void;
typedef UwsReq = void;
typedef UwsRes = void;

alias UwsReqCb = fn void(void* user, UwsReq* req, UwsRes* res);
alias UwsDataCb = fn void(void* user, char* chunk, sz len, CInt last);
alias UwsWritableCb = fn CInt(void* user, ulong offset);

struct UwsHeader
{
    char* key;
    sz key_len;
    char* val;
    sz val_len;
}

extern fn UwsApp* uws_app_new(UwsReqCb cb, void* user);
extern fn CInt uws_app_listen(UwsApp* app, ZString host, CInt port);
extern fn void uws_app_stop(UwsApp* app, CInt force);

extern fn sz uws_req_method(UwsReq* req, char** out);
extern fn sz uws_req_url(UwsReq* req, char** out);
extern fn sz uws_req_query(UwsReq* req, char** out);
extern fn CInt uws_req_headers(UwsReq* req, UwsHeader* out, CInt cap);
extern fn sz uws_res_remote(UwsRes* res, char** out);

extern fn void uws_res_on_data(UwsRes* res, UwsDataCb cb, void* user);
extern fn void uws_res_on_aborted(UwsRes* res, Callback cb, void* user);
extern fn void uws_res_on_writable(UwsRes* res, UwsWritableCb cb, void* user);
extern fn void uws_res_write_status(UwsRes* res, char* status, sz len);
extern fn void uws_res_write_header(UwsRes* res, char* key, sz key_len, char* val, sz val_len);
extern fn CInt uws_res_write(UwsRes* res, char* data, sz len);
extern fn void uws_res_end(UwsRes* res, char* body, sz len);
extern fn void uws_res_end_empty(UwsRes* res);
extern fn void uws_res_cork(UwsRes* res, Callback cb, void* user);

const sz MAX_REQUEST_BODY = 16 * 1024 * 1024;
const int MAX_HEADERS = 64;
const uint SLOT_BITS = 20;
const uint SLOT_MASK = (1u << SLOT_BITS) - 1;

struct Server
{
    uint index;
    UwsApp* app;
    JsValue index_value;
    bool stopped;
}

// A request in flight. While the uWS request callback runs, the URL and
// headers are read straight from `req`; a Conn that outlives the callback
// captures them first, since uWS reuses the request buffer.
struct Conn
{
    Server* server;
    uint id;
    UwsRes* res;
    bool aborted;
    bool in_request;
    bool streaming;
    bool head;
    UwsReq* req;
    UwsHeader[] hdrs;
    String path;
    String query;
    String method;
    String url;
    String blob;
    List{char} body;
}

List{Server*} g_servers;
List{Conn*} g_conns;
List{uint} g_free_slots;
List{Conn*} g_spare;
uint g_generation;

const String[] METHODS = { "GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH" };
JsValue[METHODS.len] g_methods;
JsValue g_dispatch;
JsValue g_drain;
JsValue g_aborted;

fn void? init_http()
{
    g_servers.init(mem);
    g_conns.init(mem, 256);
    g_free_slots.init(mem, 256);
    g_spare.init(mem, 256);
    foreach (i, m : METHODS) g_methods[i] = g_rt.string(m)!;
}

// ---- conn table ----

fn Conn* conn_new(Server* s, UwsRes* res)
{
    Conn* c = g_spare.len() ? g_spare.pop()!! : mem::new(Conn);
    c.server = s;
    c.res = res;
    uint slot;
    if (g_free_slots.len())
    {
        slot = g_free_slots.pop()!!;
        g_conns[slot] = c;
    }
    else
    {
        slot = (uint)g_conns.len();
        g_conns.push(c);
    }
    g_generation = (g_generation + 1) & ((1u << (32 - SLOT_BITS)) - 1);
    c.id = (g_generation << SLOT_BITS) | slot;
    return c;
}

fn Conn* conn_find(uint id)
{
    uint slot = id & SLOT_MASK;
    if (slot >= g_conns.len()) return null;
    Conn* c = g_conns[slot];
    return c && c.id == id ? c : null;
}

fn void conn_free(Conn* c)
{
    g_conns[c.id & SLOT_MASK] = null;
    g_free_slots.push(c.id & SLOT_MASK);
    if (c.method.len) free(c.method.ptr);
    if (c.url.len) free(c.url.ptr);
    if (c.blob.len) free(c.blob.ptr);
    if (c.body.is_initialized()) c.body.free();
    *c = {};
    if (g_spare.len() < 1024)
    {
        g_spare.push(c);
    }
    else
    {
        free(c);
    }
}

// ---- reading the request ----

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
    foreach (h : hdrs) if ((String)h.key[:h.key_len] == "host") return (String)h.val[:h.val_len];
    return "localhost";
}

// "name\nvalue\n..." in tmem: HTTP forbids newlines in either.
fn String headers_blob(UwsHeader[] hdrs)
{
    sz n = 0;
    foreach (h : hdrs) n += h.key_len + h.val_len + 2;
    char[] out = mem::temp_array(char, n);
    sz at = 0;
    foreach (h : hdrs)
    {
        out[at:h.key_len] = h.key[:h.key_len];
        at += h.key_len;
        out[at++] = '\n';
        out[at:h.val_len] = h.val[:h.val_len];
        at += h.val_len;
        out[at++] = '\n';
    }
    return (String)out;
}

fn String join_url(String host, String path, String query)
{
    sz n = 7 + host.len + path.len + (query.len ? query.len + 1 : 0);
    char[] out = mem::temp_array(char, n);
    out[:7] = "http://"[..];
    sz at = 7;
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

fn String Conn.url_now(&self)
{
    if (self.url.len || !self.req) return self.url;
    return join_url(host_of(self.hdrs), self.path, self.query);
}

fn String Conn.blob_now(&self) => self.req ? headers_blob(self.hdrs) : self.blob;

fn void Conn.capture(&self, String method)
{
    if (!self.req) return;
    self.method = method.copy(mem);
    self.url = self.url_now().copy(mem);
    self.blob = self.blob_now().copy(mem);
    self.req = null;
    self.hdrs = {};
}

// ---- dispatch ----

fn void dispatch(Conn* c, String method, char[] body, bool has_body)
{
    JsValue m;
    bool cached;
    foreach (i, name : METHODS)
    {
        if (name == method)
        {
            m = g_methods[i];
            cached = true;
            break;
        }
    }
    g_rt.@scope()
    {
        if (!cached) m = g_rt.string(method) ?? {};
        JsValue[4] args = {
            c.server.index_value,
            g_rt.number(c.id) ?? {},
            m,
            has_body ? bytes_value(copy_bytes(body)) ?? {} : (JsValue){},
        };
        JsValue? r = g_rt.call(g_dispatch, args[..]);
        if (catch r) report_uncaught();
    };
}

// ---- writing the response ----

struct Reply
{
    Conn* c;
    int status;
    String status_text;
    String blob;
    char[] body;
    bool end;
}

fn void write_head(UwsRes* res, int status, String status_text, String blob)
{
    if (status != 200)
    {
        String line = string::tformat("%d %s", status, status_text);
        uws_res_write_status(res, line.ptr, line.len);
    }
    String rest = blob;
    while (rest.len)
    {
        sz nl = rest.index_of_char('\n') ?? rest.len;
        String key = rest[:nl];
        rest = nl < rest.len ? rest[nl + 1..] : "";
        sz nl2 = rest.index_of_char('\n') ?? rest.len;
        String val = rest[:nl2];
        rest = nl2 < rest.len ? rest[nl2 + 1..] : "";
        // uWS frames the body itself.
        if (key == "content-length" || key == "transfer-encoding") continue;
        uws_res_write_header(res, key.ptr, key.len, val.ptr, val.len);
    }
}

fn void write_reply(void* user)
{
    Reply* r = user;
    UwsRes* res = r.c.res;
    write_head(res, r.status, r.status_text, r.blob);
    if (!r.end) return;
    if (r.c.head || r.status == 204 || r.status == 304)
    {
        uws_res_end_empty(res);
    }
    else
    {
        uws_res_end(res, r.body.ptr, r.body.len);
    }
}

fn void corked(Conn* c, Callback cb, void* user)
{
    // Inside the request callback uWS has already corked.
    if (c.in_request)
    {
        cb(user);
    }
    else
    {
        uws_res_cork(c.res, cb, user);
    }
}

fn void finish(Conn* c, int status, String text, String blob, char[] body)
{
    if (!c.aborted)
    {
        Reply r = { c, status, text, blob, body, true };
        corked(c, &write_reply, &r);
    }
    done(c);
}

fn void done(Conn* c)
{
    // The request callback frees it on the way out.
    if (c.in_request)
    {
        c.res = null;
    }
    else
    {
        conn_free(c);
    }
}

fn void finish_plain(Conn* c, int status, String body)
{
    String text = status == 413 ? "Payload Too Large" : "Internal Server Error";
    finish(c, status, text, "content-type\ntext/plain;charset=UTF-8\n", body);
}

fn Conn* JsCtx.conn(self)
{
    Conn* c = conn_find(self.arg(0).id());
    return c && c.res ? c : null;
}

// respond(id, status, statusText, headerBlob, body)
fn void js_respond(JsCtx ctx, void* udata)
{
    Conn* c = ctx.conn();
    if (!c) return;
    @pool()
    {
        finish(c, ctx.arg(1).as_int(200), (String)ctx.arg(2).bytes(), (String)ctx.arg(3).bytes(), ctx.arg(4).bytes());
    };
}

// stream_start(id, status, statusText, headerBlob): the head now, the body
// through stream_write and stream_end.
fn void js_stream_start(JsCtx ctx, void* udata)
{
    Conn* c = ctx.conn();
    if (!c || c.aborted) return;
    @pool()
    {
        Reply r = { c, ctx.arg(1).as_int(200), (String)ctx.arg(2).bytes(), (String)ctx.arg(3).bytes(), {}, false };
        corked(c, &write_reply, &r);
    };
    c.streaming = true;
    uws_res_on_writable(c.res, &on_writable, c);
}

struct Chunk
{
    UwsRes* res;
    char[] data;
    bool ok;
}

fn void write_chunk(void* user)
{
    Chunk* k = user;
    k.ok = uws_res_write(k.res, k.data.ptr, k.data.len) != 0;
}

// stream_write(id, bytes) -> false once the client is behind; JS then
// waits for __drain(id).
fn void js_stream_write(JsCtx ctx, void* udata)
{
    Conn* c = ctx.conn();
    if (!c || c.aborted)
    {
        ctx.ret_bool(false);
        return;
    }
    @pool()
    {
        Chunk k = { c.res, ctx.arg(1).bytes(), false };
        corked(c, &write_chunk, &k);
        ctx.ret_bool(k.ok);
    };
}

fn void end_stream(void* user)
{
    Conn* c = user;
    uws_res_end(c.res, null, 0);
}

fn void js_stream_end(JsCtx ctx, void* udata)
{
    Conn* c = ctx.conn();
    if (!c) return;
    if (!c.aborted) corked(c, &end_stream, c);
    done(c);
}

fn CInt on_writable(void* user, ulong offset)
{
    Conn* c = user;
    call_conn(g_drain, c.id);
    return 1;
}

fn void call_conn(JsValue f, uint id)
{
    g_rt.@scope()
    {
        JsValue[1] args = { g_rt.number(id) ?? {} };
        JsValue? r = g_rt.call(f, args[..]);
        if (catch r) report_uncaught();
    };
}

fn void js_req_url(JsCtx ctx, void* udata)
{
    Conn* c = conn_find(ctx.arg(0).id());
    @pool() { ctx.ret_string(c ? c.url_now() : ""); };
}

fn void js_req_headers(JsCtx ctx, void* udata)
{
    Conn* c = conn_find(ctx.arg(0).id());
    @pool() { ctx.ret_string(c ? c.blob_now() : ""); };
}

fn void js_req_remote(JsCtx ctx, void* udata)
{
    Conn* c = ctx.conn();
    if (!c || c.aborted) return;
    char* p;
    sz n = uws_res_remote(c.res, &p);
    ctx.ret_string((String)p[:n]);
}

// ---- uWS callbacks ----

fn void on_aborted(void* user)
{
    Conn* c = user;
    c.aborted = true;
    if (c.streaming) call_conn(g_aborted, c.id);
}

fn void on_data(void* user, char* chunk, sz len, CInt last)
{
    Conn* c = user;
    if (!c.res) return;
    if (c.body.len() + len > MAX_REQUEST_BODY)
    {
        finish_plain(c, 413, "Payload Too Large");
        return;
    }
    c.body.push_all(chunk[:len]);
    if (!last) return;
    @pool() { dispatch(c, c.method, c.body.array_view(), true); };
}

fn void on_request(void* user, UwsReq* req, UwsRes* res)
{
    Server* s = user;
    char* mp;
    sz ml = uws_req_method(req, &mp);
    char* up;
    sz ul = uws_req_url(req, &up);
    char* qp;
    sz ql = uws_req_query(req, &qp);
    @pool()
    {
        String method = (String)mp[:ml];
        UwsHeader[MAX_HEADERS] hbuf;
        CInt nh = uws_req_headers(req, &hbuf, MAX_HEADERS);
        Conn* c = conn_new(s, res);
        c.req = req;
        c.hdrs = hbuf[:nh];
        c.path = (String)up[:ul];
        c.query = (String)qp[:ql];
        c.head = method == "HEAD";
        if (has_body(c.hdrs))
        {
            c.capture(method);
            c.body.init(mem, 1024);
            uws_res_on_aborted(res, &on_aborted, c);
            uws_res_on_data(res, &on_data, c);
            return;
        }
        c.in_request = true;
        dispatch(c, method, {}, false);
        c.in_request = false;
        if (!c.res)
        {
            conn_free(c);
            return;
        }
        c.capture(method);
        uws_res_on_aborted(res, &on_aborted, c);
    };
}

// ---- natives ----

// serve(index, hostname, port) -> bound port
fn void js_serve(JsCtx ctx, void* udata)
{
    @pool()
    {
        uint index = ctx.arg(0).id();
        String host = ctx.arg(1).as_string() ?? "0.0.0.0";
        int port = ctx.arg(2).as_int(8080);
        if (!check_net(host, port))
        {
            ctx.throw_coded("PERMISSION_DENIED", string::tformat("net access to \"%s\" denied; run with --allow-net", describe(host, port)));
            return;
        }
        Server* s = mem::new(Server);
        s.index = index;
        s.index_value = g_rt.number(index)!!;
        s.app = uws_app_new(&on_request, s);
        CInt bound = uws_app_listen(s.app, host.zstr_tcopy(), port);
        if (bound < 0)
        {
            ctx.throw_coded("EADDRINUSE", string::tformat("could not listen on %s", describe(host, port)));
            uws_app_stop(s.app, 1);
            return;
        }
        g_servers.push(s);
        ctx.ret_number(bound);
    };
}

// stop(index, force)
fn void js_stop(JsCtx ctx, void* udata)
{
    uint index = ctx.arg(0).id();
    foreach (s : g_servers)
    {
        if (s.index != index || s.stopped) continue;
        s.stopped = true;
        uws_app_stop(s.app, ctx.arg(1).as_bool() ?? false ? 1 : 0);
    }
}

const Native[] HTTP_NATIVES = {
    { "serve", &js_serve, 3 },
    { "stop", &js_stop, 2 },
    { "respond", &js_respond, 5 },
    { "streamStart", &js_stream_start, 4 },
    { "streamWrite", &js_stream_write, 2 },
    { "streamEnd", &js_stream_end, 1 },
    { "reqUrl", &js_req_url, 1 },
    { "reqHeaders", &js_req_headers, 1 },
    { "reqRemote", &js_req_remote, 1 },
};
