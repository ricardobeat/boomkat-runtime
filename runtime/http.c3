// serve(): uWebSockets apps on the main loop, dispatching to JS fetch
// handlers. A request is a Conn from arrival until JS finishes the response.
module bkr;

import boomkat;
import boomkat::builtins;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import std::io;
import std::collections::list;
import std::collections::map;

typedef UwsApp = void;
typedef UwsReq = void;
typedef UwsRes = void;

alias UwsReqCb = fn void(void* user, UwsReq* req, UwsRes* res);
alias UwsDataCb = fn void(void* user, char* chunk, sz len, CInt last);
alias UwsWritableCb = fn CInt(void* user, ulong offset);

struct UwsHeader {
    char* key;
    sz key_len;
    char* val;
    sz val_len;
}

extern fn UwsApp* uws_app_new(UwsReqCb cb, void* user);
extern fn UwsApp* uws_app_new_tls(UwsReqCb cb, void* user, ZString cert, ZString key);
extern fn void uws_app_route(UwsApp* app, ZString method, ZString path, UwsReqCb cb, void* user);
extern fn sz uws_req_parameter(UwsReq* req, ushort index, char** out);
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
extern fn void uws_res_close(UwsRes* res);
extern fn void uws_res_end_empty(UwsRes* res);
extern fn void uws_res_end_static(UwsRes* res, char* status, sz status_len,
    char* headers, sz headers_len, char* body, sz body_len, bool empty);
extern fn void uws_res_cork(UwsRes* res, Callback cb, void* user);
extern fn void uws_loop_on_pre(Callback cb, void* user);

const sz MAX_REQUEST_BODY = 16 * 1024 * 1024;
const int MAX_HEADERS     = 64;
const uint SLOT_BITS      = 20;
const uint SLOT_MASK      = (1u << SLOT_BITS) - 1;

struct Server {
    uint index;
    UwsApp* app;
    JsValue index_value;
    bool stopped;
    HashMap{String, Static} statics;
    JsValue fetch;
    JsValue server_value;
    List{Route*} routes;
    String hostname;
    int requested_port;
    int port;
    uint pool_live;
    bool pool_started;
}

extern fn void uws_app_pool_init(UwsApp* app);
extern fn CInt uws_app_pool_join(UwsApp* app, UwsApp* parent);
extern fn CInt uws_app_pool_count(UwsApp* app);
extern fn CInt uws_app_pool_idle(UwsApp* app);

// A response fixed at serve() time, answered without entering JS.
struct Static {
    int status;
    String status_text;
    String blob;
    char[] body;
    String status_line;
    String headers;
}

// uWS owns the route tree; its callback selects a rooted handler directly.
struct Route {
    Server* server;
    JsValue handler;
    JsValue[] keys;
    bool fixed;
    Static response;
}

// A request in flight. While the uWS request callback runs, the URL and
// headers are read straight from `req`; a Conn that outlives the callback
// captures them first, since uWS reuses the request buffer.
struct Conn {
    Server* server;
    Route* route;
    JsValue params;
    ulong id;
    UwsRes* res;
    bool aborted;
    bool in_request;
    bool streaming;
    bool head;
    bool discard_body;
    NativeFile* file_body;
    UwsReq* req;
    UwsHeader[] hdrs;
    String path;
    String query;
    String method;
    String url;
    String blob;
    List{char} body;
    // A WebSocket upgrade request: the uWS context and the headers its
    // upgrade answers with.
    void* ws_ctx;
    String ws_key;
    String ws_ext;
}

const ulong HTTP_TURN_NS = 2_000_000;

const String[] METHODS = { "GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH" };

// What the native request path needs to build a Request and read a
// Response without running the prelude's JS.
struct FastTypes {
    HObject* request_proto;
    HObject* response_proto;
    TVal ct_text;
    TVal ct_json;
    HString* k_method;
    HString* k_id;
    HString* k_body;
    HString* k_headers;
    HString* k_used;
    HString* k_status;
    HString* k_ct;
    HString* k_url;
    HString* k_header_blob;
    HObject* file_proto;
    HString* k_file_path;
    HString* k_params;
    HString* k_blob;
    TVal blob_method;
    TVal response_ctor;
    JsValue[14] keep;
}


fn void? init_http() {
    g_runtime.servers.init(mem);
    g_runtime.conns.init(mem, 256);
    g_runtime.free_slots.init(mem, 256);
    g_runtime.spare.init(mem, 256);
    g_runtime.http_queue.init(mem, 256);
    uws_loop_on_pre(&http_turn_reset, &g_runtime.http_queue);
    foreach (i, m : METHODS) g_runtime.methods[i] = g_runtime.rt.string(m)!;
    g_runtime.http_fulfilled = bk_get("httpFulfilled")!;
    g_runtime.http_rejected = bk_get("httpRejected")!;
    g_runtime.http_error = bk_get("error")!;
    g_runtime.http_then = g_runtime.rt.root(g_runtime.rt.rt.heap.promise_proto.get_prop(g_runtime.rt.rt.heap.str(THEN), g_runtime.rt.rt.heap)!)!;
}

// ---- conn table ----

fn Conn* conn_new(Server* s, UwsRes* res) {
    Conn* c = g_runtime.spare.len() ? g_runtime.spare.pop()!! : mem::new(Conn);
    c.server = s;
    c.res = res;
    uint slot;
    if (g_runtime.free_slots.len()) {
        slot = g_runtime.free_slots.pop()!!;
        g_runtime.conns[slot] = c;
    } else {
        slot = (uint)g_runtime.conns.len();
        g_runtime.conns.push(c);
    }
    g_runtime.generation = (g_runtime.generation + 1) & ((1ul << (53 - SLOT_BITS)) - 1);
    c.id = (g_runtime.generation << SLOT_BITS) | slot;
    return c;
}

fn Conn* conn_find(ulong id) {
    uint slot = (uint)(id & SLOT_MASK);
    if (slot >= g_runtime.conns.len()) return null;
    Conn* c = g_runtime.conns[slot];
    return c && c.id == id ? c : null;
}

fn void conn_free(Conn* c) {
    g_runtime.conns[(sz)(c.id & SLOT_MASK)] = null;
    g_runtime.free_slots.push((uint)(c.id & SLOT_MASK));
    if (!c.params.is_empty()) g_runtime.rt.release(c.params);
    if (c.method.len) free(c.method.ptr);
    if (c.url.len) free(c.url.ptr);
    if (c.blob.len) free(c.blob.ptr);
    if (c.body.is_initialized()) c.body.free();
    c.free_upgrade();
    *c = { };
    if (g_runtime.spare.len() < 1024) {
        g_runtime.spare.push(c);
    } else {
        free(c);
    }
}

// ---- reading the request ----

fn bool has_body(UwsHeader[] hdrs) {
    foreach (h : hdrs) {
        String key = (String)h.key[:h.key_len];
        if (key == "content-length") return (String)h.val[:h.val_len] != "0";
        if (key == "transfer-encoding") return true;
    }
    return false;
}

fn String host_of(UwsHeader[] hdrs) {
    foreach (h : hdrs) if ((String)h.key[:h.key_len] == "host") return (String)h.val[:h.val_len];
    return "localhost";
}

// "name\nvalue\n..." in tmem: HTTP forbids newlines in either.
fn String headers_blob(UwsHeader[] hdrs) {
    sz n = 0;
    foreach (h : hdrs) n += h.key_len + h.val_len + 2;
    char[] out = mem::temp_array(char, n);
    sz at      = 0;
    foreach (h : hdrs) {
        out[at:h.key_len] = h.key[:h.key_len];
        at += h.key_len;
        out[at++] = '\n';
        out[at:h.val_len] = h.val[:h.val_len];
        at += h.val_len;
        out[at++] = '\n';
    }
    return (String)out;
}

fn String join_url(String host, String path, String query) {
    sz n       = 7 + host.len + path.len + (query.len ? query.len + 1 : 0);
    char[] out = mem::temp_array(char, n);
    out[:7] = "http://"[..];
    sz at = 7;
    out[at:host.len] = host[..];
    at += host.len;
    out[at:path.len] = path[..];
    at += path.len;
    if (query.len) {
        out[at] = '?';
        out[at + 1:query.len] = query[..];
    }
    return (String)out;
}

fn String Conn.url_now(&self) {
    if (self.url.len || !self.req) return self.url;
    return join_url(host_of(self.hdrs), self.path, self.query);
}

fn String Conn.blob_now(&self) => self.req ? headers_blob(self.hdrs) : self.blob;

fn void Conn.capture(&self, String method) {
    if (!self.req) return;
    self.method = method.copy(mem);
    self.url = self.url_now().copy(mem);
    self.blob = self.blob_now().copy(mem);
    self.req = null;
    self.hdrs = { };
}

// ---- dispatch ----

fn HString* fast_key(usz i, String name) {
    JsValue v = g_runtime.rt.string(name)!!;
    g_runtime.fast.keep[i] = v;
    TVal tv;
    g_runtime.rt.load(v, &tv);
    return (HString*)tv.get_heapptr();
}

// fastTypes(Request.prototype, Response.prototype, ctText, ctJson)
fn void js_fast_types(JsCtx ctx, void* udata) {
    if (!ctx.arg(0).tv.is_object() || !ctx.arg(1).tv.is_object()) return;
    g_runtime.fast.request_proto = (HObject*)ctx.arg(0).tv.get_heapptr();
    g_runtime.fast.response_proto = (HObject*)ctx.arg(1).tv.get_heapptr();
    g_runtime.fast.ct_text = ctx.arg(2).tv;
    g_runtime.fast.ct_json = ctx.arg(3).tv;
    g_runtime.fast.file_proto = ctx.arg(4).tv.get_heapptr();
    for (uint i = 0; i < 5; i++) (void)ctx.persist(ctx.arg(i));
    g_runtime.fast.k_method = fast_key(0, "method");
    g_runtime.fast.k_id = fast_key(1, "_id");
    g_runtime.fast.k_body = fast_key(2, "_body");
    g_runtime.fast.k_headers = fast_key(3, "_headers");
    g_runtime.fast.k_used = fast_key(4, "_used");
    g_runtime.fast.k_status = fast_key(5, "status");
    g_runtime.fast.k_ct = fast_key(6, "_ct");
    g_runtime.fast.k_url = fast_key(7, "_url");
    g_runtime.fast.k_header_blob = fast_key(8, "_headerBlob");
    g_runtime.fast.k_file_path = fast_key(9, "_path");
    g_runtime.fast.k_params = fast_key(10, "params");
    g_runtime.fast.k_blob = fast_key(11, "_blob");
    g_runtime.fast.blob_method = g_runtime.fast.response_proto.get_prop_proto(g_runtime.fast.k_blob, ctx.ctx.heap) ?? (TVal) { };
    g_runtime.fast.keep[12] = ctx.persist((JsArg) { .tv = g_runtime.fast.blob_method })!!;
    g_runtime.fast.response_ctor = ctx.get_prop(ctx.arg(1), "constructor")!!.tv;
    g_runtime.fast.keep[13] = ctx.persist((JsArg) { .tv = g_runtime.fast.response_ctor })!!;
}

// fetchFor(index, fetch, server): call this server's handler straight from C3.
fn void js_fetch_for(JsCtx ctx, void* udata) {
    uint index = ctx.arg(0).id();
    foreach (s : g_runtime.servers) {
        if (s.index != index) continue;
        s.fetch = ctx.persist(ctx.arg(1)) ?? { };
        s.server_value = ctx.persist(ctx.arg(2)) ?? { };
    }
}

fn JsValue? new_request(Conn* c, JsValue method, char[] body, bool has_body) {
    Heap* h      = g_runtime.rt.rt.heap;
    HObject* req = h.alloc_object(OBJECT)!;
    h.set_prototype(req, g_runtime.fast.request_proto);
    TVal m;
    g_runtime.rt.load(method, &m);
    TVal id;
    id.set_number((double)c.id);
    req.put_prop(g_runtime.fast.k_method, m, hobject::PROP_FLAGS_WEC, h);
    req.put_prop(g_runtime.fast.k_id, id, hobject::PROP_FLAGS_WEC, h);
    // Metadata belongs to the Request even when the response has ended.
    JsValue url  = g_runtime.rt.string(c.url_now())!;
    JsValue blob = g_runtime.rt.string(c.blob_now())!;
    TVal metadata;
    g_runtime.rt.load(url, &metadata);
    req.put_prop(g_runtime.fast.k_url, metadata, hobject::PROP_FLAGS_WEC, h);
    g_runtime.rt.load(blob, &metadata);
    req.put_prop(g_runtime.fast.k_header_blob, metadata, hobject::PROP_FLAGS_WEC, h);
    if (!c.params.is_empty()) {
        g_runtime.rt.load(c.params, &metadata);
        req.put_prop(g_runtime.fast.k_params, metadata, hobject::PROP_FLAGS_WEC, h);
    }
    if (has_body) {
        TVal b;
        b.set_object(new_u8(copy_bytes(body))!);
        req.put_prop(g_runtime.fast.k_body, b, hobject::PROP_FLAGS_WEC, h);
    }
    TVal rv;
    rv.set_object(req);
    return g_runtime.rt.root(rv);
}

fn TVal fast_get(HObject* o, HString* key) {
    TVal v = o.get_prop_proto(key, g_runtime.rt.rt.heap) ?? (TVal) { };
    return v;
}

// Ordinary 200 responses are written from C3 when their body and header
// serialization need no guest callbacks; other responses use the prelude.
fn bool respond_fast(Conn* c, JsValue result) {
    TVal rv;
    if (!g_runtime.rt.load(result, &rv) || !rv.is_object()) return false;
    HObject* o = (HObject*)rv.get_heapptr();
    if (o.prototype != g_runtime.fast.response_proto) return false;
    if (!web_method_is(o, g_runtime.fast.k_blob, g_runtime.fast.blob_method, g_runtime.rt.rt.heap)) return false;
    TVal headers = fast_get(o, g_runtime.fast.k_headers);
    builtins::StrBuf header_blob;
    header_blob.init(g_runtime.rt.rt.heap);
    defer header_blob.free();
    TVal used = fast_get(o, g_runtime.fast.k_used);
    if (!used.is_boolean() || used.get_boolean()) return false;
    TVal status = fast_get(o, g_runtime.fast.k_status);
    if (!status.is_fastint() || status.get_fastint() != 200) return false;
    TVal ct = fast_get(o, g_runtime.fast.k_ct);
    String blob;
    if (!headers.is_null()) {
        bool match;
        if (!web_instanceof(g_runtime.rt.rt.heap, rv, g_runtime.fast.response_ctor, &match) || !match) return false;
        if (!headers.is_object() || !web_headers_blob(
            g_runtime.rt.rt.heap,
            headers.get_heapptr(),
            &header_blob,
            true
        )) return false;
        blob = (String)header_blob.bytes();
    } else if (ct.is_null()) {
        blob = "";
    } else if (ct.is_string() && ct.get_heapptr() == g_runtime.fast.ct_text.get_heapptr()) {
        blob = BLOB_TEXT;
    } else if (ct.is_string() && ct.get_heapptr() == g_runtime.fast.ct_json.get_heapptr()) {
        blob = BLOB_JSON;
    } else {
        return false;
    }
    TVal b     = fast_get(o, g_runtime.fast.k_body);
    JsArg body = { .tv = b };
    bool file  = b.is_object() && ((HObject*)b.get_heapptr()).prototype == g_runtime.fast.file_proto;
    bool stream;
    if (b.is_object() && !body.is_bytes() && !file) {
        if (!web_instanceof(g_runtime.rt.rt.heap, b, g_runtime.native_response.stream_ctor, &stream)) return false;
    }
    if (!b.is_null() && !b.is_string() && !body.is_bytes() && !file && !stream) return false;
    TVal t;
    t.set_boolean(true);
    o.put_prop(g_runtime.fast.k_used, t, hobject::PROP_FLAGS_WEC, g_runtime.rt.rt.heap);
    if (stream) {
        JsValue[2] args = { g_runtime.rt.number((double)c.id) ?? { }, result };
        (void)call_js(g_runtime.pump, args[..]);
        return true;
    }
    @pool() {
        if (file) {
            JsArg path = { .tv = fast_get((HObject*)b.get_heapptr(), g_runtime.fast.k_file_path) };
            native_file_start(c, (String)path.bytes(), 200, "", blob);
        } else {
            finish(c, 200, "", blob, b.is_null() ? (char[]) { } : body.bytes());
        }
    };
    return true;
}

const String BLOB_TEXT = "content-type\ntext/plain;charset=UTF-8\n";
const String BLOB_JSON = "content-type\napplication/json\n";

fn void dispatch(Conn* c, String method, char[] body, bool has_body) {
    if (!c.server.fetch.is_empty() && g_runtime.fast.request_proto) {
        dispatch_fast(c, method, body, has_body);
        return;
    }
    JsValue m;
    bool cached;
    foreach (i, name : METHODS) {
        if (name == method) {
            m = g_runtime.methods[i];
            cached = true;
            break;
        }
    }
    g_runtime.rt.@scope() {
        if (!cached) m = g_runtime.rt.string(method) ?? { };
        JsValue[4] args = {
            c.server.index_value,
            g_runtime.rt.number((double)c.id) ?? { },
            m,
            has_body ? bytes_value(copy_bytes(body)) ?? { } : (JsValue) { },
        };
        if (catch call_js(g_runtime.dispatch, args[..])) {
            if (conn_find(c.id) == c && c.res && !c.streaming) finish_plain(c, 500, "Internal Server Error");
        }
    };
}

fn JsValue method_value(String method) {
    foreach (i, name : METHODS) if (name == method) return g_runtime.methods[i];
    return g_runtime.rt.string(method) ?? { };
}

fn void dispatch_fast(Conn* c, String method, char[] body, bool has_body) {
    bool started = begin_dispatch();
    defer end_dispatch(started);
    Server* s = c.server;
    ulong id  = c.id;
    g_runtime.rt.@scope() {
        JsValue? req = new_request(c, method_value(method), body, has_body);
        if (catch req) return;
        JsValue thrown;
        JsValue[2] args = { req, s.server_value };
        JsValue? r      = call_catch(c.route ? c.route.handler : s.fetch, args[..], &thrown);
        if (catch err = r) {
            if (thrown.is_empty()) {
                if (conn_find(id) == c && c.res && !c.streaming) finish_plain(c, 500, "Internal Server Error");
                return;
            }
            JsValue[3] fa = { s.index_value, g_runtime.rt.number((double)id) ?? { }, thrown };
            if (catch call_js(g_runtime.failed, fa[..])) {
                if (conn_find(id) == c && c.res && !c.streaming) finish_plain(c, 500, "Internal Server Error");
            }
            return;
        }
        defer if (g_runtime.depth == 0 && g_runtime.rejections.len()) flush_rejections();
        // Stream initialization jobs must finish before the native response path takes its source.
        if (catch checkpoint()) { report_uncaught(); return; }
        if (conn_find(id) != c || !c.res) return;
        if (respond_fast(c, r)) return;
        if (subscribe_response(r, id)) {
            if (catch checkpoint()) report_uncaught();
            return;
        }
        JsValue[3] ha = { s.index_value, g_runtime.rt.number((double)id) ?? { }, r };
        if (catch call_js(g_runtime.handled, ha[..])) {
            if (conn_find(id) == c && c.res && !c.streaming) finish_plain(c, 500, "Internal Server Error");
        }
    };
}

// Terminal reactions hold an id, never a borrowed Conn pointer. They are
// ordinary GC-managed host functions and allocate no downstream promise.
fn JsValue? response_callback(JsValue template_fn, ulong id) {
    Heap* h = g_runtime.rt.rt.heap;
    TVal template_value;
    g_runtime.rt.load(template_fn, &template_value);
    HObject* template_obj = template_value.get_heapptr();
    HObject* fn_obj       = h.alloc_object(FUNCTION)!;
    h.set_prototype(fn_obj, h.function_proto);
    fn_obj.flags.callable = true;
    fn_obj.extra_ptr().func.builtin_fn_index = template_obj.extra_ptr().func.builtin_fn_index;
    fn_obj.extra_ptr().func.comp_func = null;
    TVal value;
    value.set_number((double)id);
    fn_obj.put_prop(g_runtime.fast.k_id, value, hobject::PROP_FLAGS_WEC, h);
    value.set_object(fn_obj);
    return g_runtime.rt.root(value);
}

fn bool subscribe_response(JsValue result, ulong id) {
    Heap* h = g_runtime.rt.rt.heap;
    TVal value;
    if (!g_runtime.rt.load(result, &value) || !value.is_object()) return false;
    HObject* promise = value.get_heapptr();
    if (promise.get_class() != PROMISE || promise.prototype != h.promise_proto) return false;
    TVal expected;
    g_runtime.rt.load(g_runtime.http_then, &expected);
    TVal actual = promise.get_prop_proto(h.str(THEN), h) ?? (TVal) { };
    if (!builtins::same_value(actual, expected) || !builtins::promise_default_species(h, promise)) return false;
    JsValue? fulfilled = response_callback(g_runtime.http_fulfilled, id);
    if (catch fulfilled) return false;
    JsValue? rejected = response_callback(g_runtime.http_rejected, id);
    if (catch rejected) return false;
    if (catch g_runtime.rt.observe_promise(result, fulfilled, rejected)) return false;
    return true;
}

fn Conn* response_callback_conn(JsCtx ctx) {
    BuiltinContext* native = ctx.ctx;
    if (!native.callee_obj) return null;
    TVal id   = native.callee_obj.get_prop(g_runtime.fast.k_id, g_runtime.rt.rt.heap) ?? (TVal) { };
    JsArg arg = { .tv = id };
    return conn_find(arg.conn_id());
}

fn void js_http_fulfilled(JsCtx ctx, void* user) {
    Conn* c = response_callback_conn(ctx);
    if (!c || !c.res || c.aborted) return;
    g_runtime.rt.@scope() {
        JsValue value = g_runtime.rt.root(ctx.arg(0).tv) ?? { };
        if (respond_fast(c, value)) return;
        JsValue[3] args = { c.server.index_value, g_runtime.rt.number((double)c.id) ?? { }, value };
        (void)call_js(g_runtime.handled, args[..]);
    };
}

fn void js_http_rejected(JsCtx ctx, void* user) {
    Conn* c = response_callback_conn(ctx);
    if (!c || !c.res || c.aborted) return;
    g_runtime.rt.@scope() {
        JsValue[3] args = { c.server.index_value, g_runtime.rt.number((double)c.id) ?? { }, g_runtime.rt.root(ctx.arg(0).tv) ?? { } };
        (void)call_js(g_runtime.failed, args[..]);
    };
}

fn void response_error(Conn* c, String code, String message) {
    if (c.aborted || !c.res) return;
    g_runtime.rt.@scope() {
        JsValue[2] parts = { g_runtime.rt.string(code) ?? { }, g_runtime.rt.string(message) ?? { } };
        JsValue error    = g_runtime.rt.call(g_runtime.http_error, parts[..]) ?? { };
        JsValue[3] args  = { c.server.index_value, g_runtime.rt.number((double)c.id) ?? { }, error };
        (void)call_js(g_runtime.failed, args[..]);
    };
}

fn void js_native_response(JsCtx ctx, void* user) {
    Conn* c = ctx.conn();
    if (!c) {
        ctx.ret_bool(true);
        return;
    }
    g_runtime.rt.@scope() {
        ctx.ret_bool(respond_fast(c, g_runtime.rt.root(ctx.arg(1).tv) ?? { }));
    };
}

// ---- writing the response ----

struct Reply {
    Conn* c;
    int status;
    String status_text;
    String blob;
    char[] body;
    bool end;
}

fn void write_head(UwsRes* res, int status, String status_text, String blob) {
    if (status != 200) {
        String line = string::tformat("%d %s", status, status_text);
        uws_res_write_status(res, line.ptr, line.len);
    }
    String rest = blob;
    while (rest.len) {
        sz nl      = rest.index_of_char('\n') ?? rest.len;
        String key = rest[:nl];
        rest = nl < rest.len ? rest[nl + 1..] : "";
        sz nl2     = rest.index_of_char('\n') ?? rest.len;
        String val = rest[:nl2];
        rest = nl2 < rest.len ? rest[nl2 + 1..] : "";
        // uWS frames the body itself.
        if (key == "content-length" || key == "transfer-encoding") continue;
        uws_res_write_header(res, key.ptr, key.len, val.ptr, val.len);
    }
}

// Serialize only immutable application headers; uWS owns Date and body framing.
fn void prepare_static(Static* response) {
    @pool() {
        if (response.status != 200) {
            response.status_line = string::tformat("%d %s", response.status, response.status_text).copy(mem);
        }
        DString headers = dstring::temp();
        String rest = response.blob;
        while (rest.len) {
            sz nl = rest.index_of_char('\n') ?? rest.len;
            String key = rest[:nl];
            rest = nl < rest.len ? rest[nl + 1..] : "";
            sz nl2 = rest.index_of_char('\n') ?? rest.len;
            String val = rest[:nl2];
            rest = nl2 < rest.len ? rest[nl2 + 1..] : "";
            if (key == "content-length" || key == "transfer-encoding") continue;
            headers.append(key);
            headers.append(": ");
            headers.append(val);
            headers.append("\r\n");
        }
        response.headers = headers.str_view().copy(mem);
    };
}

fn void end_static(UwsRes* res, Static* response, bool head) {
    uws_res_end_static(res, response.status_line.ptr, response.status_line.len,
        response.headers.ptr, response.headers.len, response.body.ptr, response.body.len,
        head || response.status == 204 || response.status == 304);
}

fn void write_reply(void* user) {
    Reply* r    = user;
    UwsRes* res = r.c.res;
    write_head(res, r.status, r.status_text, r.blob);
    if (!r.end) return;
    if (r.c.head || r.status == 204 || r.status == 304) {
        uws_res_end_empty(res);
    } else {
        uws_res_end(res, r.body.ptr, r.body.len);
    }
}

fn void corked(Conn* c, Callback cb, void* user) {
    // Inside the request callback uWS has already corked.
    if (c.in_request) {
        cb(user);
    } else {
        uws_res_cork(c.res, cb, user);
    }
}

fn void finish(Conn* c, int status, String text, String blob, char[] body) {
    if (!c.aborted) {
        Reply r = { c, status, text, blob, body, true };
        corked(c, &write_reply, &r);
    }
    done(c);
}

fn void done(Conn* c) {
    // The request callback frees it on the way out.
    if (c.in_request) {
        c.res = null;
    } else {
        conn_free(c);
    }
}

fn void finish_plain(Conn* c, int status, String body) {
    String text = status == 413 ? "Payload Too Large" : "Internal Server Error";
    finish(c, status, text, "content-type\ntext/plain;charset=UTF-8\n", body);
}

fn ulong JsArg.conn_id(self) => (ulong)(self.as_number() ?? 0);

fn Conn* JsCtx.conn(self) {
    Conn* c = conn_find(self.arg(0).conn_id());
    return c && c.res ? c : null;
}

// respond(id, status, statusText, headerBlob, body)
fn void js_respond(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c) return;
    @pool() {
        JsArg body = ctx.arg(4);
        if (body.tv.is_object() && ((HObject*)body.tv.get_heapptr()).prototype == g_runtime.fast.file_proto) {
            JsArg path = { .tv = fast_get(body.tv.get_heapptr(), g_runtime.fast.k_file_path) };
            native_file_start(c, (String)path.bytes(), ctx.arg(1)
                .as_int(200), (String)ctx.arg(2).bytes(), (String)ctx.arg(3).bytes());
        } else {
            finish(c, ctx.arg(1).as_int(200), (String)ctx.arg(2).bytes(), (String)ctx.arg(3).bytes(), body.bytes());
        }
    };
}

// stream_start(id, status, statusText, headerBlob): the head now, the body
// through stream_write and stream_end.
fn void js_stream_start(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c || c.aborted) {
        ctx.ret_bool(false);
        return;
    }
    @pool() {
        Reply r = { c, ctx.arg(1).as_int(200), (String)ctx.arg(2).bytes(), (String)ctx.arg(3).bytes(), { }, false };
        corked(c, &write_reply, &r);
    };
    c.discard_body = c.head || ctx.arg(1).as_int(200) == 204 || ctx.arg(1).as_int(200) == 304;
    c.streaming = true;
    uws_res_on_writable(c.res, &on_writable, c);
    ctx.ret_bool(!c.discard_body);
}

struct Chunk {
    UwsRes* res;
    char[] data;
    bool ok;
}

fn void write_chunk(void* user) {
    Chunk* k = user;
    k.ok = uws_res_write(k.res, k.data.ptr, k.data.len) != 0;
}

struct ChunkBatch {
    UwsRes* res;
    char[][] chunks;
    bool ok;
}

fn void write_batch(void* user) {
    ChunkBatch* batch = user;
    batch.ok = true;
    foreach (bytes : batch.chunks) {
        if (bytes.len && !uws_res_write(batch.res, bytes.ptr, bytes.len)) batch.ok = false;
    }
}

struct StreamFinish {
    UwsRes* res;
    char[] bytes;
}

fn void write_stream_finish(void* user) {
    StreamFinish* f = user;
    uws_res_end(f.res, f.bytes.ptr, f.bytes.len);
}

// A source that closed within one bounded batch can end with a known length
// instead of framing every part as a chunk and making another call to end.
fn void js_stream_finish(JsCtx ctx, void* user) {
    Conn* c = ctx.conn();
    if (!c) {
        ctx.ret_bool(true);
        return;
    }
    JsArg arg = ctx.arg(1);
    if (!arg.tv.is_object() || ((HObject*)arg.tv.get_heapptr()).get_class() != ARRAY) {
        ctx.throw_error(TYPE, "stream batch must be an array");
        return;
    }
    @pool() {
        HObject* parts  = arg.tv.get_heapptr();
        char[][] chunks = mem::temp_array(char[], *parts.array_len_ptr());
        usz length      = 0;
        foreach (i, &bytes : chunks) {
            JsArg part = { .tv = parts.get_array_idx((uint)i) ?? (TVal) { } };
            if (!part.is_bytes()) {
                ctx.throw_error(TYPE, "stream chunk must be bytes");
                return;
            }
            *bytes = part.bytes();
            if (bytes.len > 65536 - length) {
                ctx.ret_bool(false);
                return;
            }
            length += bytes.len;
        }
        char[] body = chunks.len == 1 ? chunks[0] : mem::temp_array(char, (sz)length);
        if (chunks.len > 1) {
            usz at = 0;
            foreach (bytes : chunks) {
                if (bytes.len) body[at:bytes.len] = bytes[..];
                at += bytes.len;
            }
        }
        StreamFinish f = { c.res, body };
        corked(c, &write_stream_finish, &f);
        done(c);
        ctx.ret_bool(true);
    };
}

// stream_write(id, bytes) -> false once the client is behind; JS then
// waits for __drain(id).
fn void js_stream_write(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c || c.aborted) {
        ctx.ret_bool(false);
        return;
    }
    if (c.discard_body) {
        ctx.ret_bool(true);
        return;
    }
    @pool() {
        JsArg value = ctx.arg(1);
        if (value.tv.is_object() && ((HObject*)value.tv.get_heapptr()).get_class() == ARRAY) {
            HObject* parts  = value.tv.get_heapptr();
            char[][] chunks = mem::temp_array(char[], *parts.array_len_ptr());
            foreach (i, &bytes : chunks) {
                JsArg part = { .tv = parts.get_array_idx((uint)i) ?? (TVal) { } };
                if (!part.is_bytes()) {
                    ctx.throw_error(TYPE, "stream chunk must be bytes");
                    return;
                }
                *bytes = part.bytes();
            }
            ChunkBatch batch = { c.res, chunks, false };
            corked(c, &write_batch, &batch);
            ctx.ret_bool(batch.ok);
        } else {
            Chunk k = { c.res, value.bytes(), false };
            corked(c, &write_chunk, &k);
            ctx.ret_bool(k.ok);
        }
    };
}

fn void end_stream(void* user) {
    Conn* c = user;
    if (c.discard_body) {
        uws_res_end_empty(c.res);
    } else {
        uws_res_end(c.res, null, 0);
    }
}

fn void js_stream_end(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c) return;
    if (!c.aborted) corked(c, &end_stream, c);
    done(c);
}

fn CInt on_writable(void* user, ulong offset) {
    Conn* c = user;
    call_conn(g_runtime.drain, c.id);
    return 1;
}

fn void call_conn(JsValue f, ulong id) {
    g_runtime.rt.@scope() {
        JsValue[1] args = { g_runtime.rt.number((double)id) ?? { } };
        (void)call_js(f, args[..]);
    };
}

fn void js_req_url(JsCtx ctx, void* udata) {
    Conn* c = conn_find(ctx.arg(0).conn_id());
    @pool() {
        ctx.ret_string(c ? c.url_now() : "");
    };
}

fn void js_req_headers(JsCtx ctx, void* udata) {
    Conn* c = conn_find(ctx.arg(0).conn_id());
    @pool() {
        ctx.ret_string(c ? c.blob_now() : "");
    };
}

fn void js_req_remote(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c || c.aborted) return;
    char* p;
    sz n = uws_res_remote(c.res, &p);
    ctx.ret_string((String)p[:n]);
}

// ---- uWS callbacks ----

fn void http_turn_reset(void* user) => g_runtime.http_turn_ns = 0;

fn void http_queue_arm() {
    if (g_runtime.http_queue_armed) return;
    g_runtime.http_queue_armed = true;
    uws_loop_defer(g_runtime.loop, &http_queue_drain, null);
}

fn void http_queue_drain(void* user) {
    g_runtime.http_queue_armed = false;
    g_runtime.http_turn_ns = now_ns();
    while (g_runtime.http_queue_at < g_runtime.http_queue.len()) {
        ulong id = g_runtime.http_queue[g_runtime.http_queue_at++];
        Conn* c  = conn_find(id);
        if (c && c.res && !c.aborted) {
            @pool() {
                bool body = c.body.is_initialized();
                dispatch(c, c.method, body ? c.body.array_view() : (char[]) { }, body);
            };
        }
        if (now_ns() - g_runtime.http_turn_ns >= HTTP_TURN_NS) break;
    }
    if (g_runtime.http_queue_at == g_runtime.http_queue.len()) {
        g_runtime.http_queue.clear();
        g_runtime.http_queue_at = 0;
    } else {
        // A saturated server may never empty the queue. Reclaim the consumed
        // prefix so storage remains bounded by requests still waiting.
        if (g_runtime.http_queue_at >= 256) {
            sz left = g_runtime.http_queue.len() - g_runtime.http_queue_at;
            mem::move(g_runtime.http_queue.entries, &g_runtime.http_queue[g_runtime.http_queue_at], left * ulong::size);
            g_runtime.http_queue.size = left;
            g_runtime.http_queue_at = 0;
        }
        http_queue_arm();
    }
}

// Bound work between socket polls, including requests left behind by a
// disconnected client. IDs let aborted queued requests be discarded safely.
fn void http_dispatch_ready(Conn* c, String method, char[] body, bool has_body) {
    ulong now = now_ns();
    if (!g_runtime.http_turn_ns) g_runtime.http_turn_ns = now;
    if (g_runtime.http_queue.len() || now - g_runtime.http_turn_ns >= HTTP_TURN_NS) {
        c.capture(method);
        g_runtime.http_queue.push(c.id);
        http_queue_arm();
        return;
    }
    dispatch(c, method, body, has_body);
}

fn void on_aborted(void* user) {
    Conn* c = user;
    c.aborted = true;
    ulong id = c.id;
    if (c.file_body) native_file_abort(c.file_body);
    if (c.streaming) call_conn(g_runtime.aborted, id);
    // JS cancellation can finish the connection reentrantly.
    if (conn_find(id) == c) done(c);
}

fn void on_data(void* user, char* chunk, sz len, CInt last) {
    Conn* c = conn_find((ulong)(usz)user);
    if (!c || !c.res) return;
    if (c.body.len() + len > MAX_REQUEST_BODY) {
        finish_plain(c, 413, "Payload Too Large");
        return;
    }
    c.body.push_all(chunk[:len]);
    if (!last) return;
    @pool() {
        http_dispatch_ready(c, c.method, c.body.array_view(), true);
    };
}

fn int route_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

fn String route_decode(String raw) {
    if (!raw.contains("%")) return utf8_clean((char[])raw, false) ?? "";
    char[] decoded = mem::temp_array(char, raw.len);
    usz written;
    for (usz i = 0; i < raw.len; i++) {
        if (raw[i] == '%' && i + 2 < raw.len) {
            int hi = route_hex(raw[i + 1]);
            int lo = route_hex(raw[i + 2]);
            if (hi >= 0 && lo >= 0) {
                decoded[written++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        decoded[written++] = raw[i];
    }
    return utf8_clean(decoded[:written], false) ?? "";
}

fn JsValue? route_params(Route* route, UwsReq* req) {
    Heap* heap      = g_runtime.rt.rt.heap;
    HObject* params = heap.alloc_object(OBJECT)!;
    heap.set_prototype(params, null);
    TVal value;
    value.set_object(params);
    JsValue result = g_runtime.rt.root(value)!;
    foreach (i, key : route.keys) {
        char* data;
        sz length    = uws_req_parameter(req, (ushort)i, &data);
        JsValue text = g_runtime.rt.string(route_decode((String)data[:length]))!;
        TVal k;
        g_runtime.rt.load(key, &k);
        g_runtime.rt.load(text, &value);
        if (!params.put_prop(k.get_heapptr(), value, hobject::PROP_FLAGS_WEC, heap)) return boomkat::OUT_OF_MEMORY~;
    }
    return result;
}

fn void on_request(void* user, UwsReq* req, UwsRes* res) {
    request_arrive((Server*)user, null, req, res);
}

fn void on_route(void* user, UwsReq* req, UwsRes* res) {
    Route* route = user;
    if (route.fixed) {
        Static* response = &route.response;
        char* method;
        sz length        = uws_req_method(req, &method);
        end_static(res, response, (String)method[:length] == "HEAD");
        return;
    }
    request_arrive(route.server, route, req, res);
}

fn void request_arrive(Server* s, Route* route, UwsReq* req, UwsRes* res) {
    char* mp;
    sz ml = uws_req_method(req, &mp);
    char* up;
    sz ul = uws_req_url(req, &up);
    char* qp;
    sz ql = uws_req_query(req, &qp);
    if (!route && s.statics.len() && serve_static(s, (String)mp[:ml], (String)up[:ul], res)) return;
    @pool() {
        String method = (String)mp[:ml];
        UwsHeader[MAX_HEADERS] hbuf;
        CInt nh       = uws_req_headers(req, &hbuf, MAX_HEADERS);
        Conn* c       = conn_new(s, res);
        c.route = route;
        c.in_request = true;
        if (route) {
            bool ready;
            g_runtime.rt.@scope() {
                if (try params = route_params(route, req)) {
                    if (try owned = g_runtime.rt.persist(params)) {
                        c.params = owned;
                        ready = true;
                    }
                }
            };
            if (!ready) {
                finish_plain(c, 500, "Internal Server Error");
                conn_free(c);
                return;
            }
        }
        c.req = req;
        c.hdrs = hbuf[:nh];
        void* upgrade = uws_req_upgrade_context();
        if (upgrade) c.capture_upgrade(c.hdrs, upgrade);
        c.path = (String)up[:ul];
        c.query = (String)qp[:ql];
        c.head = method == "HEAD";
        if (has_body(c.hdrs)) {
            c.capture(method);
            c.body.init(mem, 1024);
            uws_res_on_aborted(res, &on_aborted, c);
            uws_res_on_data(res, &on_data, (void*)(usz)c.id);
            c.in_request = false;
            return;
        }
        c.in_request = true;
        http_dispatch_ready(c, method, { }, false);
        c.in_request = false;
        if (!c.res) {
            conn_free(c);
            return;
        }
        c.req = null;
        c.hdrs = { };
        c.path = "";
        c.query = "";
        uws_res_on_aborted(res, &on_aborted, c);
    };
}

fn bool serve_static(Server* s, String method, String path, UwsRes* res) {
    bool head = method == "HEAD";
    if (!head && method != "GET") return false;
    Static? st = s.statics.get(path);
    if (catch st) return false;
    end_static(res, &st, head);
    return true;
}

// ---- natives ----

// staticRoute(index, path, status, statusText, headerBlob, body)
fn void js_static_route(JsCtx ctx, void* udata) {
    uint index = ctx.arg(0).id();
    foreach (s : g_runtime.servers) {
        if (s.index != index) continue;
        String path = ((String)ctx.arg(1).bytes()).copy(mem);
        Static response = {ctx.arg(2).as_int(200), ((String)ctx.arg(3).bytes()).copy(mem),
            ((String)ctx.arg(4).bytes()).copy(mem), copy_bytes(ctx.arg(5).bytes()), {}, {}};
        prepare_static(&response);
        s.statics.set(path, response);
    }
}

// httpRoute(index, method, pattern, handler, parameterNames)
fn void js_http_route(JsCtx ctx, void* udata) {
    @pool() {
        uint index  = ctx.arg(0).id();
        JsArg names = ctx.arg(4);
        if (!names.tv.is_object() || ((HObject*)names.tv.get_heapptr()).get_class() != ARRAY) return ctx.throw_error(
            TYPE,
            "route parameters must be an array"
        );
        HObject* keys = names.tv.get_heapptr();
        uint count    = *keys.array_len_ptr();
        if (count > 100) return ctx.throw_error(RANGE, "too many route parameters");
        for (uint i = 0; i < count; i++) {
            TVal key = keys.get_array_idx(i) ?? (TVal) { };
            if (!key.is_string()) return ctx.throw_error(TYPE, "route parameter names must be strings");
        }

        foreach (server : g_runtime.servers) {
            if (server.index != index) continue;
            Route* route = mem::new(Route);
            route.server = server;
            route.handler = ctx.persist(ctx.arg(3)) ?? (JsValue) { };
            route.keys = mem::new_array(JsValue, count);
            for (uint i = 0; i < count; i++) {
                JsArg name = { .tv = keys.get_array_idx(i) ?? (TVal) { } };
                route.keys[i] = ctx.persist(name) ?? (JsValue) { };
            }
            server.routes.push(route);
            String method = ctx.arg(1).as_string() ?? "*";
            String path   = ctx.arg(2).as_string() ?? "";
            uws_app_route(server.app, method.zstr_tcopy(), path.zstr_tcopy(), &on_route, route);
            return;
        }
    };
}

// httpStaticRoute(index, method, pattern, status, statusText, headers, body)
fn void js_http_static_route(JsCtx ctx, void* udata) {
    @pool() {
        uint index = ctx.arg(0).id();
        foreach (server : g_runtime.servers) {
            if (server.index != index) continue;
            Route* route = mem::new(Route);
            route.server = server;
            route.fixed = true;
            route.response = { ctx.arg(3)
                .as_int(200), ((String)ctx.arg(4)
                    .bytes()).copy(mem), ((String)ctx.arg(5).bytes()).copy(mem), copy_bytes(ctx.arg(6).bytes()), {}, {} };
            prepare_static(&route.response);
            server.routes.push(route);
            String method = ctx.arg(1).as_string() ?? "*";
            String path   = ctx.arg(2).as_string() ?? "";
            uws_app_route(server.app, method.zstr_tcopy(), path.zstr_tcopy(), &on_route, route);
            return;
        }
    };
}

// serve(index, hostname, port, cert, key) -> bound port. A cert and key are
// file paths; both or neither.
fn void js_serve(JsCtx ctx, void* udata) {
    @pool() {
        uint index  = ctx.arg(0).id();
        String host = ctx.arg(1).as_string() ?? "0.0.0.0";
        int port    = ctx.arg(2).as_int(8080);
        String cert = ctx.arg(3).as_string() ?? "";
        String key  = ctx.arg(4).as_string() ?? "";
        bool use_tls = cert.len > 0;
        if (use_tls != (key.len > 0)) return ctx.throw_error(TYPE, "tls needs both a cert and a key file");
        Server* parent = g_runtime.worker ? g_runtime.worker.http_server : null;
        if ((parent || g_runtime.http_workers > 1 || g_runtime.http_processes) && g_runtime.servers.len()) {
            return ctx.throw_error(TYPE, "HTTP worker mode supports one serve() per entry module");
        }
        if (parent && (host != parent.hostname || port != parent.requested_port)) {
            return ctx.throw_error(TYPE, "HTTP worker listener configuration differs from its parent");
        }
        if (use_tls && (parent || g_runtime.http_workers > 1 || g_runtime.http_processes)) {
            return ctx.throw_error(TYPE, "TLS serve() runs on a single HTTP thread only");
        }
        if (use_tls && !tls_available()) {
            return ctx.throw_error(TYPE, string::tformat("TLS serve() needs OpenSSL 3; install it with: %s", OPENSSL_HINT));
        }
        if (!check_net(host, port)) {
            ctx.throw_coded(
                "PERMISSION_DENIED",
                string::tformat("net access to \"%s\" denied; run with --allow-net", describe(host, port))
            );
            return;
        }
        if (use_tls && (!check_path(READ, cert) || !check_path(READ, key))) {
            ctx.throw_coded("PERMISSION_DENIED", "read access to the TLS cert or key denied");
            return;
        }
        Server* s = mem::new(Server);
        s.index = index;
        // serve may run inside an async completion scope; the ID outlives it.
        s.index_value = ctx.persist(ctx.number(index))!!;
        s.statics.init(mem);
        s.routes.init(mem);
        s.app = use_tls
            ? uws_app_new_tls(&on_request, s, cert.zstr_tcopy(), key.zstr_tcopy())
            : uws_app_new(&on_request, s);
        if (s.app == null) return ctx.throw_error(TYPE, "could not load the TLS cert or key");
        s.hostname = host.copy(mem);
        s.requested_port = port;
        CInt bound = parent ? parent.port : uws_app_listen(s.app, host.zstr_tcopy(), port);
        if (bound < 0) {
            ctx.throw_coded("EADDRINUSE", string::tformat("could not listen on %s", describe(host, port)));
            uws_app_stop(s.app, 1);
            return;
        }
        g_runtime.servers.push(s);
        s.port = bound;
        ctx.ret_number(bound);
    };
}

// stop(index, force)
fn void js_stop(JsCtx ctx, void* udata) {
    uint index = ctx.arg(0).id();
    bool force = ctx.arg(1).as_bool() ?? false;
    foreach (s : g_runtime.servers) {
        if (s.index != index || s.stopped) continue;
        s.stopped = true;
        @pool() {
            ulong[] ids = g_runtime.workers.keys(tmem);
            foreach (id : ids) {
                WorkerThread* w = g_runtime.workers.get(id)!!;
                if (w.http_server == s) {
                    if (force) { worker_request_stop(w); }
                    else { worker_request_http_drain(w); }
                }
            }
        };
        uws_app_stop(s.app, force ? 1 : 0);
    }
}

fn void js_http_pool_start(JsCtx ctx, void* user) {
    foreach (s : g_runtime.servers) {
        if (s.index != ctx.arg(0).id() || s.pool_started) continue;
        s.pool_started = true;
        Server* parent = g_runtime.worker ? g_runtime.worker.http_server : null;
        if (parent) {
            if (!uws_app_pool_join(s.app, parent.app)) return ctx.throw_error(ERROR, "HTTP worker pool is stopping");
        } else if (g_runtime.http_workers > 1) {
            if (!check_path(READ, canonical(g_runtime.main))) return ctx.throw_coded("PERMISSION_DENIED", "HTTP worker entry read access denied");
            uws_app_pool_init(s.app);
            for (uint i = 1; i < g_runtime.http_workers; i++) {
                WorkerThread*? w = start_worker(g_runtime.main, string::tformat("http-%d", i), s);
                if (catch w) return ctx.throw_error(ERROR, "Cannot create HTTP worker");
                s.pool_live++;
            }
        }
        return;
    }
}

fn void js_http_pool_count(JsCtx ctx, void* user) {
    foreach (s : g_runtime.servers) if (s.index == ctx.arg(0).id()) {
        ctx.ret_number(s.stopped ? 0 : uws_app_pool_count(s.app)); return;
    }
    ctx.ret_number(0);
}

fn void js_http_pool_pending(JsCtx ctx, void* user) {
    foreach (s : g_runtime.servers) if (s.index == ctx.arg(0).id()) {
        bool draining;
        if (s.stopped && (g_runtime.http_workers > 1 || g_runtime.http_processes)) {
            draining = !uws_app_pool_idle(s.app);
            // Retire idle main-loop keep-alive sockets once all responses drain.
            if (!draining && !s.pool_live) uws_app_stop(s.app, 1);
        }
        ctx.ret_number((double)(s.pool_live + (draining ? 1u : 0u))); return;
    }
    ctx.ret_number(0);
}

fn void js_http_pool_target(JsCtx ctx, void* user) => ctx.ret_number(g_runtime.http_workers);

const Native[] HTTP_NATIVES = {
    { "httpPoolStart", &js_http_pool_start, 1 },
    { "httpPoolCount", &js_http_pool_count, 1 },
    { "httpPoolPending", &js_http_pool_pending, 1 },
    { "httpPoolTarget", &js_http_pool_target, 0 },
    { "serve", &js_serve, 5 },
    { "staticRoute", &js_static_route, 6 },
    { "httpRoute", &js_http_route, 5 },
    { "httpStaticRoute", &js_http_static_route, 7 },
    { "fastTypes", &js_fast_types, 5 },
    { "fetchFor", &js_fetch_for, 3 },
    { "httpFulfilled", &js_http_fulfilled, 1 },
    { "httpRejected", &js_http_rejected, 1 },
    { "nativeResponse", &js_native_response, 2 },
    { "stop", &js_stop, 2 },
    { "respond", &js_respond, 5 },
    { "streamStart", &js_stream_start, 4 },
    { "streamWrite", &js_stream_write, 2 },
    { "streamFinish", &js_stream_finish, 2 },
    { "sinkTypes", &js_sink_types, 4 },
    { "sinkEnqueue", &js_sink_enqueue, 1 },
    { "streamEnd", &js_stream_end, 1 },
    { "reqUrl", &js_req_url, 1 },
    { "reqHeaders", &js_req_headers, 1 },
    { "reqRemote", &js_req_remote, 1 },
};
