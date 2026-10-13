// extern "C" pass-throughs over the parts of uWebSockets C3 cannot reach:
// the templated App, HttpRequest and HttpResponse. Loops, timers, polls and
// raw sockets are plain uSockets and are bound from C3 directly.
#include "App.h"

#include <cstddef>

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

struct App {
    uWS::App app;
    us_listen_socket_t *listener = nullptr;
};

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

// The bound port, or -1.
int uws_app_listen(uws_app *app, const char *host, int port) {
    App *a = (App *)app;
    a->app.listen(std::string(host), port, [a](auto *token) { a->listener = token; });
    if (!a->listener) return -1;
    return us_socket_local_port(0, (us_socket_t *)a->listener);
}

void uws_app_stop(uws_app *app, int force) {
    App *a = (App *)app;
    if (a->listener) us_listen_socket_close(0, a->listener);
    a->listener = nullptr;
    if (force) a->app.close();
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
