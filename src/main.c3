// A tiny JS-backed HTTP server: libwebsockets accepts the request, boomkat
// runs the JS handler, and whatever the handler returns becomes the body.
// Built to be compared against equivalent node/bun servers (see bench/).
//
// The handler function is compiled once at startup and held as a rooted value;
// each request is a direct call on it, so nothing in the hot path compiles JS.
//
// With more than one thread this uses libwebsockets' own SMP support: the
// context is created with count_threads, and each service thread drives its
// own thread service index via lws_service_tsi. lws distributes accepted
// connections across them, so unlike uWebSockets no socket handoff is needed.
// That requires a libwebsockets built with LWS_MAX_SMP > 1 -- see
// scripts/build_lws.sh; the homebrew build ships LWS_MAX_SMP 1, which silently
// clamps count_threads to 1.
module test_server;

import boomkat;
import libwebsockets;
import std::io;
import std::core::mem;
import std::thread;

const int DEFAULT_PORT = 8080;
const int MAX_THREADS = 8;      // must not exceed the library's LWS_MAX_SMP

// Size of a worker's temp arena. Each request resets it, so this only has to
// hold one response.
const sz WORKER_POOL = 256 * 1024;

faultdef WRITE_FAILED, TOO_LARGE;

// The handler is user JS. It takes the request method and URL and returns the
// response body. The trailing expression is the function itself, so eval hands
// it straight back.
const String BOOTSTRAP = `
function handler(method, url) {
    return method + " " + url;
}
handler
`;

// One per service thread. Never shared: the thread that owns a Worker is the
// only one that touches its runtime.
struct Worker
{
    int tsi;             // libwebsockets thread service index
    JsRuntime rt;
    JsValue handler;     // rooted for the life of the process
}

Worker[MAX_THREADS] g_workers;

// The callback runs on the service thread that owns the connection, so the
// right Worker is reachable without asking lws which tsi we are on.
tlocal Worker* t_worker;

libwebsockets::Context* g_ctx;

// ---- request parsing ----

tlocal char[2048] t_url_buf;

// Only the URI tokens this libwebsockets build is known to expose are probed.
// The token carrying the URI also identifies the method, so one pass finds both.
fn void capture_request(libwebsockets::Lws* wsi, String* method, String* url)
{
    int[3] tokens = { libwebsockets::WSI_TOKEN_GET_URI,
                      libwebsockets::WSI_TOKEN_POST_URI,
                      libwebsockets::WSI_TOKEN_OPTIONS_URI };
    String[3] names = { "GET", "POST", "OPTIONS" };

    foreach (i, token : tokens)
    {
        int n = libwebsockets::lws_hdr_copy(wsi, &t_url_buf[0], t_url_buf.len, token);
        if (n <= 0) continue;
        *method = names[i];
        *url = (String)t_url_buf[:(sz)n];
        return;
    }
    // No URI token matched, or the URI was empty.
    *method = "GET";
    *url = "/";
}

// ---- dispatch ----

// Calls the JS handler and returns its result as a string. The result is
// allocated in the temp arena, so the caller must be inside a @pool.
fn String? Worker.dispatch(&self, String method, String url)
{
    JsValue m = self.rt.string(method)!;
    defer self.rt.release(m);
    JsValue u = self.rt.string(url)!;
    defer self.rt.release(u);

    JsValue[2] args = { m, u };
    JsValue result = self.rt.call(self.handler, args[..])!;
    defer self.rt.release(result);

    return self.rt.to_display_string(result);
}

// ---- response ----

// Emits status line, headers and body. `body` is copied into a buffer with
// LWS_PRE headroom, which lws writes in place.
fn void? write_response(libwebsockets::Lws* wsi, uint status, String body)
{
    char[1024] hdr;
    char* hdr_start = (char*)&hdr[0] + libwebsockets::LWS_PRE;
    char* hdr_end = (char*)&hdr[0] + hdr.len;
    char* p = hdr_start;

    if (libwebsockets::lws_add_http_header_status(wsi, status, &p, hdr_end) != 0 ||
        libwebsockets::lws_add_http_header_by_token(wsi,
                libwebsockets::WSI_TOKEN_HTTP_CONTENT_TYPE,
                "text/plain", 10, &p, hdr_end) != 0 ||
        libwebsockets::lws_add_http_header_content_length(wsi, (ulong)body.len,
                &p, hdr_end) != 0 ||
        libwebsockets::lws_finalize_http_header(wsi, &p, hdr_end) != 0)
    {
        return WRITE_FAILED~;
    }

    int hdr_len = (int)(p - hdr_start);
    if (libwebsockets::lws_write(wsi, hdr_start, hdr_len,
                                 libwebsockets::WRITE_HTTP_HEADERS) != hdr_len)
    {
        return WRITE_FAILED~;
    }

    if (body.len == 0) return;

    char[8192] out;
    if (body.len > out.len - libwebsockets::LWS_PRE) return TOO_LARGE~;
    char* body_start = (char*)&out[0] + libwebsockets::LWS_PRE;
    mem::copy(body_start, body.ptr, body.len);
    if (libwebsockets::lws_write(wsi, body_start, body.len,
                                 libwebsockets::WRITE_HTTP) < 0)
    {
        return WRITE_FAILED~;
    }
}

// ---- the lws callback ----

fn int http_callback(libwebsockets::Lws* wsi, libwebsockets::CallbackReason reason,
                     void* user, void* in_, sz len)
{
    if (reason != libwebsockets::CB_HTTP) return 0;

    String method;
    String url;
    capture_request(wsi, &method, &url);

    // to_display_string allocates from tmem, so each request gets its own
    // arena rather than growing one for the life of the process.
    @pool()
    {
        String? body = t_worker.dispatch(method, url);
        if (catch err = body)
        {
            io::eprintfn("handler failed: %s: %s", err, t_worker.rt.last_error());
            if (catch write_response(wsi, 500, "Internal Server Error")) return 1;
        }
        else
        {
            if (catch write_response(wsi, 200, body)) return 1;
        }
    };
    return libwebsockets::lws_http_transaction_completed(wsi);
}

// Entry point for every service thread, including the main one.
//
// The temp allocator is thread-local and only created implicitly on the main
// thread, so each worker brings up its own around the whole service loop;
// @pool() inside the request handler derives from this.
fn int worker_main(void* arg)
{
    Worker* w = (Worker*)arg;
    t_worker = w;
    @pool_init(mem, WORKER_POOL)
    {
        while (libwebsockets::lws_service_tsi(g_ctx, 0, w.tsi) >= 0) {}
    };
    return 0;
}

libwebsockets::Protocols[2] g_protocols = {
    { .name = "http", .callback = &http_callback,
      .per_session_data_size = 0, .rx_buffer_size = 0 },
    { .name = null, .callback = null },
};

fn int main(String[] args)
{
    int port = DEFAULT_PORT;
    int threads = 1;
    if (args.len > 1)
    {
        int? parsed = args[1].to_int();
        if (catch parsed) { io::eprintfn("usage: %s [port] [threads]", args[0]); return 1; }
        port = parsed;
    }
    if (args.len > 2)
    {
        int? parsed = args[2].to_int();
        if (catch parsed) { io::eprintfn("usage: %s [port] [threads]", args[0]); return 1; }
        threads = parsed;
    }
    if (threads < 1 || threads > MAX_THREADS)
    {
        io::eprintfn("threads must be 1..%d", MAX_THREADS);
        return 1;
    }

    // Every runtime is opened and bootstrapped here, on the main thread,
    // before any service thread starts.
    for (int i = 0; i < threads; i++)
    {
        Worker* w = &g_workers[i];
        w.tsi = i;
        if (catch err = w.rt.open())
        {
            io::eprintfn("failed to open JS runtime %d: %s", i, err);
            return 1;
        }
        JsValue? h = w.rt.eval(BOOTSTRAP, "<bootstrap>");
        if (catch err = h)
        {
            io::eprintfn("bootstrap failed on runtime %d: %s: %s", i, err, w.rt.last_error());
            return 1;
        }
        w.handler = h;
    }
    defer for (int i = 0; i < threads; i++) g_workers[i].rt.close();

    // Keep lws quiet; its default log level writes a line per connection.
    libwebsockets::lws_set_log_level(libwebsockets::LLL_ERR | libwebsockets::LLL_WARN, null);

    // The C3 mirror of lws_context_creation_info is sized for the homebrew
    // build (880 bytes); a library built with LWS_MAX_SMP > 1 has 8 more bytes
    // of trailing members. Every field this uses sits at an identical offset in
    // both, so the struct is placed in an over-sized zeroed buffer rather than
    // risking lws reading past the end of a bare C3 value.
    char[1024] info_raw;
    libwebsockets::ContextCreationInfo* info =
        (libwebsockets::ContextCreationInfo*)&info_raw[0];
    libwebsockets::context_info_defaults(info);
    info.port = port;
    info.iface = "127.0.0.1";
    info.protocols = &g_protocols[0];
    info.vhost_name = "test-server";
    info.count_threads = (uint)threads;
    // Without this lws resolves the server's canonical name at vhost setup,
    // which fails on a machine with no resolvable hostname and takes the
    // listen socket down with it.
    info.options = libwebsockets::SERVER_OPTION_SKIP_SERVER_CANONICAL_NAME;

    g_ctx = libwebsockets::lws_create_context(info);
    if (g_ctx == null)
    {
        io::eprintn("failed to create libwebsockets context");
        return 1;
    }
    defer libwebsockets::lws_context_destroy(g_ctx);

    libwebsockets::Vhost* vh = libwebsockets::lws_get_vhost_by_name(g_ctx, "test-server");
    int listen_port = vh == null ? -1 : libwebsockets::lws_get_vhost_listen_port(vh);
    if (listen_port <= 0)
    {
        io::eprintn("vhost has no listen socket");
        return 1;
    }

    // The library clamps count_threads to its compiled-in LWS_MAX_SMP, so ask
    // what we actually got rather than assuming the request was honoured.
    int actual = libwebsockets::lws_get_count_threads(g_ctx);
    if (actual < threads)
    {
        io::eprintfn("warning: asked for %d threads, library allows %d (LWS_MAX_SMP)",
                     threads, actual);
        threads = actual;
    }

    io::printfn("test-server listening on http://127.0.0.1:%d (%d thread%s)",
                listen_port, threads, threads == 1 ? "" : "s");

    // Service threads 1..n-1 get their own thread; tsi 0 runs on this one.
    Thread[MAX_THREADS] pool;
    for (int i = 1; i < threads; i++)
    {
        if (catch err = pool[i].create(&worker_main, (void*)&g_workers[i]))
        {
            io::eprintfn("failed to start service thread %d: %s", i, err);
            return 1;
        }
    }
    worker_main((void*)&g_workers[0]);
    for (int i = 1; i < threads; i++) pool[i].join()!!;
    return 0;
}
