// The same JS-backed HTTP server as src/main.c3, but on uWebSockets instead of
// libwebsockets. Separate binary (`out/test-server-uws`) so the two can be
// benchmarked against each other and against node/bun.
//
// uWebSockets is C++, so it is reached through the extern "C" shim in
// shim/uws_shim.cpp; build it with scripts/build_uws.sh first. The shim owns
// the accept loop and calls back here once per request, which is why this file
// has no event loop of its own.
//
// The JS half is deliberately identical to src/main.c3: the handler is
// compiled once at startup and held as a rooted value, so nothing in the hot
// path compiles JS. Only the HTTP frontend differs.
//
// With more than one thread each gets its own Worker -- its own runtime, heap
// and handler -- and uSockets' SO_REUSEPORT spreads accepts across them. The
// engine has no locking, but two threads driving separate runtimes share
// nothing, and every runtime is opened and bootstrapped on the main thread
// before any worker starts, so the engine's process-global init and the
// compiler are never touched concurrently.
module test_server_uws;

import boomkat;
import std::io;
import std::core::mem;
import std::thread;

const int DEFAULT_PORT = 8080;
const int MAX_THREADS = 64;

// The handler is user JS. It takes the request method and URL and returns the
// response body. The trailing expression is the function itself, so eval hands
// it straight back.
const String BOOTSTRAP = `
function handler(method, url) {
    return method + " " + url;
}
handler
`;

// One per thread. Never shared: the thread that owns a Worker is the only one
// that touches its runtime.
struct Worker
{
    int index;
    JsRuntime rt;
    JsValue handler;                          // rooted for the life of the process
    JsValue[COMMON_METHODS.len] methods;      // ditto, indexed like COMMON_METHODS
}

Worker[MAX_THREADS] g_workers;
int g_port;
int g_threads;

// Skips the JS engine entirely and formats the response in C3. Not a mode to
// serve with -- it exists to attribute cost, by showing what the HTTP frontend
// alone can do with the same output.
bool g_no_js;

// Methods repeat across essentially every request, so their JS strings are
// interned and rooted once per worker instead of per request. Anything not
// listed falls back to interning on the spot.
const String[] COMMON_METHODS = { "GET", "POST", "HEAD", "PUT", "DELETE",
                                  "OPTIONS", "PATCH" };

// Size of a worker's temp arena. Each request resets it, so this only has to
// hold one response, but it is the thread's whole budget for tmem.
const sz WORKER_POOL = 256 * 1024;

// Entry point for every listener thread, including the main one.
//
// The temp allocator is thread-local and is only created implicitly on the
// main thread, so each worker has to bring up its own around the entire loop:
// @pool() inside the request handler derives from this.
fn int worker_main(void* arg)
{
    Worker* w = (Worker*)arg;
    int rc;
    @pool_init(mem, WORKER_POOL)
    {
        rc = uws_run_one(g_port, &on_request, (void*)w, 0, w.index, g_threads);
    };
    return rc;
}

// ---- the shim ----

// Fills `out` with the response body, writing its length and the HTTP status
// back through the out-parameters. Runs on the event loop thread, one request
// at a time, which is what the single-threaded JS runtime needs.
alias UwsReqCb = fn void(void* user, char* method, sz method_len,
                         char* url, sz url_len,
                         char* out, sz out_cap, sz* out_len, int* out_status);

// Runs one event loop on the calling thread and blocks. Several threads may
// call it on the same port; uSockets sets SO_REUSEPORT.
// `index` and `nthreads` place this loop in the cluster that redistributes
// accepted sockets; see the shim for why that is needed on macOS.
extern fn int uws_run_one(int port, UwsReqCb cb, void* user, sz max_body,
                          int index, int nthreads);

// ---- dispatch ----

// Calls the JS handler and returns its result as a string. The result is
// allocated in the temp arena, so the caller must be inside a @pool.
fn String? Worker.dispatch(&self, String method, String url)
{
    // A cached method value costs a compare against a handful of short
    // strings; interning one costs a hash and a table probe.
    JsValue m = {};
    bool m_cached = false;
    foreach (i, name : COMMON_METHODS)
    {
        if (name == method) { m = self.methods[i]; m_cached = true; break; }
    }
    if (!m_cached) m = self.rt.string(method)!;
    defer if (!m_cached) self.rt.release(m);

    JsValue u = self.rt.string(url)!;
    defer self.rt.release(u);

    JsValue[2] args = { m, u };
    JsValue result = self.rt.call(self.handler, args[..])!;
    defer self.rt.release(result);

    // The handler returns a string, so read it strictly. to_display_string
    // would coerce, which means running JS on a value that is already the
    // right type; fall back to it only if the handler returned something else.
    String? direct = self.rt.as_string(result);
    if (try direct) return direct;
    return self.rt.to_display_string(result);
}

fn void emit(char* out, sz out_cap, sz* out_len, String body) @inline
{
    sz n = body.len > out_cap ? out_cap : body.len;
    mem::copy(out, body.ptr, n);
    *out_len = n;
}

fn void on_request(void* user, char* method, sz method_len,
                   char* url, sz url_len,
                   char* out, sz out_cap, sz* out_len, int* out_status)
{
    Worker* w = (Worker*)user;

    if (g_no_js)
    {
        *out_status = 200;
        sz n = 0;
        for (sz i = 0; i < method_len && n < out_cap; i++) out[n++] = method[i];
        if (n < out_cap) out[n++] = ' ';
        for (sz i = 0; i < url_len && n < out_cap; i++) out[n++] = url[i];
        *out_len = n;
        return;
    }

    // to_display_string allocates from tmem, which is thread-local, so each
    // request gets its own arena rather than growing one for the life of the
    // process -- and worker threads never share one.
    @pool()
    {
        String? body = w.dispatch((String)method[:method_len], (String)url[:url_len]);
        if (catch err = body)
        {
            io::eprintfn("handler failed: %s: %s", err, w.rt.last_error());
            *out_status = 500;
            emit(out, out_cap, out_len, "Internal Server Error");
        }
        else
        {
            *out_status = 200;
            emit(out, out_cap, out_len, body);
        }
    };
}

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
        if (catch parsed) { io::eprintfn("usage: %s [port] [threads] [nojs]", args[0]); return 1; }
        threads = parsed;
    }
    if (args.len > 3 && args[3] == "nojs") g_no_js = true;
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

        foreach (mi, name : COMMON_METHODS)
        {
            JsValue? mv = w.rt.string(name);
            if (catch err = mv)
            {
                io::eprintfn("interning method %s failed: %s", name, err);
                return 1;
            }
            w.methods[mi] = mv;
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
