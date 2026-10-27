// WebSocket: one class for both ends. A server socket comes from
// upgradeWebSocket() and rides uWS through the ws natives; a client socket
// frames the protocol here over a net connection.
(function (bk) {
const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });
const CONNECTING = 0, OPEN = 1, CLOSING = 2, CLOSED = 3;
const INTERNAL = Symbol("internal");

class CloseEvent extends Event {
    constructor(type, init = {}) {
        super(type, init);
        this.code = init.code ?? 0;
        this.reason = init.reason ?? "";
        this.wasClean = !!init.wasClean;
    }
}

function validCloseCode(code) {
    return code === 1000 || (code >= 3000 && code <= 4999);
}

class WebSocket extends EventTarget {
    #transport = null;
    #state = CONNECTING;
    #url;
    #protocol = "";
    #binaryType = "blob";
    #queue = null; // pending Blob conversions keep send order

    constructor(url, protocols = []) {
        super();
        this.onopen = this.onmessage = this.onerror = this.onclose = null;
        if (url === INTERNAL) {
            this.#url = protocols.url;
            this.#protocol = protocols.protocol;
            this.#transport = protocols.transport;
            return;
        }
        const u = new URL(String(url));
        if (u.protocol === "http:") u.protocol = "ws:";
        else if (u.protocol === "https:") u.protocol = "wss:";
        if (u.protocol !== "ws:" && u.protocol !== "wss:") throw new DOMException(`unsupported protocol ${u.protocol}`, "SyntaxError");
        if (u.hash) throw new DOMException("WebSocket URLs cannot have a fragment", "SyntaxError");
        if (typeof protocols === "string") protocols = [protocols];
        protocols = [...protocols].map(String);
        if (new Set(protocols).size !== protocols.length) throw new DOMException("duplicate subprotocol", "SyntaxError");
        this.#url = u.href;
        connectClient(this, u, protocols).then(
            ({ transport, protocol }) => {
                this.#transport = transport;
                this.#protocol = protocol;
                // close() while connecting fails the connection.
                if (this.#state === CLOSING) { transport.finish(1006, ""); return; }
                this._opened();
                transport.start();
            },
            () => this._closed(1006, "", true),
        );
    }

    get url() { return this.#url; }
    get readyState() { return this.#state; }
    get protocol() { return this.#protocol; }
    get extensions() { return ""; }
    get bufferedAmount() { return this.#transport ? this.#transport.buffered() : 0; }
    get binaryType() { return this.#binaryType; }
    set binaryType(v) { if (v === "blob" || v === "arraybuffer") this.#binaryType = v; }

    send(data) {
        if (this.#state === CONNECTING) throw new DOMException("WebSocket is still connecting", "InvalidStateError");
        if (this.#state !== OPEN) return;
        if (data instanceof Blob || this.#queue) {
            const bytes = data instanceof Blob ? data.arrayBuffer() : data;
            this.#queue = Promise.all([this.#queue, bytes]).then(([, b]) => {
                if (this.#state === OPEN) this.#write(b);
            });
            const queued = this.#queue;
            queued.then(() => { if (this.#queue === queued) this.#queue = null; });
            return;
        }
        this.#write(data);
    }

    #write(data) {
        if (typeof data === "string") { this.#transport.send(data, false); return; }
        if (data instanceof ArrayBuffer) data = new Uint8Array(data);
        else if (ArrayBuffer.isView(data)) data = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        else { this.#transport.send(String(data), false); return; }
        this.#transport.send(data, true);
    }

    close(code, reason = "") {
        if (code !== undefined && !validCloseCode(code)) throw new DOMException(`invalid close code ${code}`, "InvalidAccessError");
        reason = String(reason);
        if (enc.encode(reason).length > 123) throw new DOMException("close reason is too long", "SyntaxError");
        if (this.#state === CLOSING || this.#state === CLOSED) return;
        const connecting = this.#state === CONNECTING;
        this.#state = CLOSING;
        if (!connecting) this.#transport.close(code ?? 1000, reason);
    }

    _opened() {
        if (this.#state !== CONNECTING) return;
        this.#state = OPEN;
        this.dispatchEvent(new Event("open"));
    }

    _message(data, binary) {
        if (this.#state !== OPEN && this.#state !== CLOSING) return;
        if (binary) data = this.#binaryType === "blob" ? new Blob([data]) : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
        this.dispatchEvent(new MessageEvent("message", { data, origin: new URL(this.#url).origin }));
    }

    _closed(code, reason, error) {
        if (this.#state === CLOSED) return;
        this.#state = CLOSED;
        if (error) this.dispatchEvent(new Event("error"));
        this.dispatchEvent(new CloseEvent("close", { code, reason, wasClean: !error && code !== 1006 }));
    }
}
for (const [name, value] of Object.entries({ CONNECTING, OPEN, CLOSING, CLOSED })) {
    Object.defineProperty(WebSocket, name, { value, enumerable: true });
    Object.defineProperty(WebSocket.prototype, name, { value, enumerable: true });
}

// ---- server sockets ----

const servers = new Map();
let nextId = 0;

bk.wsEvent = function (id, kind, a, b) {
    const ws = servers.get(id);
    if (!ws) return;
    switch (kind) {
        case 0: ws._opened(); break;
        case 1: ws._message(a, false); break;
        case 2: ws._message(a, true); break;
        case 3: servers.delete(id); ws._closed(a, b, a === 1006); break;
    }
};

// The { socket, response } pair upgradeWebSocket() returns. The upgrade
// happens when the handler's Response reaches the server.
bk.wsServer = function (req, options = {}) {
    if (!(req instanceof Request) || typeof req._id !== "number") throw new TypeError("upgradeWebSocket needs the server's Request");
    if ((req.headers.get("upgrade") || "").toLowerCase() !== "websocket") throw new TypeError("request is not a WebSocket upgrade");
    const offered = (req.headers.get("sec-websocket-protocol") || "").split(",").map(p => p.trim()).filter(Boolean);
    const protocol = options.protocol === undefined ? "" : String(options.protocol);
    if (protocol && !offered.includes(protocol)) throw new TypeError(`client did not offer subprotocol ${protocol}`);
    const id = ++nextId;
    const socket = new WebSocket(INTERNAL, {
        url: req.url.replace(/^http/, "ws"),
        protocol,
        transport: {
            send: (data, binary) => { bk.wsSend(id, data, binary); },
            close: (code, reason) => bk.wsClose(id, code, reason),
            buffered: () => bk.wsBuffered(id),
        },
    });
    const response = new Response(null);
    response.status = 101;
    response._ws = { id, socket, protocol };
    return { socket, response };
};

// Called by the response path with a Response from wsServer.
bk.wsRespond = function (connId, res) {
    const { id, socket, protocol } = res._ws;
    res._used = true;
    servers.set(id, socket);
    if (!bk.wsUpgrade(connId, id, protocol)) {
        servers.delete(id);
        socket._closed(1006, "", true);
        return false;
    }
    return true;
};

// ---- client sockets ----

const CRLFCRLF = enc.encode("\r\n\r\n");

function find(buf, needle) {
    outer: for (let i = 0; i <= buf.length - needle.length; i++) {
        for (let j = 0; j < needle.length; j++) if (buf[i + j] !== needle[j]) continue outer;
        return i;
    }
    return -1;
}

function concat(a, b) {
    if (!a.length) return b;
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
}

async function connectClient(ws, url, protocols) {
    const tls = url.protocol === "wss:";
    const port = Number(url.port) || (tls ? 443 : 80);
    const rid = await bk.op(bk.connect, url.hostname.replace(/^\[|\]$/g, ""), port, tls);
    const conn = new bk.Handle(rid);
    try {
        const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
        let head = `GET ${url.pathname}${url.search} HTTP/1.1\r\nhost: ${url.host}\r\n`
            + `upgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-key: ${key}\r\nsec-websocket-version: 13\r\n`
            + `user-agent: bkr\r\n`;
        if (protocols.length) head += `sec-websocket-protocol: ${protocols.join(", ")}\r\n`;
        await conn.write(enc.encode(head + "\r\n"));
        let buf = new Uint8Array(0);
        let end;
        while ((end = find(buf, CRLFCRLF)) < 0) {
            const chunk = await conn.read();
            if (chunk === null) throw new TypeError("connection closed during the WebSocket handshake");
            buf = concat(buf, chunk);
            if (buf.length > 64 * 1024) throw new TypeError("WebSocket handshake response is too large");
        }
        const lines = new TextDecoder().decode(buf.subarray(0, end)).split("\r\n");
        if (!/^HTTP\/1\.1 101\b/.test(lines[0])) throw new TypeError(`WebSocket handshake failed: ${lines[0]}`);
        const headers = new Headers();
        for (const line of lines.slice(1)) {
            const c = line.indexOf(":");
            if (c > 0) headers.append(line.slice(0, c).trim(), line.slice(c + 1).trim());
        }
        if ((headers.get("upgrade") || "").toLowerCase() !== "websocket"
            || !(headers.get("connection") || "").toLowerCase().split(",").some(t => t.trim() === "upgrade")
            || headers.get("sec-websocket-accept") !== bk.wsAccept(key)) {
            throw new TypeError("invalid WebSocket handshake response");
        }
        const protocol = headers.get("sec-websocket-protocol") || "";
        if (protocol ? !protocols.includes(protocol) : false) throw new TypeError("server chose an unoffered subprotocol");
        if (headers.get("sec-websocket-extensions")) throw new TypeError("server enabled an unoffered extension");
        return { transport: new ClientTransport(ws, conn, buf.subarray(end + 4)), protocol };
    } catch (e) {
        conn.close();
        throw e;
    }
}

const MAX_MESSAGE = 64 * 1024 * 1024;

class ClientTransport {
    constructor(ws, conn, rest) {
        this.ws = ws;
        this.conn = conn;
        this.buf = rest;
        this.pending = 0;
        this.writes = Promise.resolve();
        this.closeSent = false;
        this.done = false;
    }

    buffered() { return this.pending; }

    send(data, binary) {
        const payload = binary ? data.slice() : enc.encode(data);
        this.frame(binary ? 2 : 1, payload);
    }

    close(code, reason) {
        if (this.closeSent) return;
        const r = enc.encode(reason);
        const payload = new Uint8Array(2 + r.length);
        payload[0] = code >> 8;
        payload[1] = code & 255;
        payload.set(r, 2);
        this.frame(8, payload);
        this.closeSent = true;
        // A peer that never answers the close is dropped.
        this.closeTimer = setTimeout(() => this.finish(1006, ""), 5000);
    }

    frame(opcode, payload) {
        if (this.closeSent || this.done) return;
        const n = payload.length;
        const extra = n < 126 ? 0 : n < 65536 ? 2 : 8;
        const out = new Uint8Array(2 + extra + 4 + n);
        out[0] = 0x80 | opcode;
        if (extra === 0) out[1] = 0x80 | n;
        else if (extra === 2) { out[1] = 0x80 | 126; out[2] = n >> 8; out[3] = n & 255; }
        else { out[1] = 0x80 | 127; new DataView(out.buffer).setBigUint64(2, BigInt(n)); }
        const mask = crypto.getRandomValues(new Uint8Array(4));
        out.set(mask, 2 + extra);
        const at = 6 + extra;
        for (let i = 0; i < n; i++) out[at + i] = payload[i] ^ mask[i & 3];
        this.pending += n;
        this.writes = this.writes.then(() => this.conn.write(out)).then(
            () => { this.pending -= n; },
            () => this.finish(1006, ""),
        );
    }

    async need(n) {
        while (this.buf.length < n) {
            const chunk = await this.conn.read();
            if (chunk === null) return false;
            this.buf = concat(this.buf, chunk);
        }
        return true;
    }

    take(n) {
        const out = this.buf.subarray(0, n);
        this.buf = this.buf.subarray(n);
        return out;
    }

    async start() {
        let parts = [], size = 0, kind = 0;
        try {
            for (;;) {
                if (!(await this.need(2))) return this.finish(1006, "");
                const [b0, b1] = this.take(2);
                const fin = !!(b0 & 0x80), opcode = b0 & 15;
                if ((b0 & 0x70) || (b1 & 0x80)) return this.fail(1002);
                let n = b1 & 127;
                if (n === 126) {
                    if (!(await this.need(2))) return this.finish(1006, "");
                    const b = this.take(2);
                    n = b[0] << 8 | b[1];
                } else if (n === 127) {
                    if (!(await this.need(8))) return this.finish(1006, "");
                    const big = new DataView(this.take(8).slice().buffer).getBigUint64(0);
                    if (big > BigInt(MAX_MESSAGE)) return this.fail(1009);
                    n = Number(big);
                }
                if (opcode >= 8 && (n > 125 || !fin)) return this.fail(1002);
                if (size + n > MAX_MESSAGE) return this.fail(1009);
                if (!(await this.need(n))) return this.finish(1006, "");
                const payload = this.take(n).slice();
                if (opcode === 8) {
                    const code = n >= 2 ? payload[0] << 8 | payload[1] : 1005;
                    let reason = "";
                    try { reason = dec.decode(payload.subarray(2)); } catch { return this.fail(1007); }
                    if (!this.closeSent) this.close(code === 1005 ? 1000 : code, "");
                    await this.writes;
                    return this.finish(code, reason);
                }
                if (opcode === 9) { this.frame(10, payload); continue; }
                if (opcode === 10) continue;
                if (opcode === 0) {
                    if (!kind) return this.fail(1002);
                } else if (opcode === 1 || opcode === 2) {
                    if (kind) return this.fail(1002);
                    kind = opcode;
                } else {
                    return this.fail(1002);
                }
                parts.push(payload);
                size += n;
                if (!fin) continue;
                let data = parts.length === 1 ? parts[0] : new Uint8Array(size);
                if (parts.length > 1) { let at = 0; for (const p of parts) { data.set(p, at); at += p.length; } }
                const binary = kind === 2;
                parts = []; size = 0; kind = 0;
                if (!binary) {
                    try { data = dec.decode(data); } catch { return this.fail(1007); }
                }
                this.ws._message(data, binary);
            }
        } catch {
            this.finish(1006, "");
        }
    }

    fail(code) {
        this.close(code, "");
        this.writes.then(() => this.finish(1006, ""));
    }

    finish(code, reason) {
        if (this.done) return;
        this.done = true;
        clearTimeout(this.closeTimer);
        this.conn.close();
        this.ws._closed(code, reason, code === 1006);
    }
}

Object.defineProperty(globalThis, "WebSocket", { value: WebSocket, writable: true, configurable: true });
Object.defineProperty(globalThis, "CloseEvent", { value: CloseEvent, writable: true, configurable: true });
})(__bk);
