// extern "C" shim over uWebSockets.
//
// uWebSockets is C++ (header-only, templated on the SSL flag), so C3 cannot
// bind it directly. This exposes the smallest surface the server needs: run
// one or more listener threads that hand each request's method and URL to a C
// callback and send back whatever the callback writes.
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

// Fills `out` with the response body and writes its length and HTTP status
// through the out-parameters. Called on the loop thread that owns `user`, one
// request at a time, so a `user` never sees concurrent calls.
typedef void (*uws_req_cb)(void *user,
                           const char *method, size_t method_len,
                           const char *url, size_t url_len,
                           char *out, size_t out_cap, size_t *out_len,
                           int *out_status);

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
int uws_run_one(int port, uws_req_cb cb, void *user, size_t max_body,
                int index, int nthreads);

}

namespace {

// Matches the 8 KB response cap on the libwebsockets server, so the two are
// limited the same way rather than one silently truncating later than the other.
constexpr size_t kDefaultMaxBody = 8192;

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

bool serve(int port, uws_req_cb cb, void *user, size_t max_body,
           int index, int nthreads) {
    bool listening = false;

    // Reused across requests: handlers run one at a time on this thread and
    // the body is copied into the socket before the next one starts, so there
    // is nothing to keep between calls. Per-thread, never shared.
    std::vector<char> buf(max_body);

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

    app.any("/*", [cb, user, &buf, max_body](auto *res, auto *req) {
        // uWS reports the method lowercase ("get"); the libwebsockets server
        // reports it uppercase, and the JS handler echoes it, so normalise
        // here to keep the two servers byte-identical.
        std::string_view m = req->getMethod();
        char method[16];
        size_t mlen = m.size() < sizeof(method) ? m.size() : sizeof(method);
        for (size_t i = 0; i < mlen; i++) {
            char c = m[i];
            method[i] = (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
        }

        std::string_view u = req->getUrl();

        size_t out_len = 0;
        int status = 200;
        cb(user, method, mlen, u.data(), u.size(), buf.data(), max_body,
           &out_len, &status);
        if (out_len > max_body) out_len = max_body;

        // 200 is uWS's default, so only a failure writes a status line.
        if (status != 200) {
            res->writeStatus(status == 500 ? "500 Internal Server Error"
                                           : "400 Bad Request");
        }
        res->writeHeader("Content-Type", "text/plain");
        res->end(std::string_view(buf.data(), out_len));
    });

    app.listen("127.0.0.1", port, [&listening](auto *token) {
        listening = token != nullptr;
    });

    if (!listening) return false;
    app.run();
    return true;
}

} // namespace

int uws_run_one(int port, uws_req_cb cb, void *user, size_t max_body,
                int index, int nthreads) {
    if (cb == nullptr || nthreads < 1 || index < 0 || index >= nthreads) return -1;
    if (max_body == 0) max_body = kDefaultMaxBody;

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

    return serve(port, cb, user, max_body, index, nthreads) ? 0 : -1;
}
