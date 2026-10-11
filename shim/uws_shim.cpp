// extern "C" shim over uWebSockets.
//
// uWebSockets is C++ (header-only, templated on the SSL flag), so C3 cannot
// bind it directly. This is a thin, one-to-one C surface over the parts of
// HttpRequest and HttpResponse the server uses. Everything above that --
// buffering bodies, building the Request, writing a Response, timers' JS side
// -- lives in C3 (src-uws/), so this file should stay a set of pass-throughs.
//
// Threading is the caller's job: this runs exactly one event loop on the calling
// thread. uSockets sets SO_REUSEPORT on the listen socket, so several threads
// can each call this on the same port and the kernel spreads accepts across
// them. Nothing is shared between loops, which is what lets the caller give
// each its own single-threaded JS runtime.
//
// The caller owns the threads because a C3 worker has to set up its
// thread-local temp allocator around the whole loop, which it cannot do if a
// C++ thread calls into it.
#include "App.h"

#include <cstddef>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <vector>

extern "C" {

// Opaque to the caller: these are uWS::HttpRequest and uWS::HttpResponse<false>.
// A request is only valid during the request callback; a response is valid
// until it is ended or its abort callback runs.
typedef struct uws_req uws_req;
typedef struct uws_res uws_res;

// Called on the loop thread that owns `user`, one request at a time. Whatever
// the callback does not end before returning it must have hooked with
// uws_res_on_aborted, as uWS requires.
typedef void (*uws_req_cb)(void *user, uws_req *req, uws_res *res);

// ---- request, valid only inside the request callback ----

// Lowercase, as uWS reports it.
size_t uws_req_method(uws_req *req, const char **out);
// Path only; the query is separate.
size_t uws_req_url(uws_req *req, const char **out);
// Without the leading '?'; empty when there is none.
size_t uws_req_query(uws_req *req, const char **out);
// Up to `cap` headers in arrival order, keys lowercased, pointing into the
// request buffer. Returns how many were written.
typedef struct { const char *key; size_t key_len; const char *val; size_t val_len; } uws_header;
int uws_req_headers(uws_req *req, uws_header *out, int cap);

// ---- response ----

// `last` is set on the final chunk. The chunk is only valid during the call.
typedef void (*uws_data_cb)(void *user, const char *chunk, size_t len, int last);
void uws_res_on_data(uws_res *res, uws_data_cb cb, void *user);
void uws_res_on_aborted(uws_res *res, void (*cb)(void *), void *user);

// `status` is the full status line text, e.g. "404 Not Found".
void uws_res_write_status(uws_res *res, const char *status, size_t len);
void uws_res_write_header(uws_res *res, const char *key, size_t key_len,
                          const char *val, size_t val_len);
void uws_res_end(uws_res *res, const char *body, size_t len);
// Run `cb(user)` with the socket corked, so writes made outside the request
// callback still leave as one packet.
void uws_res_cork(uws_res *res, void (*cb)(void *), void *user);

// Run `cb(user)` once after `ms` milliseconds on the calling thread's loop.
// The returned handle is valid until the callback starts or the timer is
// cancelled, whichever comes first.
void *uws_timer_start(int ms, void (*cb)(void *), void *user);
void uws_timer_cancel(void *timer);

// Runs one listener on the calling thread. Blocks forever once bound.
// Returns 0 if the port was bound, -1 if it was not.
//
// `index` identifies this loop within a cluster of `nthreads`. With nthreads
// > 1 the loops form a cluster: whichever one the kernel hands an accepted
// socket to redistributes it round-robin to the others.
//
// This is what SO_REUSEPORT alone does not buy on macOS, where the kernel
// delivers every connection to a single socket instead of balancing across
// them -- measured as one busy thread and the rest idle. Handing the accepted
// fd across loops explicitly does not depend on kernel behaviour. It is the
// approach uWebSockets' own LocalCluster.h takes.
int uws_run_one(int port, uws_req_cb cb, void *user, int index, int nthreads);

}

using Req = uWS::HttpRequest;
using Res = uWS::HttpResponse<false>;

namespace {

struct TimerExt {
    void (*cb)(void *);
    void *user;
};

// Cluster rendezvous. Every loop must be constructed and registered before any
// of them starts accepting, or a socket could be handed to a null app.
struct Cluster {
    std::vector<uWS::App *> apps;
    std::atomic<unsigned> next{0};
    std::mutex m;
    std::condition_variable cv;
    int registered = 0;
    int total = 0;
};

Cluster g_cluster;

// preOpen takes a bare function pointer, so the handler cannot capture. The
// accepting loop's own index reaches it through this instead.
thread_local int t_index = -1;

bool serve(int port, uws_req_cb cb, void *user, int index, int nthreads) {
    bool listening = false;

    uWS::App app;

    if (nthreads > 1) {
        // Publish this loop, then wait for every sibling before running.
        {
            std::unique_lock<std::mutex> lock(g_cluster.m);
            g_cluster.apps[index] = &app;
            g_cluster.registered++;
            g_cluster.cv.notify_all();
            g_cluster.cv.wait(lock, [] {
                return g_cluster.registered == g_cluster.total;
            });
        }

        t_index = index;
        app.preOpen([](struct us_socket_context_t *, LIBUS_SOCKET_DESCRIPTOR fd,
                       char *ip, int ip_length) -> LIBUS_SOCKET_DESCRIPTOR {
            unsigned target = g_cluster.next.fetch_add(1, std::memory_order_relaxed)
                              % (unsigned)g_cluster.total;

            // Already ours: keep it rather than paying a cross-loop hop.
            if ((int)target == t_index) return fd;

            uWS::App *receiver = g_cluster.apps[target];
            receiver->getLoop()->defer(
                [fd, ipStore = std::string(ip, ip + ip_length), receiver]() {
                    receiver->adoptSocket(fd, std::string_view(ipStore));
                });
            // -1 tells uWS this loop is no longer responsible for the socket.
            return (LIBUS_SOCKET_DESCRIPTOR)-1;
        });
    }

    app.any("/*", [cb, user](auto *res, auto *req) {
        cb(user, (uws_req *)req, (uws_res *)res);
    });

    app.listen("127.0.0.1", port, [&listening](auto *token) {
        listening = token != nullptr;
    });

    if (!listening) return false;
    app.run();
    return true;
}

} // namespace

size_t uws_req_method(uws_req *req, const char **out) {
    std::string_view v = ((Req *)req)->getMethod();
    *out = v.data();
    return v.size();
}

size_t uws_req_url(uws_req *req, const char **out) {
    std::string_view v = ((Req *)req)->getUrl();
    *out = v.data();
    return v.size();
}

size_t uws_req_query(uws_req *req, const char **out) {
    std::string_view v = ((Req *)req)->getQuery();
    *out = v.data();
    return v.size();
}

int uws_req_headers(uws_req *req, uws_header *out, int cap) {
    int n = 0;
    for (auto [k, v] : *(Req *)req) {
        if (n == cap) break;
        out[n++] = uws_header{k.data(), k.size(), v.data(), v.size()};
    }
    return n;
}

void uws_res_on_data(uws_res *res, uws_data_cb cb, void *user) {
    ((Res *)res)->onData([cb, user](std::string_view chunk, bool last) {
        cb(user, chunk.data(), chunk.size(), last ? 1 : 0);
    });
}

void uws_res_on_aborted(uws_res *res, void (*cb)(void *), void *user) {
    ((Res *)res)->onAborted([cb, user]() { cb(user); });
}

void uws_res_write_status(uws_res *res, const char *status, size_t len) {
    ((Res *)res)->writeStatus(std::string_view(status, len));
}

void uws_res_write_header(uws_res *res, const char *key, size_t key_len,
                          const char *val, size_t val_len) {
    ((Res *)res)->writeHeader(std::string_view(key, key_len), std::string_view(val, val_len));
}

void uws_res_end(uws_res *res, const char *body, size_t len) {
    ((Res *)res)->end(std::string_view(body, len));
}

void uws_res_cork(uws_res *res, void (*cb)(void *), void *user) {
    ((Res *)res)->cork([cb, user]() { cb(user); });
}

void *uws_timer_start(int ms, void (*cb)(void *), void *user) {
    struct us_loop_t *loop = (struct us_loop_t *)uWS::Loop::get();
    struct us_timer_t *t = us_create_timer(loop, 0, sizeof(TimerExt));
    *(TimerExt *)us_timer_ext(t) = TimerExt{cb, user};
    // uSockets reads 0 ms as "disarmed", and a 0 ms timeout means "soon".
    us_timer_set(t, [](struct us_timer_t *t) {
        TimerExt e = *(TimerExt *)us_timer_ext(t);
        us_timer_close(t);
        e.cb(e.user);
    }, ms < 1 ? 1 : ms, 0);
    return t;
}

void uws_timer_cancel(void *timer) {
    if (timer != nullptr) us_timer_close((struct us_timer_t *)timer);
}

int uws_run_one(int port, uws_req_cb cb, void *user, int index, int nthreads) {
    if (cb == nullptr || nthreads < 1 || index < 0 || index >= nthreads) return -1;

    if (nthreads > 1) {
        // The first caller in sizes the cluster; all callers must agree.
        std::lock_guard<std::mutex> lock(g_cluster.m);
        if (g_cluster.total == 0) {
            g_cluster.total = nthreads;
            g_cluster.apps.assign((size_t)nthreads, nullptr);
        } else if (g_cluster.total != nthreads) {
            return -1;
        }
    }

    return serve(port, cb, user, index, nthreads) ? 0 : -1;
}
