// The JS half of the fetch-style API: Headers, Request, Response, URL,
// URLSearchParams, TextEncoder/TextDecoder and timers, shaped after what Bun,
// Deno and Cloudflare Workers expose.
//
// It is written in JS rather than as host objects because these are mostly
// plumbing over plain JS values -- a Headers is a Map, a body is a string --
// and keeping them in JS lets the engine's inline caches see through them.
// The host boundary is kept to a few primitives that move strings across:
//
//   C3 -> JS  __dispatch(id, method, body)
//             __timer_fire(id)
//   JS -> C3  __respond(id, status, statusText, headerBlob, body)
//             __req_url(id), __req_headers(id) -> string, read lazily
//             __timer_start(ms, id) -> handle, __timer_cancel(handle)
//
// A header blob is "name\nvalue\nname\nvalue\n...": HTTP forbids a newline in
// either, so it splits without escaping, and it costs one string per request
// rather than one per header.
//
// No backticks in here: the whole thing is a C3 raw string.
module test_server_uws;

const String PRELUDE = `
"use strict";
var __INTERNAL = {};

function __utf8encode(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
            var d = s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
            else c = 0xFFFD;
        } else if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
}

function __utf8decode(b) {
    var s = "";
    for (var i = 0; i < b.length; ) {
        var c = b[i++], n = 0, cp;
        if (c < 0x80) { s += String.fromCharCode(c); continue; }
        else if (c >= 0xC2 && c < 0xE0) { n = 1; cp = c & 31; }
        else if (c >= 0xE0 && c < 0xF0) { n = 2; cp = c & 15; }
        else if (c >= 0xF0 && c < 0xF5) { n = 3; cp = c & 7; }
        else { s += "�"; continue; }
        if (i + n > b.length) { s += "�"; break; }
        var ok = true;
        for (var k = 0; k < n; k++) {
            var x = b[i + k];
            if ((x & 0xC0) !== 0x80) { ok = false; break; }
            cp = (cp << 6) | (x & 63);
        }
        if (!ok) { s += "�"; continue; }
        i += n;
        s += String.fromCodePoint(cp);
    }
    return s;
}

class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(s) { return __utf8encode(s === undefined ? "" : String(s)); }
}

class TextDecoder {
    get encoding() { return "utf-8"; }
    decode(b) {
        if (b === undefined) return "";
        if (b instanceof ArrayBuffer) b = new Uint8Array(b);
        else if (ArrayBuffer.isView(b) && !(b instanceof Uint8Array))
            b = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
        return __utf8decode(b);
    }
}

// ---- URLSearchParams / URL ---------------------------------------------

function __formDecode(s) {
    s = s.replace(/\+/g, " ");
    try { return decodeURIComponent(s); } catch (e) { return s; }
}

function __formEncode(s) {
    return encodeURIComponent(s).replace(/%20/g, "+");
}

class URLSearchParams {
    constructor(init) {
        this._list = [];
        this._url = null;
        if (init === undefined || init === null) return;
        if (init instanceof URLSearchParams) {
            for (var p of init._list) this._list.push([p[0], p[1]]);
        } else if (typeof init === "object" && typeof init[Symbol.iterator] === "function") {
            for (var e of init) this._list.push([String(e[0]), String(e[1])]);
        } else if (typeof init === "object") {
            for (var k of Object.keys(init)) this._list.push([k, String(init[k])]);
        } else {
            this._parse(String(init));
        }
    }
    _parse(s) {
        this._list = [];
        if (s.charAt(0) === "?") s = s.slice(1);
        if (s === "") return;
        var parts = s.split("&");
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (part === "") continue;
            var eq = part.indexOf("=");
            if (eq < 0) this._list.push([__formDecode(part), ""]);
            else this._list.push([__formDecode(part.slice(0, eq)), __formDecode(part.slice(eq + 1))]);
        }
    }
    _update() { if (this._url) this._url._setSearch(this.toString()); }
    get size() { return this._list.length; }
    append(k, v) { this._list.push([String(k), String(v)]); this._update(); }
    delete(k) { k = String(k); this._list = this._list.filter(function (p) { return p[0] !== k; }); this._update(); }
    get(k) { k = String(k); for (var p of this._list) if (p[0] === k) return p[1]; return null; }
    getAll(k) { k = String(k); return this._list.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); }
    has(k) { k = String(k); return this._list.some(function (p) { return p[0] === k; }); }
    set(k, v) {
        k = String(k); v = String(v);
        var out = [], done = false;
        for (var p of this._list) {
            if (p[0] !== k) out.push(p);
            else if (!done) { out.push([k, v]); done = true; }
        }
        if (!done) out.push([k, v]);
        this._list = out;
        this._update();
    }
    sort() { this._list.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); this._update(); }
    forEach(fn, self) { for (var p of this._list) fn.call(self, p[1], p[0], this); }
    keys() { return this._list.map(function (p) { return p[0]; })[Symbol.iterator](); }
    values() { return this._list.map(function (p) { return p[1]; })[Symbol.iterator](); }
    entries() { return this._list.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
    toString() {
        return this._list.map(function (p) { return __formEncode(p[0]) + "=" + __formEncode(p[1]); }).join("&");
    }
}

// Splits scheme://authority/path?query#hash with builtin indexOf calls --
// a loop over characters in JS is several times slower here -- which covers
// every request URL; anything unusual goes through the regex.
function __urlSplit(u) {
    var se = u.indexOf("://");
    if (se <= 0 || se >= 10) return __URL_RE.exec(u);
    var a = se + 3;
    var h = u.indexOf("#", a);
    var end = h < 0 ? u.length : h;
    var q = u.indexOf("?", a);
    if (q > end) q = -1;
    var stop = q < 0 ? end : q;
    var p = u.indexOf("/", a);
    if (p < 0 || p > stop) p = stop;
    return [u, u.slice(0, se + 1), u.slice(a, p), u.slice(p, stop),
            q < 0 ? undefined : u.slice(q, end), h < 0 ? undefined : u.slice(h)];
}

var __URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/;

class URL {
    constructor(url, base) {
        url = String(url);
        var m = __urlSplit(url);
        if (!m && base !== undefined) {
            var b = base instanceof URL ? base : new URL(String(base));
            if (url.charAt(0) === "/" && url.charAt(1) === "/") m = __urlSplit(b.protocol + url);
            else if (url.charAt(0) === "/") m = __urlSplit(b.origin + url);
            else if (url.charAt(0) === "?") m = __urlSplit(b.origin + b.pathname + url);
            else if (url.charAt(0) === "#") m = __urlSplit(b.origin + b.pathname + b.search + url);
            else {
                var dir = b.pathname.slice(0, b.pathname.lastIndexOf("/") + 1);
                m = __urlSplit(b.origin + dir + url);
            }
        }
        if (!m) throw new TypeError("Invalid URL: " + url);
        this.protocol = m[1] === "http:" || m[1] === "https:" ? m[1] : m[1].toLowerCase();
        var host = m[2];
        var at = host.lastIndexOf("@");
        this.username = ""; this.password = "";
        if (at >= 0) {
            var cred = host.slice(0, at); host = host.slice(at + 1);
            var c = cred.indexOf(":");
            if (c < 0) this.username = cred;
            else { this.username = cred.slice(0, c); this.password = cred.slice(c + 1); }
        }
        var colon = host.lastIndexOf(":");
        if (colon >= 0 && host.indexOf("]", colon) < 0) {
            this.hostname = host.slice(0, colon).toLowerCase();
            this.port = host.slice(colon + 1);
        } else {
            this.hostname = host.toLowerCase();
            this.port = "";
        }
        if ((this.protocol === "http:" && this.port === "80") || (this.protocol === "https:" && this.port === "443"))
            this.port = "";
        this.pathname = __normalizePath(m[3] || "/");
        this._search = m[4] && m[4] !== "?" ? m[4] : "";
        this.hash = m[5] && m[5] !== "#" ? m[5] : "";
        this._params = null;
    }
    get host() { return this.port ? this.hostname + ":" + this.port : this.hostname; }
    get origin() { return this.protocol + "//" + this.host; }
    get search() { return this._search; }
    set search(s) {
        s = String(s);
        if (s !== "" && s.charAt(0) !== "?") s = "?" + s;
        this._search = s === "?" ? "" : s;
        if (this._params) this._params._parse(this._search);
    }
    _setSearch(qs) { this._search = qs ? "?" + qs : ""; }
    get searchParams() {
        if (!this._params) { this._params = new URLSearchParams(this._search); this._params._url = this; }
        return this._params;
    }
    get href() {
        var auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
        return this.protocol + "//" + auth + this.host + this.pathname + this._search + this.hash;
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
    static canParse(u, b) { try { new URL(u, b); return true; } catch (e) { return false; } }
}

function __normalizePath(p) {
    if (p.indexOf(".") < 0) return p;
    var segs = p.split("/"), out = [];
    for (var i = 0; i < segs.length; i++) {
        var s = segs[i];
        if (s === "..") { if (out.length > 1) out.pop(); if (i === segs.length - 1) out.push(""); }
        else if (s === ".") { if (i === segs.length - 1) out.push(""); }
        else out.push(s);
    }
    var r = out.join("/");
    return r.charAt(0) === "/" ? r : "/" + r;
}

// ---- Headers -----------------------------------------------------------

class Headers {
    constructor(init) {
        // lowercased name -> value; Map keeps insertion order for iteration.
        this._map = new Map();
        this._cookies = null;
        if (init === __INTERNAL) return;
        if (init === undefined || init === null) return;
        if (init instanceof Headers) {
            for (var e of init._map) this._map.set(e[0], e[1]);
            if (init._cookies) this._cookies = init._cookies.slice();
        } else if (typeof init[Symbol.iterator] === "function") {
            for (var p of init) this.append(p[0], p[1]);
        } else {
            for (var k of Object.keys(init)) this.append(k, init[k]);
        }
    }
    // Set-Cookie is the one header that must not be joined with commas.
    append(k, v) {
        k = String(k).toLowerCase(); v = String(v).trim();
        if (k === "set-cookie") { (this._cookies || (this._cookies = [])).push(v); return; }
        var cur = this._map.get(k);
        this._map.set(k, cur === undefined ? v : cur + ", " + v);
    }
    set(k, v) {
        k = String(k).toLowerCase(); v = String(v).trim();
        if (k === "set-cookie") { this._cookies = [v]; return; }
        this._map.set(k, v);
    }
    get(k) {
        k = String(k).toLowerCase();
        if (k === "set-cookie") return this._cookies ? this._cookies.join(", ") : null;
        var v = this._map.get(k);
        return v === undefined ? null : v;
    }
    getSetCookie() { return this._cookies ? this._cookies.slice() : []; }
    has(k) {
        k = String(k).toLowerCase();
        return k === "set-cookie" ? !!(this._cookies && this._cookies.length) : this._map.has(k);
    }
    delete(k) {
        k = String(k).toLowerCase();
        if (k === "set-cookie") this._cookies = null; else this._map.delete(k);
    }
    forEach(fn, self) { for (var e of this.entries()) fn.call(self, e[1], e[0], this); }
    *entries() {
        var keys = Array.from(this._map.keys());
        if (this._cookies) keys.push("set-cookie");
        keys.sort();
        for (var k of keys) {
            if (k === "set-cookie") { for (var c of this._cookies) yield [k, c]; }
            else yield [k, this._map.get(k)];
        }
    }
    *keys() { for (var e of this.entries()) yield e[0]; }
    *values() { for (var e of this.entries()) yield e[1]; }
    [Symbol.iterator]() { return this.entries(); }
    toJSON() { var o = {}; for (var e of this.entries()) o[e[0]] = e[1]; return o; }

    _blob() {
        var s = "";
        for (var e of this._map) s += e[0] + "\n" + e[1] + "\n";
        if (this._cookies) for (var c of this._cookies) s += "set-cookie\n" + c + "\n";
        return s;
    }
    static _fromBlob(blob) {
        var h = new Headers(__INTERNAL);
        if (blob === "") return h;
        var parts = blob.split("\n");
        for (var i = 0; i + 1 < parts.length; i += 2) h.append(parts[i], parts[i + 1]);
        return h;
    }
}

// ---- bodies ------------------------------------------------------------

// Bodies are held as strings. That is what crosses to C3, and what nearly
// every handler produces or consumes; bytes are converted at the edges.
function __bodyInit(body, headers) {
    if (body === undefined || body === null) return null;
    if (typeof body === "string") {
        if (!headers.has("content-type")) headers.set("content-type", "text/plain;charset=UTF-8");
        return body;
    }
    if (body instanceof URLSearchParams) {
        if (!headers.has("content-type")) headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
        return body.toString();
    }
    if (body instanceof ArrayBuffer) return __utf8decode(new Uint8Array(body));
    if (ArrayBuffer.isView(body)) return __utf8decode(new Uint8Array(body.buffer, body.byteOffset, body.byteLength));
    if (body instanceof Request || body instanceof Response) return body._body;
    var s = String(body);
    if (!headers.has("content-type")) headers.set("content-type", "text/plain;charset=UTF-8");
    return s;
}

var __BodyMixin = {
    get body() { return this._body; },
    get bodyUsed() { return this._used; },
    _consume() {
        if (this._used) return Promise.reject(new TypeError("Body already used"));
        this._used = true;
        return Promise.resolve(this._body === null ? "" : this._body);
    },
    text() { return this._consume(); },
    json() { return this._consume().then(JSON.parse); },
    arrayBuffer() { return this._consume().then(function (s) { return __utf8encode(s).buffer; }); },
    bytes() { return this._consume().then(__utf8encode); },
    formData() { return Promise.reject(new TypeError("formData() is not supported")); },
    blob() { return Promise.reject(new TypeError("blob() is not supported")); },
};

function __mixBody(cls) {
    for (var k of Object.getOwnPropertyNames(__BodyMixin))
        Object.defineProperty(cls.prototype, k, Object.getOwnPropertyDescriptor(__BodyMixin, k));
}

// ---- Request -----------------------------------------------------------

class Request {
    constructor(input, init, id, body) {
        if (input === __INTERNAL) {
            // From the server. The URL and headers are fetched from C3 only
            // if the handler reads them, which most handlers barely do. The
            // other fields default from the prototype (see __protoDefaults).
            this.method = init;
            this._id = id;
            if (body !== undefined) this._body = body;
            return;
        }
        init = init || {};
        var src = input instanceof Request ? input : null;
        this._url = src ? src.url : new URL(String(input)).href;
        this.method = String(init.method || (src ? src.method : "GET")).toUpperCase();
        this._headers = new Headers(init.headers !== undefined ? init.headers : src ? src.headers : undefined);
        this._id = 0;
        this._body = init.body !== undefined ? __bodyInit(init.body, this._headers) : src ? src._body : null;
        this._used = false;
    }
    get url() {
        if (this._url === null) this._url = __req_url(this._id);
        return this._url;
    }
    get headers() {
        if (this._headers === null) this._headers = Headers._fromBlob(__req_headers(this._id));
        return this._headers;
    }
    get signal() { return undefined; }
    clone() {
        if (this._used) throw new TypeError("Body already used");
        return new Request(this);
    }
}
__mixBody(Request);

// Defaults on the prototype rather than assigned in each constructor: every
// own property a constructor adds costs a shape transition and a setter check
// up the prototype chain, which on the per-request path is most of the cost
// of building the object. An instance gets its own property only when it
// differs.
function __protoDefaults(cls, d) {
    for (var k of Object.keys(d))
        Object.defineProperty(cls.prototype, k, { value: d[k], writable: true, configurable: true });
}
__protoDefaults(Request, { _id: 0, _url: null, _headers: null, _body: null, _used: false });

// ---- Response ----------------------------------------------------------

var __STATUS_TEXT = {
    200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
    301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
    307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 413: "Payload Too Large",
    415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests",
    500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
    503: "Service Unavailable", 504: "Gateway Timeout",
};

var __CT_TEXT = "text/plain;charset=UTF-8";
var __BLOB_TEXT = "content-type\n" + __CT_TEXT + "\n";

// The overwhelmingly common Response is a string body with no headers. That
// one never builds a Headers: it keeps the body and its implied content-type
// and hands C3 a constant blob. Touching .headers materializes the real thing.
class Response {
    constructor(body, init) {
        if (typeof body === "string" && init === undefined) {
            // The hot case: everything but the body is a prototype default.
            this._body = body;
            return;
        }
        if (init === undefined || init === null) {
        } else {
            var status = init.status === undefined ? 200 : init.status | 0;
            if (status < 200 || status > 599) throw new RangeError("Invalid status: " + init.status);
            this.status = status;
            if (init.statusText !== undefined) this._statusText = String(init.statusText);
            if (init.headers !== undefined) this._headers = init._own ? init.headers : new Headers(init.headers);
        }
        if (typeof body === "string" && this._headers === null) {
            this._body = body;
        } else if (body === undefined || body === null) {
            this._ct = null;
        } else {
            this._ct = null;
            this._body = __bodyInit(body, this.headers);
        }
    }
    get headers() {
        if (this._headers === null) {
            this._headers = new Headers(__INTERNAL);
            if (this._ct !== null) this._headers.set("content-type", this._ct);
        }
        return this._headers;
    }
    get statusText() {
        return this._statusText !== null ? this._statusText : (__STATUS_TEXT[this.status] || "");
    }
    get ok() { return this.status >= 200 && this.status < 300; }
    get url() { return ""; }
    _blob() {
        if (this._headers !== null) return this._headers._blob();
        return this._ct === __CT_TEXT ? __BLOB_TEXT : "";
    }
    clone() {
        if (this._used) throw new TypeError("Body already used");
        var r = new Response(null, { status: this.status, statusText: this._statusText === null ? undefined : this._statusText, headers: this.headers });
        r._body = this._body;
        return r;
    }
    static json(data, init) {
        var h = new Headers(init === undefined ? undefined : init.headers);
        if (!h.has("content-type")) h.set("content-type", "application/json");
        return new Response(JSON.stringify(data), { status: init === undefined ? undefined : init.status,
            statusText: init === undefined ? undefined : init.statusText, headers: h, _own: true });
    }
    static redirect(url, status) {
        status = status === undefined ? 302 : status;
        if ([301, 302, 303, 307, 308].indexOf(status) < 0) throw new RangeError("Invalid redirect status: " + status);
        var h = new Headers(__INTERNAL);
        h.set("location", String(url));
        return new Response(null, { status: status, headers: h, _own: true });
    }
    static error() {
        var r = new Response(null, { status: 500 });
        r.type = "error";
        return r;
    }
}
__mixBody(Response);
__protoDefaults(Response, { status: 200, type: "default", redirected: false, _used: false,
                            _statusText: null, _headers: null, _ct: __CT_TEXT, _body: null });

// ---- timers ------------------------------------------------------------

var __timers = new Map();
var __timer_next = 1;

function __timer_fire(id) {
    var t = __timers.get(id);
    if (t === undefined) return;
    if (t.interval >= 0) t.handle = __timer_start(t.interval, id);
    else __timers.delete(id);
    t.fn.apply(undefined, t.args);
}

function __timer_add(fn, ms, args, repeat) {
    if (typeof fn !== "function") throw new TypeError("callback must be a function");
    ms = +ms; if (!(ms >= 0)) ms = 0;
    var id = __timer_next++;
    __timers.set(id, { fn: fn, args: args, interval: repeat ? ms : -1, handle: __timer_start(ms, id) });
    return id;
}

function setTimeout(fn, ms) { return __timer_add(fn, ms, Array.prototype.slice.call(arguments, 2), false); }
function setInterval(fn, ms) { return __timer_add(fn, ms, Array.prototype.slice.call(arguments, 2), true); }
function clearTimeout(id) {
    var t = __timers.get(id);
    if (t === undefined) return;
    __timers.delete(id);
    __timer_cancel(t.handle);
}
var clearInterval = clearTimeout;
function queueMicrotask(fn) { Promise.resolve().then(fn); }

// ---- dispatch ----------------------------------------------------------

// The handler as the script gave it: an object with fetch, called as a
// method so it keeps its this, or a bare function.
var __handlerObj = null;
var __handlerFn = null;

function __install(h) {
    if (typeof h === "function") __handlerFn = h;
    else if (h && typeof h.fetch === "function") __handlerObj = h;
    else throw new TypeError("the script must evaluate to a fetch function or an object with fetch()");
}

function __report(e) {
    if (typeof console !== "undefined" && console.error) console.error(e && e.stack ? e.stack : String(e));
}

function __fail(id, e) {
    __report(e);
    __respond(id, 500, "Internal Server Error", "content-type\ntext/plain;charset=UTF-8\n", "Internal Server Error");
}

function __send(id, res) {
    if (!(res instanceof Response)) {
        __fail(id, new TypeError("fetch handler must return a Response, got " + typeof res));
        return;
    }
    res._used = true;
    var st = res.status;
    __respond(id, st, st === 200 ? "" : res.statusText, res._blob(), res._body === null ? "" : res._body);
}

function __dispatch(id, method, body) {
    var req = new Request(__INTERNAL, method, id, body);
    var r;
    try { r = __handlerObj !== null ? __handlerObj.fetch(req) : __handlerFn(req); }
    catch (e) { __fail(id, e); return; }
    if (r instanceof Response) {
        r._used = true;
        var st = r.status;
        __respond(id, st, st === 200 ? "" : r.statusText, r._blob(), r._body === null ? "" : r._body);
        return;
    }
    Promise.resolve(r).then(function (res) { __send(id, res); }, function (e) { __fail(id, e); });
}
`;
