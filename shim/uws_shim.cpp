// extern "C" pass-throughs over the parts of uWebSockets C3 cannot reach:
// the templated App, HttpRequest and HttpResponse. Loops, timers, polls and
// raw sockets are plain uSockets and are bound from C3 directly.
//
// An App serves plain HTTP or TLS, chosen when it is created. Responses and
// WebSockets exist in both forms, so their handles carry the transport in bit 0.
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
int bkr_process_listen(void *app, const char *host, int port, void *loop,
    void (*adopt)(void *, int, const char *, int));
void bkr_process_stop(void *app);

}

using Req = uWS::HttpRequest;

namespace {

struct App;
struct WsData;
template <bool SSL> using Res = uWS::HttpResponse<SSL>;
template <bool SSL> using Ws = uWS::WebSocket<SSL, true, WsData>;

// Handles carry the transport in bit 0, 1 for TLS. Sockets are at least
// 8-byte aligned, so the bit is free.
const uintptr_t TLS_BIT = 1;

uintptr_t handle_of(Res<false> *res) { return (uintptr_t)res; }
uintptr_t handle_of(Res<true> *res) { return (uintptr_t)res | TLS_BIT; }
uintptr_t handle_of(Ws<false> *ws) { return (uintptr_t)ws; }
uintptr_t handle_of(Ws<true> *ws) { return (uintptr_t)ws | TLS_BIT; }

us_socket_t *socket_of(uintptr_t handle) { return (us_socket_t *)(handle & ~TLS_BIT); }

// Calls f with the response or WebSocket that `handle` names, in its own type.
template <class F> auto visit_res(uintptr_t handle, F &&f) {
    if (handle & TLS_BIT) return f((Res<true> *)(handle & ~TLS_BIT));
    return f((Res<false> *)handle);
}

template <class F> auto visit_ws(uintptr_t handle, F &&f) {
    if (handle & TLS_BIT) return f((Ws<true> *)(handle & ~TLS_BIT));
    return f((Ws<false> *)handle);
}

// A response is busy until it has answered and its buffer has drained.
template <bool SSL> bool response_busy(uintptr_t handle) {
    auto *res = (Res<SSL> *)(handle & ~TLS_BIT);
    auto *data = (uWS::HttpResponseData<SSL> *)us_socket_ext(0, (us_socket_t *)res);
    return !res->hasResponded() || data->buffer.length();
}

struct Endpoint;
struct Dispatch;
struct App {
    std::unique_ptr<uWS::App> plain;
    std::unique_ptr<uWS::SSLApp> tls;
    us_listen_socket_t *listener = nullptr;
    std::shared_ptr<Dispatch> dispatch;
    std::shared_ptr<Endpoint> endpoint;
    bool dispatch_owner = false;
    us_socket_context_t *dispatch_context = nullptr;
    std::unordered_set<uintptr_t> connections; // response handles, owned by this app's loop
    std::unordered_set<uintptr_t> websockets;
    std::unordered_set<std::string> ws_paths;

    // Runs f with this app's uWebSockets instance, plain or TLS.
    template <class F> void with(F &&f) {
        if (tls) f(*tls);
        else f(*plain);
    }
};

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

// A server WebSocket carries the runtime's id for it.
struct WsData { uint64_t id = 0; App *owner = nullptr; };

typedef void (*uws_ws_open_cb)(uint64_t id, void *ws);
typedef void (*uws_ws_message_cb)(uint64_t id, const char *data, size_t len, int binary);
typedef void (*uws_ws_close_cb)(uint64_t id, int code, const char *reason, size_t len);
typedef void (*uws_ws_drain_cb)(uint64_t id);
struct WsCallbacks {
    uws_ws_open_cb open;
    uws_ws_message_cb message;
    uws_ws_close_cb close;
    uws_ws_drain_cb drain;
} ws_callbacks;

// The WebSocket context of the upgrade request being dispatched, read by the
// request callback. Null for every other request.
thread_local void *upgrade_context = nullptr;
thread_local std::unordered_map<us_socket_context_t *, App *> tracked_contexts;

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
        target->app->with([&](auto &ua) { ua.adoptSocket(fd, accepted->ip); });
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
    app->with([app](auto &ua) {
        ua.filter([app](auto *res, int change) {
            uintptr_t handle = handle_of(res);
            if (change > 0) {
                tracked_contexts[us_socket_context(0, (us_socket_t *)res)] = app;
                app->connections.insert(handle);
            }
            else app->connections.erase(handle);
        });
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

void uws_ws_callbacks(uws_ws_open_cb open, uws_ws_message_cb message, uws_ws_close_cb close, uws_ws_drain_cb drain) {
    ws_callbacks = { open, message, close, drain };
}

// uWS tries WebSocket routes before ordinary ones, and they yield a request
// without Sec-WebSocket-Key, so each request path that may upgrade gets one.
// The upgrade runs the ordinary request callback with its context set.
static void add_ws_route(App *a, const char *path, uws_req_cb cb, void *user) {
    if (!a->ws_paths.insert(path).second) return;
    a->with([&](auto &ua) {
        ua.template ws<WsData>(path, {
            .compression = uWS::DISABLED,
            .maxPayloadLength = 16 * 1024 * 1024,
            .idleTimeout = 120,
            .maxBackpressure = 16 * 1024 * 1024,
            .closeOnBackpressureLimit = false,
            .resetIdleTimeoutOnSend = true,
            .sendPingsAutomatically = true,
            .upgrade = [cb, user](auto *res, auto *req, auto *context) {
                upgrade_context = context;
                cb(user, (uws_req *)req, (uws_res *)handle_of(res));
                upgrade_context = nullptr;
            },
            .open = [](auto *ws) {
                if (auto *owner = ws->getUserData()->owner) owner->websockets.insert(handle_of(ws));
                ws_callbacks.open(ws->getUserData()->id, (void *)handle_of(ws));
            },
            .message = [](auto *ws, std::string_view message, uWS::OpCode op) {
                ws_callbacks.message(ws->getUserData()->id, message.data(), message.size(), op == uWS::OpCode::BINARY);
            },
            .drain = [](auto *ws) { ws_callbacks.drain(ws->getUserData()->id); },
            .close = [](auto *ws, int code, std::string_view reason) {
                if (auto *owner = ws->getUserData()->owner) owner->websockets.erase(handle_of(ws));
                ws_callbacks.close(ws->getUserData()->id, code, reason.data(), reason.size());
            },
        });
    });
}

// A TLS app is created with its certificate and key; cert is null for plain HTTP.
// Null when the certificate or key does not load.
static App *new_app(uws_req_cb cb, void *user, const char *cert, const char *key) {
    App *a = new App();
    if (cert) {
        a->tls = std::make_unique<uWS::SSLApp>(uWS::SocketContextOptions{ .key_file_name = key, .cert_file_name = cert });
        if (a->tls->constructorFailed()) {
            delete a;
            return nullptr;
        }
    }
    else a->plain = std::make_unique<uWS::App>();
    a->with([&](auto &ua) {
        ua.any("/*", [cb, user](auto *res, auto *req) { cb(user, (uws_req *)req, (uws_res *)handle_of(res)); });
    });
    add_ws_route(a, "/*", cb, user);
    return a;
}

uws_app *uws_app_new(uws_req_cb cb, void *user) {
    return (uws_app *)new_app(cb, user, nullptr, nullptr);
}

uws_app *uws_app_new_tls(uws_req_cb cb, void *user, const char *cert, const char *key) {
    return (uws_app *)new_app(cb, user, cert, key);
}

void *uws_req_upgrade_context(void) { return upgrade_context; }

// Completes an upgrade, now or after an async handler. uWS answers 101 and
// calls the open callback before this returns.
void uws_res_upgrade(uws_res *res, uint64_t id, const char *key, size_t key_len, const char *protocol,
                     size_t protocol_len, const char *extensions, size_t extensions_len, void *context) {
    App *owner = nullptr;
    uintptr_t handle = (uintptr_t)res;
    auto found = tracked_contexts.find(us_socket_context(0, socket_of(handle)));
    if (found != tracked_contexts.end()) {
        owner = found->second;
        // Upgrade can realloc the socket. Retire the HTTP pointer before it
        // moves; the WebSocket open/close callbacks track its new lifetime.
        owner->connections.erase(handle);
    }
    visit_res(handle, [&](auto *r) {
        r->template upgrade<WsData>({ id, owner }, std::string_view(key, key_len), std::string_view(protocol, protocol_len),
            std::string_view(extensions, extensions_len), (us_socket_context_t *)context);
    });
}

// 0 sent, 1 buffered under backpressure, 2 dropped.
int uws_ws_send(void *ws, const char *data, size_t len, int binary) {
    return visit_ws((uintptr_t)ws, [&](auto *w) {
        return (int)w->send(std::string_view(data, len), binary ? uWS::OpCode::BINARY : uWS::OpCode::TEXT);
    });
}

void uws_ws_end(void *ws, int code, const char *reason, size_t len) {
    visit_ws((uintptr_t)ws, [&](auto *w) { w->end(code, std::string_view(reason, len)); });
}

void uws_ws_terminate(void *ws) { visit_ws((uintptr_t)ws, [](auto *w) { w->close(); }); }

size_t uws_ws_buffered(void *ws) { return visit_ws((uintptr_t)ws, [](auto *w) { return w->getBufferedAmount(); }); }

void uws_app_route(uws_app *app, const char *method, const char *path, uws_req_cb cb, void *user) {
    App *a = (App *)app;
    auto handler = [cb, user](auto *res, auto *req) { cb(user, (uws_req *)req, (uws_res *)handle_of(res)); };
    std::string m(method);
    a->with([&](auto &ua) {
        if (m == "GET") ua.get(path, handler);
        else if (m == "HEAD") ua.head(path, handler);
        else if (m == "POST") ua.post(path, handler);
        else if (m == "PUT") ua.put(path, handler);
        else if (m == "PATCH") ua.patch(path, handler);
        else if (m == "DELETE") ua.del(path, handler);
        else if (m == "OPTIONS") ua.options(path, handler);
        else if (m == "TRACE") ua.trace(path, handler);
        else if (m == "CONNECT") ua.connect(path, handler);
        else ua.any(path, handler);
    });
    if (m == "GET" || m == "*") add_ws_route(a, path, cb, user);
}

size_t uws_req_parameter(uws_req *req, unsigned short index, const char **out) {
    std::string_view value = ((Req *)req)->getParameter(index);
    *out = value.data();
    return value.size();
}

// The bound port, or -1.
int uws_app_listen(uws_app *app, const char *host, int port) {
    App *a = (App *)app;
    // Process workers adopt plain sockets only, so a TLS app listens itself.
    if (!a->tls) {
        int process_port = bkr_process_listen(a, host, port, uWS::Loop::get(),
            [](void *app, int fd, const char *ip, int length) {
                ((App *)app)->with([&](auto &ua) { ua.adoptSocket(fd, std::string_view(ip, length)); });
            });
        if (process_port != -2) {
            if (process_port >= 0) track_connections(a);
            return process_port;
        }
    }
    a->with([a, host, port](auto &ua) {
        ua.listen(std::string(host), port, [a](auto *token) { a->listener = token; });
    });
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
    a->with([](auto &ua) { ua.preOpen(dispatch_connection); });
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
    if (!a->websockets.empty()) return 0;
    for (auto handle : a->connections) {
        bool busy = (handle & TLS_BIT) ? response_busy<true>(handle) : response_busy<false>(handle);
        if (busy) return 0;
    }
    return 1;
}

void uws_app_stop(uws_app *app, int force) {
    App *a = (App *)app;
    bkr_process_stop(a);
    detach_dispatch(a);
    if (a->listener) us_listen_socket_close(0, a->listener);
    a->listener = nullptr;
    if (force) a->with([](auto &ua) { ua.close(); });
}

void uws_app_free(uws_app *app) {
    auto *a = (App *)app;
    bkr_process_stop(a);
    detach_dispatch(a);
    if (a->dispatch_owner) {
        std::lock_guard<std::mutex> guard(dispatch_registry_lock);
        dispatch_registry.erase(a->dispatch_context);
    }
    for (auto it = tracked_contexts.begin(); it != tracked_contexts.end();) {
        if (it->second == a) it = tracked_contexts.erase(it);
        else ++it;
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
    std::string_view v = visit_res((uintptr_t)res, [](auto *r) { return r->getRemoteAddressAsText(); });
    *out = v.data();
    return v.size();
}

void uws_res_on_data(uws_res *res, uws_data_cb cb, void *user) {
    visit_res((uintptr_t)res, [&](auto *r) {
        r->onData([cb, user](std::string_view chunk, bool last) {
            cb(user, chunk.data(), chunk.size(), last ? 1 : 0);
        });
    });
}

void uws_res_on_aborted(uws_res *res, void (*cb)(void *), void *user) {
    visit_res((uintptr_t)res, [&](auto *r) { r->onAborted([cb, user]() { cb(user); }); });
}

void uws_res_on_writable(uws_res *res, uws_writable_cb cb, void *user) {
    visit_res((uintptr_t)res, [&](auto *r) {
        r->onWritable([cb, user](uintmax_t off) { return cb(user, off) != 0; });
    });
}

void uws_res_write_status(uws_res *res, const char *status, size_t len) {
    visit_res((uintptr_t)res, [&](auto *r) { r->writeStatus(std::string_view(status, len)); });
}

void uws_res_write_header(uws_res *res, const char *key, size_t key_len,
                          const char *val, size_t val_len) {
    visit_res((uintptr_t)res, [&](auto *r) {
        r->writeHeader(std::string_view(key, key_len), std::string_view(val, val_len));
    });
}

// Chunked write; 0 when the socket buffer is full and the caller should
// wait for on_writable.
int uws_res_write(uws_res *res, const char *data, size_t len) {
    return visit_res((uintptr_t)res, [&](auto *r) { return r->write(std::string_view(data, len)) ? 1 : 0; });
}

void uws_res_end(uws_res *res, const char *body, size_t len) {
    visit_res((uintptr_t)res, [&](auto *r) { r->end(std::string_view(body, len)); });
}

void uws_res_end_empty(uws_res *res) {
    visit_res((uintptr_t)res, [](auto *r) { r->endWithoutBody(std::nullopt); });
}

void uws_res_end_static(uws_res *res, const char *status, size_t status_len,
                        const char *headers, size_t headers_len,
                        const char *body, size_t body_len, bool empty) {
    visit_res((uintptr_t)res, [&](auto *r) {
        if (status_len) r->writeStatus(std::string_view(status, status_len));
        if (headers_len) r->writeHeaders(std::string_view(headers, headers_len));
        if (empty) r->endWithoutBody(std::nullopt);
        else r->end(std::string_view(body, body_len));
    });
}

void uws_res_cork(uws_res *res, void (*cb)(void *), void *user) {
    visit_res((uintptr_t)res, [&](auto *r) { r->cork([cb, user]() { cb(user); }); });
}

void uws_res_close(uws_res *res) { visit_res((uintptr_t)res, [](auto *r) { r->close(); }); }

}
