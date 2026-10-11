(function (bk) {
const enc = new TextEncoder();
const dec = new TextDecoder();
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const MAX_REDIRECTS = 20;

const concat = (a, b) => {
    if (a.length === 0) return b;
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
};

function indexOf(buf, needle, from = 0) {
    outer: for (let i = from; i <= buf.length - needle.length; i++) {
        for (let j = 0; j < needle.length; j++) if (buf[i + j] !== needle[j]) continue outer;
        return i;
    }
    return -1;
}

const CRLFCRLF = enc.encode("\r\n\r\n");
const CRLF = enc.encode("\r\n");

class Reader {
    constructor(conn) {
        this.conn = conn;
        this.buf = new Uint8Array(0);
        this.eof = false;
    }
    async fill() {
        const chunk = await this.conn.read();
        if (chunk === null) {
            this.eof = true;
            return false;
        }
        this.buf = concat(this.buf, chunk);
        return true;
    }
    async until(needle) {
        let from = 0;
        for (;;) {
            const i = indexOf(this.buf, needle, from);
            if (i >= 0) {
                const head = this.buf.subarray(0, i);
                this.buf = this.buf.subarray(i + needle.length);
                return head;
            }
            from = Math.max(0, this.buf.length - needle.length + 1);
            if (!(await this.fill())) throw new TypeError("connection closed before the response was complete");
        }
    }
    async take(n) {
        while (this.buf.length < n) if (!(await this.fill())) throw new TypeError("connection closed mid-body");
        const out = this.buf.subarray(0, n);
        this.buf = this.buf.subarray(n);
        return out;
    }
    async next() {
        if (this.buf.length > 0) {
            const out = this.buf;
            this.buf = new Uint8Array(0);
            return out;
        }
        return this.conn.read();
    }
}

function bodyStream(reader, headers, method, status) {
    const conn = reader.conn;
    const done = (c) => { c.close(); conn.close(); };
    if (method === "HEAD" || status === 204 || status === 304 || (status >= 100 && status < 200)) {
        conn.close();
        return null;
    }
    const te = (headers.get("transfer-encoding") || "").toLowerCase();
    if (te.includes("chunked")) {
        return new ReadableStream({
            async pull(c) {
                const line = dec.decode(await reader.until(CRLF));
                const size = parseInt(line, 16);
                if (!(size >= 0)) throw new TypeError("bad chunk size");
                if (size === 0) {
                    for (;;) if ((await reader.until(CRLF)).length === 0) break;
                    return done(c);
                }
                c.enqueue((await reader.take(size)).slice());
                await reader.take(2);
            },
            cancel: () => conn.close(),
        });
    }
    const length = headers.get("content-length");
    if (length !== null) {
        let left = Number(length);
        return new ReadableStream({
            async pull(c) {
                if (left === 0) return done(c);
                const chunk = await reader.next();
                if (chunk === null) throw new TypeError("connection closed mid-body");
                const part = chunk.length > left ? chunk.subarray(0, left) : chunk;
                left -= part.length;
                c.enqueue(part.slice());
                if (left === 0) done(c);
            },
            cancel: () => conn.close(),
        });
    }
    return new ReadableStream({
        async pull(c) {
            const chunk = await reader.next();
            if (chunk === null) return done(c);
            c.enqueue(chunk.slice());
        },
        cancel: () => conn.close(),
    });
}

async function requestOnce(url, method, headers, body, signal) {
    const tls = url.protocol === "https:";
    if (!tls && url.protocol !== "http:") throw new TypeError("unsupported protocol: " + url.protocol);
    const port = Number(url.port) || (tls ? 443 : 80);
    const rid = await bk.op(bk.connect, url.hostname.replace(/^\[|\]$/g, ""), port, tls);
    const conn = new bk.Handle(rid);
    const abort = () => conn.close();
    signal?.addEventListener("abort", abort, { once: true });
    try {
        const h = new Headers(headers);
        if (!h.has("host")) h.set("host", url.host);
        if (!h.has("user-agent")) h.set("user-agent", "bkr");
        if (!h.has("accept")) h.set("accept", "*/*");
        h.set("accept-encoding", "identity");
        h.set("connection", "close");
        if (body !== null) h.set("content-length", String(body.length));
        else if (method === "POST" || method === "PUT" || method === "PATCH") h.set("content-length", "0");
        let head = `${method} ${url.pathname}${url.search} HTTP/1.1\r\n`;
        for (const [k, v] of h) head += `${k}: ${v}\r\n`;
        await conn.write(enc.encode(head + "\r\n"));
        if (body !== null && body.length) await conn.write(body);
        const reader = new Reader(conn);
        const text = dec.decode(await reader.until(CRLFCRLF));
        const lines = text.split("\r\n");
        const m = /^HTTP\/1\.[01] (\d{3}) ?(.*)$/.exec(lines[0]);
        if (!m) throw new TypeError("invalid HTTP response");
        const rh = new Headers();
        for (let i = 1; i < lines.length; i++) {
            const c = lines[i].indexOf(":");
            if (c > 0) rh.append(lines[i].slice(0, c).trim(), lines[i].slice(c + 1).trim());
        }
        const status = Number(m[1]);
        return { status, statusText: m[2], headers: rh, reader, conn };
    } catch (e) {
        conn.close();
        if (signal?.aborted) throw signal.reason;
        throw e;
    } finally {
        signal?.removeEventListener("abort", abort);
    }
}

async function fetch(input, init = {}) {
    const req = input instanceof Request ? input : null;
    let url = new URL(req ? req.url : String(input));
    let method = (init.method ?? req?.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers ?? req?.headers);
    const signal = init.signal ?? req?.signal ?? null;
    let body = null;
    const rawBody = init.body ?? (req && req.body ? await req.bytes() : null);
    if (rawBody !== null && rawBody !== undefined) {
        const r = new Request(url, { method: "POST", body: rawBody });
        if (!headers.has("content-type") && r.headers.has("content-type")) headers.set("content-type", r.headers.get("content-type"));
        body = await r.bytes();
    }
    const redirect = init.redirect ?? "follow";
    signal?.throwIfAborted();
    for (let hops = 0; ; hops++) {
        const res = await requestOnce(url, method, headers, body, signal);
        if (REDIRECTS.has(res.status) && res.headers.has("location") && redirect !== "manual") {
            res.conn.close();
            if (redirect === "error") throw new TypeError("redirect not allowed");
            if (hops >= MAX_REDIRECTS) throw new TypeError("too many redirects");
            const next = new URL(res.headers.get("location"), url);
            if (next.origin !== url.origin) {
                headers.delete("authorization");
                headers.delete("cookie");
            }
            if (res.status === 303 || ((res.status === 301 || res.status === 302) && method === "POST")) {
                method = method === "HEAD" ? "HEAD" : "GET";
                body = null;
                headers.delete("content-type");
            }
            url = next;
            continue;
        }
        const stream = bodyStream(res.reader, res.headers, method, res.status);
        const out = new Response(stream, { status: res.status === 101 ? 200 : res.status, statusText: res.statusText, headers: res.headers });
        Object.defineProperty(out, "url", { value: url.href });
        Object.defineProperty(out, "redirected", { value: hops > 0 });
        return out;
    }
}

globalThis.fetch = fetch;
})(__bk);
