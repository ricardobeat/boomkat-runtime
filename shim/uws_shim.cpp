// extern "C" pass-throughs over the parts of uWebSockets C3 cannot reach:
// the templated App, HttpRequest and HttpResponse. Loops, timers, polls and
// raw sockets are plain uSockets and are bound from C3 directly.
#include "App.h"

#include <cstddef>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <unistd.h>

extern "C" {

typedef struct uws_app uws_app;
typedef struct uws_req uws_req;
typedef struct uws_res uws_res;
typedef void (*uws_req_cb)(void *user, uws_req *req, uws_res *res);
typedef void (*uws_data_cb)(void *user, const char *chunk, size_t len, int last);
typedef int (*uws_writable_cb)(void *user, uintmax_t offset);
typedef struct { const char *key; size_t key_len; const char *val; size_t val_len; } uws_header;

}

using Req = uWS::HttpRequest;
using Res = uWS::HttpResponse<false>;

namespace {

struct App;
struct Endpoint {
    App *app;
    uWS::Loop *loop;
    bool active = true; // guarded by Dispatch::lock
};
struct Dispatch {
    std::mutex lock;
    std::vector<std::shared_ptr<Endpoint>> endpoints;
    size_t next = 0;
    bool stopped = false;
};
struct App {
    uWS::App app;
    us_listen_socket_t *listener = nullptr;
    std::shared_ptr<Dispatch> dispatch;
    std::shared_ptr<Endpoint> endpoint;
    bool dispatch_owner = false;
    us_socket_context_t *dispatch_context = nullptr;
    std::unordered_set<Res *> connections; // owned by this app's loop
};

std::mutex dispatch_registry_lock;
std::unordered_map<us_socket_context_t *, std::shared_ptr<Dispatch>> dispatch_registry;

// The descriptor stays owned even if a target loop drops its deferred callback.
struct AcceptedFd {
    int fd;
    std::string ip;
    ~AcceptedFd() { if (fd >= 0) close(fd); }
};

LIBUS_SOCKET_DESCRIPTOR dispatch_connection(us_socket_context_t *context, LIBUS_SOCKET_DESCRIPTOR fd, char *ip, int length) {
    std::shared_ptr<Dispatch> dispatch;
    {
        std::lock_guard<std::mutex> guard(dispatch_registry_lock);
        auto found = dispatch_registry.find(context);
        if (found == dispatch_registry.end()) return fd;
        dispatch = found->second;
    }
    std::lock_guard<std::mutex> guard(dispatch->lock);
    if (dispatch->stopped || dispatch->endpoints.empty()) { close(fd); return fd + 1; }
    auto target = dispatch->endpoints[dispatch->next++ % dispatch->endpoints.size()];
    if (target->loop == uWS::Loop::get()) return fd;
    auto accepted = std::make_shared<AcceptedFd>();
    accepted->fd = fd;
    if (length) accepted->ip.assign(ip, length);
    // Defer while holding the membership lock: a worker cannot retire its loop
    // between selecting an endpoint and enqueueing the descriptor.
    target->loop->defer([dispatch, target, accepted]() {
        {
            std::lock_guard<std::mutex> guard(dispatch->lock);
            if (!target->active || dispatch->stopped) return;
        }
        // Adoption and stop both run on this endpoint's execution thread.
        int fd = accepted->fd;
        accepted->fd = -1;
        target->app->app.adoptSocket(fd, accepted->ip);
    });
    return fd + 1;
}

void detach_dispatch(App *app) {
    if (!app->dispatch) return;
    std::lock_guard<std::mutex> guard(app->dispatch->lock);
    app->endpoint->active = false;
    auto &members = app->dispatch->endpoints;
    members.erase(std::remove(members.begin(), members.end(), app->endpoint), members.end());
    app->dispatch->next = 0;
    if (app->dispatch_owner) app->dispatch->stopped = true;
}

void track_connections(App *app) {
    app->app.filter([app](Res *res, int change) {
        if (change > 0) app->connections.insert(res);
        else app->connections.erase(res);
    });
}

}

extern "C" {

void *uws_loop(void) { return uWS::Loop::get(); }

void uws_loop_run(void) { uWS::Loop::get()->run(); }

void uws_loop_on_pre(void (*cb)(void *), void *user) {
    uWS::Loop::get()->addPreHandler(user, [cb, user](uWS::Loop *) { cb(user); });
}

// Thread-safe: runs cb(user) on `loop`'s thread at its next iteration.
void uws_loop_defer(void *loop, void (*cb)(void *), void *user) {
    ((uWS::Loop *)loop)->defer([cb, user]() { cb(user); });
}

uws_app *uws_app_new(uws_req_cb cb, void *user) {
    App *a = new App();
    a->app.any("/*", [cb, user](auto *res, auto *req) { cb(user, (uws_req *)req, (uws_res *)res); });
    return (uws_app *)a;
}

void uws_app_route(uws_app *app, const char *method, const char *path, uws_req_cb cb, void *user) {
    App *a = (App *)app;
    auto handler = [cb, user](auto *res, auto *req) { cb(user, (uws_req *)req, (uws_res *)res); };
    std::string m(method);
    if (m == "GET") a->app.get(path, std::move(handler));
    else if (m == "HEAD") a->app.head(path, std::move(handler));
    else if (m == "POST") a->app.post(path, std::move(handler));
    else if (m == "PUT") a->app.put(path, std::move(handler));
    else if (m == "PATCH") a->app.patch(path, std::move(handler));
    else if (m == "DELETE") a->app.del(path, std::move(handler));
    else if (m == "OPTIONS") a->app.options(path, std::move(handler));
    else if (m == "TRACE") a->app.trace(path, std::move(handler));
    else if (m == "CONNECT") a->app.connect(path, std::move(handler));
    else a->app.any(path, std::move(handler));
}

size_t uws_req_parameter(uws_req *req, unsigned short index, const char **out) {
    std::string_view value = ((Req *)req)->getParameter(index);
    *out = value.data();
    return value.size();
}

// The bound port, or -1.
int uws_app_listen(uws_app *app, const char *host, int port) {
    App *a = (App *)app;
    a->app.listen(std::string(host), port, [a](auto *token) { a->listener = token; });
    if (!a->listener) return -1;
    return us_socket_local_port(0, (us_socket_t *)a->listener);
}

void uws_app_pool_init(uws_app *app) {
    auto *a = (App *)app;
    a->dispatch = std::make_shared<Dispatch>();
    a->endpoint = std::make_shared<Endpoint>();
    a->endpoint->app = a;
    a->endpoint->loop = uWS::Loop::get();
    a->dispatch->endpoints.push_back(a->endpoint);
    a->dispatch_owner = true;
    track_connections(a);
    a->dispatch_context = us_socket_context(0, (us_socket_t *)a->listener);
    {
        std::lock_guard<std::mutex> guard(dispatch_registry_lock);
        dispatch_registry[a->dispatch_context] = a->dispatch;
    }
    a->app.preOpen(dispatch_connection);
}

int uws_app_pool_join(uws_app *app, uws_app *parent) {
    auto *a = (App *)app, *p = (App *)parent;
    auto dispatch = p->dispatch;
    std::lock_guard<std::mutex> guard(dispatch->lock);
    if (dispatch->stopped) return 0;
    a->dispatch = dispatch;
    a->endpoint = std::make_shared<Endpoint>();
    a->endpoint->app = a;
    a->endpoint->loop = uWS::Loop::get();
    track_connections(a);
    dispatch->endpoints.push_back(a->endpoint);
    return 1;
}

int uws_app_pool_count(uws_app *app) {
    auto *a = (App *)app;
    if (!a->dispatch) return 1;
    std::lock_guard<std::mutex> guard(a->dispatch->lock);
    return a->dispatch->stopped ? 0 : (int)a->dispatch->endpoints.size();
}

int uws_app_pool_idle(uws_app *app) {
    auto *a = (App *)app;
    for (auto *res : a->connections) {
        auto *data = (uWS::HttpResponseData<false> *)us_socket_ext(0, (us_socket_t *)res);
        if (!res->hasResponded() || data->buffer.length()) return 0;
    }
    return 1;
}

void uws_app_stop(uws_app *app, int force) {
    App *a = (App *)app;
    detach_dispatch(a);
    if (a->listener) us_listen_socket_close(0, a->listener);
    a->listener = nullptr;
    if (force) a->app.close();
}

void uws_app_free(uws_app *app) {
    auto *a = (App *)app;
    detach_dispatch(a);
    if (a->dispatch_owner) {
        std::lock_guard<std::mutex> guard(dispatch_registry_lock);
        dispatch_registry.erase(a->dispatch_context);
    }
    delete a;
}

size_t uws_req_method(uws_req *req, const char **out) {
    std::string_view v = ((Req *)req)->getCaseSensitiveMethod();
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

size_t uws_res_remote(uws_res *res, const char **out) {
    std::string_view v = ((Res *)res)->getRemoteAddressAsText();
    *out = v.data();
    return v.size();
}

void uws_res_on_data(uws_res *res, uws_data_cb cb, void *user) {
    ((Res *)res)->onData([cb, user](std::string_view chunk, bool last) {
        cb(user, chunk.data(), chunk.size(), last ? 1 : 0);
    });
}

void uws_res_on_aborted(uws_res *res, void (*cb)(void *), void *user) {
    ((Res *)res)->onAborted([cb, user]() { cb(user); });
}

void uws_res_on_writable(uws_res *res, uws_writable_cb cb, void *user) {
    ((Res *)res)->onWritable([cb, user](uintmax_t off) { return cb(user, off) != 0; });
}

void uws_res_write_status(uws_res *res, const char *status, size_t len) {
    ((Res *)res)->writeStatus(std::string_view(status, len));
}

void uws_res_write_header(uws_res *res, const char *key, size_t key_len,
                          const char *val, size_t val_len) {
    ((Res *)res)->writeHeader(std::string_view(key, key_len), std::string_view(val, val_len));
}

// Chunked write; 0 when the socket buffer is full and the caller should
// wait for on_writable.
int uws_res_write(uws_res *res, const char *data, size_t len) {
    return ((Res *)res)->write(std::string_view(data, len)) ? 1 : 0;
}

void uws_res_end(uws_res *res, const char *body, size_t len) {
    ((Res *)res)->end(std::string_view(body, len));
}

void uws_res_end_empty(uws_res *res) {
    ((Res *)res)->endWithoutBody(std::nullopt);
}

void uws_res_cork(uws_res *res, void (*cb)(void *), void *user) {
    ((Res *)res)->cork([cb, user]() { cb(user); });
}

void uws_res_close(uws_res *res) { ((Res *)res)->close(); }

}
