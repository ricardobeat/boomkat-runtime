// TCP and TLS sockets on uSockets, DNS on the pool.
module bkr;

import boomkat;
import std::io;
import std::collections::list;
import libc;

typedef UsSocket = void;
alias SockCb = fn UsSocket*(UsSocket*);
alias OpenCb = fn UsSocket*(UsSocket*, CInt, char*, CInt);
alias CloseCb = fn UsSocket*(UsSocket*, CInt, void*);
alias DataCb = fn UsSocket*(UsSocket*, char*, CInt);
alias ErrCb = fn UsSocket*(UsSocket*, CInt);
typedef UsListenSocket = void;
typedef UsContext = void;

struct UsContextOptions
{
    ZString key_file_name;
    ZString cert_file_name;
    ZString passphrase;
    ZString dh_params_file_name;
    ZString ca_file_name;
    ZString ssl_ciphers;
    CInt ssl_prefer_low_memory_usage;
}

extern fn UsContext* us_create_socket_context(CInt ssl, void* loop, CInt ext_size, UsContextOptions options);
extern fn void* us_socket_context_ext(CInt ssl, UsContext* ctx);
extern fn void* us_socket_context_get_native_handle(CInt ssl, UsContext* ctx);
extern fn void us_socket_context_on_open(CInt ssl, UsContext* ctx, OpenCb cb);
extern fn void us_socket_context_on_close(CInt ssl, UsContext* ctx, CloseCb cb);
extern fn void us_socket_context_on_data(CInt ssl, UsContext* ctx, DataCb cb);
extern fn void us_socket_context_on_writable(CInt ssl, UsContext* ctx, SockCb cb);
extern fn void us_socket_context_on_timeout(CInt ssl, UsContext* ctx, SockCb cb);
extern fn void us_socket_context_on_end(CInt ssl, UsContext* ctx, SockCb cb);
extern fn void us_socket_context_on_connect_error(CInt ssl, UsContext* ctx, ErrCb cb);
extern fn UsListenSocket* us_socket_context_listen(CInt ssl, UsContext* ctx, ZString host, CInt port, CInt options, CInt ext_size);
extern fn UsSocket* us_socket_context_connect(CInt ssl, UsContext* ctx, ZString host, CInt port, ZString source, CInt options, CInt ext_size);
extern fn void us_listen_socket_close(CInt ssl, UsListenSocket* ls);
extern fn CInt us_socket_write(CInt ssl, UsSocket* s, char* data, CInt len, CInt more);
extern fn void* us_socket_ext(CInt ssl, UsSocket* s);
extern fn UsContext* us_socket_context(CInt ssl, UsSocket* s);
extern fn void us_socket_shutdown(CInt ssl, UsSocket* s);
extern fn CInt us_socket_is_shut_down(CInt ssl, UsSocket* s);
extern fn UsSocket* us_socket_close(CInt ssl, UsSocket* s, CInt code, void* reason);
extern fn CInt us_socket_local_port(CInt ssl, UsSocket* s);
extern fn CInt us_socket_remote_port(CInt ssl, UsSocket* s);
extern fn void us_socket_remote_address(CInt ssl, UsSocket* s, char* buf, CInt* len);
extern fn void* us_socket_get_native_handle(CInt ssl, UsSocket* s);
extern fn void us_poll_change(void* p, void* loop, CInt events);
extern fn CInt us_poll_events(void* p);

const CInt POLL_READABLE = 1;
const CInt POLL_WRITABLE = 2;

UsContext*[2] g_client_ctx;

// ---- socket callbacks, shared by client and accepted sockets ----

fn Res* sock_res(CInt ssl, UsSocket* s) => *(Res**)us_socket_ext(ssl, s);

macro @callbacks($ssl, UsContext* ctx)
{
    us_socket_context_on_open($ssl, ctx, fn (s, is_client, ip, ip_len) => on_sock_open($ssl, s, is_client));
    us_socket_context_on_data($ssl, ctx, fn (s, data, len) => on_sock_data($ssl, s, data[:len]));
    us_socket_context_on_writable($ssl, ctx, fn (s) => on_sock_writable($ssl, s));
    us_socket_context_on_close($ssl, ctx, fn (s, code, reason) => on_sock_close($ssl, s, code));
    us_socket_context_on_end($ssl, ctx, fn (s) => on_sock_end($ssl, s));
    us_socket_context_on_connect_error($ssl, ctx, fn (s, code) => on_sock_connect_error($ssl, s, code));
    us_socket_context_on_timeout($ssl, ctx, fn (s) => s);
}

fn UsSocket* on_sock_open(CInt ssl, UsSocket* s, CInt is_client)
{
    if (is_client)
    {
        Res* r = sock_res(ssl, s);
        r.sock = s;
        if (ssl) tls_client_setup(r);
        uint op = r.connect_op;
        r.connect_op = 0;
        if (op) resolve_number(op, r.rid);
        return s;
    }
    Res* l = *(Res**)us_socket_context_ext(ssl, us_socket_context(ssl, s));
    Res* r = res_new(SOCKET);
    r.sock = s;
    r.ssl = ssl;
    *(Res**)us_socket_ext(ssl, s) = r;
    if (l.accept_op)
    {
        uint op = l.accept_op;
        l.accept_op = 0;
        resolve_number(op, r.rid);
    }
    else
    {
        l.backlog.push(r.rid);
    }
    return s;
}

fn UsSocket* on_sock_data(CInt ssl, UsSocket* s, char[] data)
{
    Res* r = sock_res(ssl, s);
    r.inbox.push_all(data);
    if (r.read_op)
    {
        r.deliver();
    }
    else if (r.inbox.len() > (sz)INBOX_HIGH)
    {
        r.pause();
    }
    return s;
}

fn UsSocket* on_sock_writable(CInt ssl, UsSocket* s)
{
    sock_res(ssl, s).flush();
    return s;
}

fn UsSocket* on_sock_end(CInt ssl, UsSocket* s)
{
    Res* r = sock_res(ssl, s);
    r.eof = true;
    r.deliver();
    // Both halves done: nothing more can happen on it.
    if (us_socket_is_shut_down(ssl, s)) return us_socket_close(ssl, s, 0, null);
    return s;
}

fn UsSocket* on_sock_close(CInt ssl, UsSocket* s, CInt code)
{
    Res* r = sock_res(ssl, s);
    r.gone = true;
    r.sock = null;
    if (r.connect_op)
    {
        uint op = r.connect_op;
        r.connect_op = 0;
        if (r.cert_failed)
        {
            reject(op, "CERT_INVALID", string::tformat("TLS certificate for %s failed verification", r.host));
        }
        else
        {
            reject(op, "ECONNRESET", "connection closed during the handshake");
        }
        r.closed = true;
    }
    if (code && !r.eof) r.error = Errno.ECONNRESET;
    if (r.write_op)
    {
        uint op = r.write_op;
        r.write_op = 0;
        if (r.cert_failed)
        {
            reject(op, "CERT_INVALID", string::tformat("TLS certificate for %s failed verification", r.host));
        }
        else
        {
            reject(op, "EPIPE", "connection closed");
        }
    }
    r.deliver();
    res_release(r);
    return s;
}

fn UsSocket* on_sock_connect_error(CInt ssl, UsSocket* s, CInt code)
{
    Res* r = sock_res(ssl, s);
    r.gone = true;
    r.closed = true;
    uint op = r.connect_op;
    r.connect_op = 0;
    if (op) reject(op, "ECONNREFUSED", string::tformat("connection to %s refused", r.host));
    res_release(r);
    return s;
}

fn void Res.pause(&self)
{
    if (self.paused || !self.sock) return;
    self.paused = true;
    us_poll_change(self.sock, g_loop, us_poll_events(self.sock) & ~POLL_READABLE);
}

fn void Res.resume(&self)
{
    if (!self.paused || !self.sock) return;
    self.paused = false;
    us_poll_change(self.sock, g_loop, us_poll_events(self.sock) | POLL_READABLE);
}

// ---- writing ----

fn void Res.socket_write(&self, uint op, char[] data)
{
    if (self.gone)
    {
        reject(op, "EPIPE", "connection closed");
        return;
    }
    if (self.write_op)
    {
        reject(op, "EBUSY", "a write is already pending");
        return;
    }
    if (!self.outbox.len())
    {
        CInt n = us_socket_write(self.ssl, self.sock, data.ptr, (CInt)data.len, 0);
        if (n == data.len)
        {
            resolve_number(op, n);
            return;
        }
        data = data[n..];
    }
    self.outbox.push_all(data);
    self.write_op = op;
    self.write_len = data.len;
}

fn void Res.flush(&self)
{
    if (!self.outbox.len() || !self.sock) return;
    char[] pending = self.outbox.array_view();
    CInt n = us_socket_write(self.ssl, self.sock, pending.ptr, (CInt)pending.len, 0);
    if (n <= 0) return;
    sz rest = (sz)self.outbox.len() - n;
    mem::move(self.outbox.entries, self.outbox.entries + n, rest);
    self.outbox.size = rest;
    if (self.outbox.len() || !self.write_op) return;
    uint op = self.write_op;
    self.write_op = 0;
    resolve_number(op, self.write_len);
}

// ---- DNS ----

struct DnsTask
{
    inline Task task;
    uint op;
    String host;
    int port;
    CInt ssl;
    bool connect;
    List{String} addrs;
    CInt err;
}

struct AddrInfo
{
    CInt ai_flags;
    CInt ai_family;
    CInt ai_socktype;
    CInt ai_protocol;
    uint ai_addrlen;
    ZString ai_canonname;
    SockAddrIn* ai_addr;
    AddrInfo* ai_next;
}

struct SockAddrIn
{
    char sin_len;
    char sin_family;
    ushort sin_port;
    char[24] data;
}

extern fn CInt getaddrinfo(ZString node, ZString service, AddrInfo* hints, AddrInfo** res);
extern fn void freeaddrinfo(AddrInfo* ai);
extern fn ZString inet_ntop(CInt af, void* src, char* dst, uint size);
extern fn ZString gai_strerror(CInt err);

const CInt AF_INET = 2;
const CInt AF_INET6 = 30;
const CInt SOCK_STREAM = 1;

fn void dns_work(Task* t)
{
    DnsTask* d = (DnsTask*)t;
    d.addrs.init(mem);
    AddrInfo hints = { .ai_socktype = SOCK_STREAM };
    AddrInfo* res;
    d.err = getaddrinfo(d.host.zstr_copy(mem), null, &hints, &res);
    if (d.err) return;
    defer freeaddrinfo(res);
    for (AddrInfo* a = res; a; a = a.ai_next)
    {
        char[64] buf;
        void* src = a.ai_family == AF_INET ? (void*)&a.ai_addr.data[0] : (void*)&a.ai_addr.data[4];
        if (a.ai_family != AF_INET && a.ai_family != AF_INET6) continue;
        if (!inet_ntop(a.ai_family, src, &buf, 64)) continue;
        String ip = ((ZString)&buf).str_view().copy(mem);
        bool dup;
        foreach (x : d.addrs) dup |= x == ip;
        if (!dup) d.addrs.push(ip);
    }
}

fn void dns_done(Task* t)
{
    DnsTask* d = (DnsTask*)t;
    defer
    {
        foreach (a : d.addrs) free(a.ptr);
        d.addrs.free();
        free(d.host.ptr);
        free(d);
    }
    @pool()
    {
        if (d.err)
        {
            reject(d.op, "ENOTFOUND", string::tformat("cannot resolve %s: %s", d.host, gai_strerror(d.err)));
            return;
        }
        if (!d.connect)
        {
            g_rt.@scope()
            {
                JsValue list = g_rt.array() ?? {};
                foreach (i, a : d.addrs) (void)g_rt.set_index(list, (uint)i, g_rt.string(a) ?? {});
                resolve(d.op, list);
            };
            return;
        }
        // A grant by name covers what it resolves to, except internal
        // addresses, which need their own grant (see check_net_addr).
        foreach (ip : d.addrs)
        {
            if (!check_net_addr(d.host, ip, d.port))
            {
                reject(d.op, "PERMISSION_DENIED", string::tformat("net access to %s (%s) denied", describe(d.host, d.port), ip));
                return;
            }
        }
        if (!d.addrs.len())
        {
            reject(d.op, "ENOTFOUND", string::tformat("no addresses for %s", d.host));
            return;
        }
        start_connect(d.op, d.host, d.addrs[0], d.port, d.ssl);
    };
}

fn void start_connect(uint op, String host, String ip, int port, CInt ssl)
{
    if (!g_client_ctx[ssl])
    {
        UsContextOptions opts;
        UsContext* ctx = us_create_socket_context(ssl, g_loop, 0, opts);
        if (ssl) tls_client_init(ctx);
        if (ssl)
        {
            @callbacks(1, ctx);
        }
        else
        {
            @callbacks(0, ctx);
        }
        g_client_ctx[ssl] = ctx;
    }
    Res* r = res_new(SOCKET);
    r.ssl = ssl;
    r.host = host.copy(mem);
    r.connect_op = op;
    UsSocket* s = us_socket_context_connect(ssl, g_client_ctx[ssl], ip.zstr_tcopy(), port, null, 0, (CInt)8);
    if (!s)
    {
        r.closed = r.gone = true;
        res_release(r);
        reject(op, "ECONNREFUSED", string::tformat("cannot connect to %s", describe(host, port)));
        return;
    }
    *(Res**)us_socket_ext(ssl, s) = r;
    r.sock = s;
}

fn void dns_start(uint op, String host, int port, CInt ssl, bool connect)
{
    DnsTask* d = mem::new(DnsTask);
    *d = { .task = { .work = &dns_work, .done = &dns_done }, .op = op, .host = host.copy(mem), .port = port, .ssl = ssl, .connect = connect };
    submit(d);
}

// ---- natives ----

fn String denied_msg(String host, int port) => string::tformat("net access to \"%s\" denied; run with --allow-net", describe(host, port));

// connect(op, host, port, tls) -> rid
fn void js_connect(JsCtx ctx, void* udata)
{
    uint op = ctx.arg(0).id();
    @pool()
    {
        String host = ctx.arg(1).as_string() ?? "";
        int port = ctx.arg(2).as_int(-1);
        CInt ssl = ctx.arg(3).as_bool() ?? false ? 1 : 0;
        if (port < 0 || port > 65535)
        {
            reject(op, "EINVAL", "invalid port");
            return;
        }
        if (!check_net(host, port))
        {
            reject(op, "PERMISSION_DENIED", denied_msg(host, port));
            return;
        }
        dns_start(op, host, port, ssl, true);
    };
}

// resolve(op, host) -> [address]
fn void js_resolve(JsCtx ctx, void* udata)
{
    uint op = ctx.arg(0).id();
    @pool()
    {
        String host = ctx.arg(1).as_string() ?? "";
        if (!check_net(host, -1))
        {
            reject(op, "PERMISSION_DENIED", denied_msg(host, -1));
            return;
        }
        dns_start(op, host, -1, 0, false);
    };
}

// listen(host, port) -> rid
fn void js_listen(JsCtx ctx, void* udata)
{
    @pool()
    {
        String host = ctx.arg(0).as_string() ?? "0.0.0.0";
        int port = ctx.arg(1).as_int(0);
        if (!check_net(host, port))
        {
            ctx.throw_coded("PERMISSION_DENIED", denied_msg(host, port));
            return;
        }
        UsContextOptions opts;
        UsContext* uc = us_create_socket_context(0, g_loop, (CInt)8, opts);
        @callbacks(0, uc);
        Res* l = res_new(LISTENER);
        l.ctx = uc;
        *(Res**)us_socket_context_ext(0, uc) = l;
        l.listener = us_socket_context_listen(0, uc, host.zstr_tcopy(), port, 0, (CInt)8);
        if (!l.listener)
        {
            l.closed = l.gone = true;
            res_release(l);
            ctx.throw_coded("EADDRINUSE", string::tformat("could not listen on %s", describe(host, port)));
            return;
        }
        ctx.ret_number(l.rid);
    };
}

// accept(op, lid) -> rid, or null once the listener is closed
fn void js_accept(JsCtx ctx, void* udata)
{
    uint op = ctx.arg(0).id();
    Res* l = res_find(ctx.arg(1).id());
    if (!l || l.kind != LISTENER || l.closed)
    {
        reject(op, "EBADF", "bad listener id");
        return;
    }
    if (l.backlog.len())
    {
        resolve_number(op, l.backlog.pop_first()!!);
        return;
    }
    l.accept_op = op;
}

fn void js_close_write(JsCtx ctx, void* udata)
{
    Res* r = ctx.res();
    if (!r || r.kind != SOCKET || r.gone) return;
    us_socket_shutdown(r.ssl, r.sock);
}

// addr(rid) -> [localPort, remoteAddress, remotePort]
fn void js_addr(JsCtx ctx, void* udata)
{
    Res* r = ctx.res();
    if (!r) return;
    @pool()
    {
        if (r.kind == LISTENER)
        {
            ctx.ret_string(string::tformat("%d", us_socket_local_port(0, (UsSocket*)r.listener)));
            return;
        }
        if (!r.sock) return;
        char[64] raw;
        CInt len = 64;
        us_socket_remote_address(r.ssl, r.sock, &raw, &len);
        char[64] text;
        CInt af = len == 4 ? AF_INET : AF_INET6;
        String ip = inet_ntop(af, &raw, &text, 64) ? ((ZString)&text).str_view() : "";
        ctx.ret_string(string::tformat("%d %s %d", us_socket_local_port(r.ssl, r.sock), ip, us_socket_remote_port(r.ssl, r.sock)));
    };
}

const Native[] NET_NATIVES = {
    { "connect", &js_connect, 4 },
    { "resolve", &js_resolve, 2 },
    { "listen", &js_listen, 2 },
    { "accept", &js_accept, 2 },
    { "closeWrite", &js_close_write, 1 },
    { "addr", &js_addr, 1 },
};
