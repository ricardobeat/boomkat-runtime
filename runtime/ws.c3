// Server WebSockets on uWebSockets. A handler accepts an upgrade with
// upgradeWebSocket(); uWS owns framing, pings and close handshakes, and the
// events reach JS through bk.wsEvent under an id JS chose.
module bkr;

import boomkat;
import std::collections::map;
import std::encoding::base64;
import std::hash::sha1;

typedef UwsWs = void;

alias UwsWsOpenCb = fn void(ulong id, UwsWs* ws);
alias UwsWsMessageCb = fn void(ulong id, char* data, sz len, CInt binary);
alias UwsWsCloseCb = fn void(ulong id, CInt code, char* reason, sz len);
alias UwsWsDrainCb = fn void(ulong id);

extern fn void uws_ws_callbacks(UwsWsOpenCb open, UwsWsMessageCb message, UwsWsCloseCb close, UwsWsDrainCb drain);
extern fn void* uws_req_upgrade_context();
extern fn void uws_res_upgrade(UwsRes* res, ulong id, char* key, sz key_len, char* protocol, sz protocol_len,
                               char* extensions, sz extensions_len, void* context);
extern fn CInt uws_ws_send(UwsWs* ws, char* data, sz len, CInt binary);
extern fn void uws_ws_end(UwsWs* ws, CInt code, char* reason, sz len);
extern fn void uws_ws_terminate(UwsWs* ws);
extern fn sz uws_ws_buffered(UwsWs* ws);

enum WsEvent : char {
    OPEN,
    TEXT,
    BINARY,
    CLOSE,
    DRAIN,
}

tlocal HashMap{ulong, UwsWs*} g_ws;
tlocal JsValue g_ws_event;

fn void? init_ws() {
    g_ws.init(mem);
    g_ws_event = bk_get("wsEvent")!;
    uws_ws_callbacks(&ws_on_open, &ws_on_message, &ws_on_close, &ws_on_drain);
}

fn void ws_emit(ulong id, WsEvent kind, JsValue a = { }, JsValue b = { }) {
    JsValue[4] args = { g_runtime.rt.number((double)id) ?? { }, g_runtime.rt.number(kind.ordinal) ?? { }, a, b };
    (void)call_js(g_ws_event, args[..]);
}

fn void ws_on_open(ulong id, UwsWs* ws) {
    g_ws.set(id, ws);
    g_runtime.rt.@scope() {
        ws_emit(id, OPEN);
    };
}

fn void ws_on_message(ulong id, char* data, sz len, CInt binary) {
    g_runtime.rt.@scope() {
        if (binary) {
            ws_emit(id, BINARY, bytes_value(copy_bytes(data[:len])) ?? { });
        } else {
            ws_emit(id, TEXT, g_runtime.rt.string((String)data[:len]) ?? { });
        }
    };
}

fn void ws_on_close(ulong id, CInt code, char* reason, sz len) {
    g_ws.remove(id);
    g_runtime.rt.@scope() {
        ws_emit(id, CLOSE, g_runtime.rt.number(code) ?? { }, g_runtime.rt.string((String)reason[:len]) ?? { });
    };
}

fn void ws_on_drain(ulong id) {
    g_runtime.rt.@scope() {
        ws_emit(id, DRAIN);
    };
}

// The upgrade headers a later uws_res_upgrade needs, copied while the request
// is still readable.
fn void Conn.capture_upgrade(&self, UwsHeader[] hdrs, void* context) {
    self.ws_ctx = context;
    foreach (h : hdrs) {
        String key = (String)h.key[:h.key_len];
        String val = (String)h.val[:h.val_len];
        switch (key) {
            case "sec-websocket-key": self.ws_key = val.copy(mem);
            case "sec-websocket-extensions": self.ws_ext = val.copy(mem);
        }
    }
}

fn void Conn.free_upgrade(&self) {
    if (self.ws_key.len) free(self.ws_key.ptr);
    if (self.ws_ext.len) free(self.ws_ext.ptr);
}

struct Upgrade {
    Conn* c;
    ulong id;
    String protocol;
}

fn void write_upgrade(void* user) {
    Upgrade* u = user;
    Conn* c    = u.c;
    uws_res_upgrade(c.res, u.id, c.ws_key.ptr, c.ws_key.len, u.protocol.ptr, u.protocol.len,
                    c.ws_ext.ptr, c.ws_ext.len, c.ws_ctx);
}

// wsUpgrade(connId, wsId, protocol) -> false when the request cannot upgrade
fn void js_ws_upgrade(JsCtx ctx, void* udata) {
    Conn* c = ctx.conn();
    if (!c || !c.ws_ctx || c.aborted || c.streaming) {
        ctx.ret_bool(false);
        return;
    }
    @pool() {
        Upgrade u = { c, (ulong)(ctx.arg(1).as_number() ?? 0), (String)ctx.arg(2).bytes() };
        // The HTTP response becomes the WebSocket; the Conn ends here.
        corked(c, &write_upgrade, &u);
    };
    done(c);
    ctx.ret_bool(true);
}

fn UwsWs* JsCtx.ws(self) => g_ws.get((ulong)(self.arg(0).as_number() ?? 0)) ?? null;

// wsSend(wsId, data, binary) -> 0 sent, 1 buffered, 2 dropped, -1 closed
fn void js_ws_send(JsCtx ctx, void* udata) {
    UwsWs* ws = ctx.ws();
    if (!ws) {
        ctx.ret_number(-1);
        return;
    }
    char[] data = ctx.arg(1).bytes();
    ctx.ret_number(uws_ws_send(ws, data.ptr, data.len, (ctx.arg(2).as_bool() ?? false) ? 1 : 0));
}

// wsClose(wsId, code, reason): a close handshake, or an immediate
// termination when code is 0
fn void js_ws_close(JsCtx ctx, void* udata) {
    UwsWs* ws = ctx.ws();
    if (!ws) return;
    int code = ctx.arg(1).as_int(1000);
    if (code == 0) {
        uws_ws_terminate(ws);
        return;
    }
    char[] reason = ctx.arg(2).bytes();
    uws_ws_end(ws, code, reason.ptr, reason.len);
}

fn void js_ws_buffered(JsCtx ctx, void* udata) {
    UwsWs* ws = ctx.ws();
    ctx.ret_number(ws ? (double)uws_ws_buffered(ws) : 0);
}

// wsAccept(key) -> the Sec-WebSocket-Accept a server answers `key` with
fn void js_ws_accept(JsCtx ctx, void* udata) {
    @pool() {
        String key = (String)ctx.arg(0).bytes();
        char[20] digest = sha1::hash(string::tformat("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key));
        ctx.ret_string(base64::tencode(&digest));
    };
}

const Native[] WS_NATIVES = {
    { "wsAccept", &js_ws_accept, 1 },
    { "wsUpgrade", &js_ws_upgrade, 3 },
    { "wsSend", &js_ws_send, 3 },
    { "wsClose", &js_ws_close, 3 },
    { "wsBuffered", &js_ws_buffered, 1 },
};
