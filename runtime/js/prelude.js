// Web-standard globals over the natives on __bk.
"use strict";
(function (bk) {

const INTERNAL = Symbol("internal");
const def = (name, value) => Object.defineProperty(globalThis, name, { value, writable: true, configurable: true });
const hidden = (obj, props) => { for (const k in props) Object.defineProperty(obj, k, { value: props[k], writable: true, configurable: true }); };

// ---- errors and async ops ----

class SystemError extends Error {
    constructor(code, message) {
        super(message);
        this.code = code;
    }
    get name() { return this.code === "PERMISSION_DENIED" ? "PermissionDenied" : "SystemError"; }
}
def("SystemError", SystemError);
bk.error = (code, message) => new SystemError(code, message);

const pending = new Map();
let nextOp = 1;

bk.op = function (native, a, b, c, d) {
    const id = nextOp++;
    const p = Promise.withResolvers();
    pending.set(id, p);
    native(id, a, b, c, d);
    return p.promise;
};

bk.settle = function (id, ok, value, code) {
    const p = pending.get(id);
    if (p === undefined) return;
    pending.delete(id);
    if (ok) p.resolve(value);
    else p.reject(new SystemError(code, value));
};

// ---- encoding ----

class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(s = "") { return bk.encode(String(s)); }
    encodeInto(s, dest) {
        const b = bk.encode(String(s));
        const n = Math.min(b.length, dest.length);
        dest.set(n === b.length ? b : b.subarray(0, n));
        return { read: s.length, written: n };
    }
}

function asBytes(b) {
    if (b instanceof Uint8Array) return b;
    if (b instanceof ArrayBuffer || b instanceof SharedArrayBuffer) return new Uint8Array(b);
    if (ArrayBuffer.isView(b)) return new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    throw new TypeError("expected an ArrayBuffer or view");
}
bk.asBytes = asBytes;

class TextDecoder {
    constructor(label = "utf-8", opts = {}) {
        label = String(label).toLowerCase();
        if (label !== "utf-8" && label !== "utf8" && label !== "unicode-1-1-utf-8")
            throw new RangeError("unsupported encoding: " + label);
        this.fatal = !!opts.fatal;
        this.ignoreBOM = !!opts.ignoreBOM;
    }
    get encoding() { return "utf-8"; }
    decode(b, opts) {
        if (b === undefined) return "";
        let u = asBytes(b);
        if (!this.ignoreBOM && u.length >= 3 && u[0] === 0xEF && u[1] === 0xBB && u[2] === 0xBF) u = u.subarray(3);
        const s = bk.decode(u, this.fatal);
        if (s === null) throw new TypeError("invalid UTF-8");
        return s;
    }
}

def("TextEncoder", TextEncoder);
def("TextDecoder", TextDecoder);

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
def("btoa", function btoa(s) {
    s = String(s);
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
        const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
        if (a > 255 || b > 255 || c > 255) throw new DOMException("invalid character", "InvalidCharacterError");
        const n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += B64[n >> 18] + B64[(n >> 12) & 63] + (i + 1 < s.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < s.length ? B64[n & 63] : "=");
    }
    return out;
});
def("atob", function atob(s) {
    s = String(s).replace(/[\t\n\f\r ]/g, "");
    if (s.length % 4 === 0) s = s.replace(/==?$/, "");
    if (s.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(s)) throw new DOMException("invalid base64", "InvalidCharacterError");
    let out = "", bits = 0, acc = 0;
    for (let i = 0; i < s.length; i++) {
        acc = (acc << 6) | B64.indexOf(s[i]);
        bits += 6;
        if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); }
    }
    return out;
});

class DOMException extends Error {
    constructor(message = "", name = "Error") { super(message); this._name = name; }
    get name() { return this._name; }
}
def("DOMException", DOMException);

// ---- events and abort ----

class Event {
    constructor(type, init = {}) {
        this.type = String(type);
        this.bubbles = !!init.bubbles;
        this.cancelable = !!init.cancelable;
        this.defaultPrevented = false;
        this.target = null;
        this.currentTarget = null;
        this.timeStamp = performance.now();
    }
    preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
    stopPropagation() {}
    stopImmediatePropagation() { this._stop = true; }
}

class EventTarget {
    constructor() { hidden(this, { _listeners: new Map() }); }
    addEventListener(type, fn, opts) {
        if (!fn) return;
        const once = typeof opts === "object" && opts !== null && !!opts.once;
        let list = this._listeners.get(type);
        if (!list) this._listeners.set(type, list = []);
        if (!list.some((l) => l.fn === fn)) list.push({ fn, once });
        if (typeof opts === "object" && opts && opts.signal) opts.signal.addEventListener("abort", () => this.removeEventListener(type, fn));
    }
    removeEventListener(type, fn) {
        const list = this._listeners.get(type);
        if (list) this._listeners.set(type, list.filter((l) => l.fn !== fn));
    }
    dispatchEvent(ev) {
        ev.target = ev.currentTarget = this;
        const handler = this["on" + ev.type];
        if (typeof handler === "function") handler.call(this, ev);
        for (const l of (this._listeners.get(ev.type) || []).slice()) {
            if (l.once) this.removeEventListener(ev.type, l.fn);
            if (typeof l.fn === "function") l.fn.call(this, ev); else l.fn.handleEvent(ev);
            if (ev._stop) break;
        }
        return !ev.defaultPrevented;
    }
}

class AbortSignal extends EventTarget {
    constructor(key) {
        if (key !== INTERNAL) throw new TypeError("Illegal constructor");
        super();
        this.aborted = false;
        this.reason = undefined;
        this.onabort = null;
    }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    _abort(reason) {
        if (this.aborted) return;
        this.aborted = true;
        this.reason = reason === undefined ? new DOMException("The operation was aborted", "AbortError") : reason;
        this.dispatchEvent(new Event("abort"));
    }
    static abort(reason) { const s = new AbortSignal(INTERNAL); s._abort(reason); return s; }
    static timeout(ms) {
        const s = new AbortSignal(INTERNAL);
        setTimeout(() => s._abort(new DOMException("signal timed out", "TimeoutError")), ms);
        return s;
    }
    static any(signals) {
        const s = new AbortSignal(INTERNAL);
        for (const x of signals) {
            if (x.aborted) { s._abort(x.reason); break; }
            x.addEventListener("abort", () => s._abort(x.reason), { once: true });
        }
        return s;
    }
}

class AbortController {
    constructor() { this.signal = new AbortSignal(INTERNAL); }
    abort(reason) { this.signal._abort(reason); }
}

def("Event", Event);
def("EventTarget", EventTarget);
def("AbortSignal", AbortSignal);
def("AbortController", AbortController);

// ---- the global scope as an event target ----

const globalEvents = new EventTarget();
def("addEventListener", globalEvents.addEventListener.bind(globalEvents));
def("removeEventListener", globalEvents.removeEventListener.bind(globalEvents));
def("dispatchEvent", globalEvents.dispatchEvent.bind(globalEvents));

class PromiseRejectionEvent extends Event {
    constructor(type, init) {
        super(type, init);
        this.promise = init.promise;
        this.reason = init.reason;
    }
}
def("PromiseRejectionEvent", PromiseRejectionEvent);

bk.unhandled = function (reason, promise) {
    const ev = new PromiseRejectionEvent("unhandledrejection", { reason, promise, cancelable: true });
    globalEvents.dispatchEvent(ev);
    return ev.defaultPrevented;
};

bk.describe = (v) => v instanceof Error && v.stack ? v.stack : typeof v === "string" ? v : JSON.stringify(v) ?? String(v);

// ---- timers ----

// Every timer lives in one heap; a single native timer is armed for the
// earliest, so a burst of timers costs one kernel timer, not one each.
const timers = new Map();
const heap = [];
let nextTimer = 1;
let armed = 0;
let armedDue = 0;

const before = (a, b) => a.due < b.due || (a.due === b.due && a.id < b.id);

function heapPush(e) {
    let i = heap.push(e) - 1;
    while (i > 0) {
        const parent = (i - 1) >> 1;
        if (!before(e, heap[parent])) break;
        heap[i] = heap[parent];
        i = parent;
    }
    heap[i] = e;
}

function heapPop() {
    const top = heap[0];
    const last = heap.pop();
    if (heap.length > 0) {
        let i = 0;
        for (;;) {
            let c = 2 * i + 1;
            if (c >= heap.length) break;
            if (c + 1 < heap.length && before(heap[c + 1], heap[c])) c++;
            if (!before(heap[c], last)) break;
            heap[i] = heap[c];
            i = c;
        }
        heap[i] = last;
    }
    return top;
}

function arm(now) {
    while (heap.length > 0 && !timers.has(heap[0].id)) heapPop();
    if (heap.length === 0) {
        if (armed !== 0) { bk.timerCancel(armed); armed = 0; }
        return;
    }
    const due = heap[0].due;
    if (armed !== 0) {
        if (due >= armedDue) return;
        bk.timerCancel(armed);
    }
    armedDue = due;
    armed = bk.timerStart(Math.max(1, Math.round(due - now)), 0);
}

bk.timerFire = function () {
    armed = 0;
    const now = bk.now();
    while (heap.length > 0 && heap[0].due <= now + 0.5) {
        const e = heapPop();
        const t = timers.get(e.id);
        if (t === undefined) continue;
        if (t.interval >= 0) {
            e.due = now + Math.max(t.interval, 1);
            heapPush(e);
        } else {
            timers.delete(e.id);
        }
        t.fn.apply(undefined, t.args);
    }
    arm(bk.now());
};

function addTimer(fn, ms, args, repeat) {
    if (typeof fn !== "function") throw new TypeError("callback must be a function");
    ms = +ms;
    if (!(ms >= 0)) ms = 0;
    const id = nextTimer++;
    const now = bk.now();
    timers.set(id, { fn, args, interval: repeat ? ms : -1 });
    heapPush({ id, due: now + Math.max(ms, 1) });
    arm(now);
    return id;
}

function clearTimer(id) {
    if (!timers.delete(id)) return;
    if (timers.size === 0) {
        heap.length = 0;
        arm(0);
    }
}

def("setTimeout", (fn, ms, ...args) => addTimer(fn, ms, args, false));
def("setInterval", (fn, ms, ...args) => addTimer(fn, ms, args, true));
def("clearTimeout", clearTimer);
def("clearInterval", clearTimer);
def("queueMicrotask", (fn) => { Promise.resolve().then(fn); });

const origin = bk.now();
def("performance", { now: () => bk.now() - origin, timeOrigin: Date.now() - (bk.now() - origin) });

// ---- crypto ----

def("crypto", {
    getRandomValues(a) {
        if (!ArrayBuffer.isView(a) || a instanceof Float32Array || a instanceof Float64Array) throw new TypeError("expected an integer TypedArray");
        if (a.byteLength > 65536) throw new DOMException("quota exceeded", "QuotaExceededError");
        bk.random(asBytes(a));
        return a;
    },
    randomUUID() {
        const b = new Uint8Array(16);
        bk.random(b);
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        let h = "";
        for (let i = 0; i < 16; i++) h += (b[i] < 16 ? "0" : "") + b[i].toString(16) + (i === 3 || i === 5 || i === 7 || i === 9 ? "-" : "");
        return h;
    },
});

def("structuredClone", (v) => v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

// ---- streams ----

class ReadableStreamDefaultController {
    constructor(stream) { this._stream = stream; }
    get desiredSize() { const s = this._stream; return s._state === "readable" ? s._hwm - s._queue.length : 0; }
    enqueue(chunk) {
        const s = this._stream;
        if (s._state !== "readable" || s._closeRequested) throw new TypeError("stream is not readable");
        if (s._reads.length) s._reads.shift().resolve({ value: chunk, done: false });
        else s._queue.push(chunk);
        s._pullIfNeeded();
    }
    close() {
        const s = this._stream;
        if (s._closeRequested || s._state !== "readable") throw new TypeError("stream is not readable");
        s._closeRequested = true;
        if (!s._queue.length) s._finish();
    }
    error(e) { this._stream._fail(e); }
}

class ReadableStream {
    constructor(source = {}, strategy = {}) {
        this._source = source;
        this._state = "readable";
        this._queue = [];
        this._reads = [];
        this._reader = null;
        this._error = undefined;
        this._closeRequested = false;
        this._pulling = false;
        this._repull = false;
        this._started = false;
        this._hwm = strategy.highWaterMark === undefined ? 1 : strategy.highWaterMark;
        this._controller = new ReadableStreamDefaultController(this);
        this._closed = null;
        const begun = () => { this._started = true; this._pullIfNeeded(); };
        if (!source.start) {
            queueMicrotask(begun);
            return;
        }
        Promise.resolve(source.start(this._controller)).then(begun, (e) => this._fail(e));
    }
    // The closed promise is rarely asked for, so it is made on demand.
    _closedPromise() {
        if (this._closed === null) {
            this._closed = Promise.withResolvers();
            this._closed.promise.catch(() => {});
            if (this._state === "closed") this._closed.resolve();
            else if (this._state === "errored") this._closed.reject(this._error);
        }
        return this._closed.promise;
    }
    get locked() { return this._reader !== null; }
    _pullIfNeeded() {
        if (!this._started || this._state !== "readable" || this._closeRequested || !this._source.pull) return;
        if (this._queue.length >= this._hwm && !this._reads.length) return;
        if (this._pulling) { this._repull = true; return; }
        this._pulling = true;
        let r;
        try { r = this._source.pull(this._controller); }
        catch (e) { this._pulling = false; this._fail(e); return; }
        if (r !== undefined && r !== null && typeof r.then === "function") {
            r.then(() => this._pullDone(), (e) => this._fail(e));
        } else {
            this._pullDone();
        }
    }
    _pullDone() {
        this._pulling = false;
        if (this._repull) { this._repull = false; this._pullIfNeeded(); }
    }
    _finish() {
        this._state = "closed";
        for (const r of this._reads) r.resolve({ value: undefined, done: true });
        this._reads = [];
        if (this._closed !== null) this._closed.resolve();
    }
    _fail(e) {
        if (this._state !== "readable") return;
        this._state = "errored";
        this._error = e;
        this._queue = [];
        for (const r of this._reads) r.reject(e);
        this._reads = [];
        if (this._closed !== null) this._closed.reject(e);
    }
    _takeQueued() {
        const value = this._queue.shift();
        if (this._closeRequested && !this._queue.length) this._finish();
        else this._pullIfNeeded();
        return value;
    }
    _read() {
        if (this._queue.length) return Promise.resolve({ value: this._takeQueued(), done: false });
        if (this._state === "closed") return Promise.resolve({ value: undefined, done: true });
        if (this._state === "errored") return Promise.reject(this._error);
        const p = Promise.withResolvers();
        this._reads.push(p);
        this._pullIfNeeded();
        return p.promise;
    }
    cancel(reason) {
        if (this._reader) return Promise.reject(new TypeError("stream is locked"));
        return this._cancel(reason);
    }
    _cancel(reason) {
        if (this._state === "closed") return Promise.resolve();
        if (this._state === "errored") return Promise.reject(this._error);
        this._queue = [];
        this._finish();
        return Promise.resolve(this._source.cancel ? this._source.cancel(reason) : undefined).then(() => {});
    }
    getReader(opts) {
        if (opts && opts.mode === "byob") throw new TypeError("byob readers are not supported");
        if (this._reader) throw new TypeError("stream is locked");
        return new ReadableStreamDefaultReader(this);
    }
    async *values({ preventCancel = false } = {}) {
        const reader = this.getReader();
        try {
            while (true) {
                const { value, done } = await reader.read();
                if (done) return;
                yield value;
            }
        } finally {
            if (!preventCancel) reader.cancel();
            reader.releaseLock();
        }
    }
    [Symbol.asyncIterator]() { return this.values(); }
    async pipeTo(dest, { preventClose = false, preventAbort = false, preventCancel = false, signal } = {}) {
        const reader = this.getReader();
        const writer = dest.getWriter();
        try {
            while (true) {
                if (signal && signal.aborted) throw signal.reason;
                const { value, done } = await reader.read();
                if (done) break;
                await writer.ready;
                await writer.write(value);
            }
            if (!preventClose) await writer.close();
        } catch (e) {
            if (!preventAbort) await writer.abort(e).catch(() => {});
            if (!preventCancel) await reader.cancel(e).catch(() => {});
            throw e;
        } finally {
            reader.releaseLock();
            writer.releaseLock();
        }
    }
    pipeThrough(pair, opts) {
        this.pipeTo(pair.writable, opts).catch(() => {});
        return pair.readable;
    }
    tee() {
        const reader = this.getReader();
        const branches = [];
        const pull = () => reader.read().then(({ value, done }) => {
            for (const b of branches) {
                if (b._state !== "readable") continue;
                if (done) b._controller.close(); else b._controller.enqueue(value);
            }
        });
        for (let i = 0; i < 2; i++) branches.push(new ReadableStream({ pull }));
        return branches;
    }
    static from(it) {
        if (it instanceof ReadableStream) return it;
        const iter = it[Symbol.asyncIterator] ? it[Symbol.asyncIterator]() : it[Symbol.iterator]();
        return new ReadableStream({
            async pull(c) {
                const { value, done } = await iter.next();
                if (done) c.close(); else c.enqueue(value);
            },
            cancel(r) { if (iter.return) return iter.return(r); },
        }, { highWaterMark: 0 });
    }
}

class ReadableStreamDefaultReader {
    constructor(stream) {
        if (stream._reader) throw new TypeError("stream is locked");
        this._stream = stream;
        stream._reader = this;
    }
    get closed() { return this._stream ? this._stream._closedPromise() : Promise.resolve(); }
    read() {
        if (!this._stream) return Promise.reject(new TypeError("reader released"));
        return this._stream._read();
    }
    cancel(reason) { return this._stream ? this._stream._cancel(reason) : Promise.resolve(); }
    releaseLock() {
        if (!this._stream) return;
        for (const r of this._stream._reads) r.reject(new TypeError("reader released"));
        this._stream._reads = [];
        this._stream._reader = null;
        this._stream = null;
    }
}

class WritableStream {
    constructor(sink = {}, strategy = {}) {
        this._sink = sink;
        this._state = "writable";
        this._writer = null;
        this._error = undefined;
        this._chain = Promise.resolve(sink.start ? sink.start(this._controller()) : undefined);
        this._chain.catch((e) => this._fail(e));
    }
    get locked() { return this._writer !== null; }
    _controller() { return { error: (e) => this._fail(e), signal: undefined }; }
    _fail(e) {
        if (this._state === "errored") return;
        this._state = "errored";
        this._error = e;
    }
    _queue(step) {
        const p = this._chain.then(() => {
            if (this._state === "errored") throw this._error;
            return step();
        });
        this._chain = p.catch((e) => { this._fail(e); });
        return p;
    }
    _write(chunk) {
        if (this._state !== "writable") return Promise.reject(this._error || new TypeError("stream is closed"));
        return this._queue(() => this._sink.write ? this._sink.write(chunk, this._controller()) : undefined);
    }
    _close() {
        if (this._state !== "writable") return Promise.reject(this._error || new TypeError("stream is closed"));
        this._state = "closing";
        return this._queue(() => this._sink.close ? this._sink.close() : undefined).then(() => { this._state = "closed"; });
    }
    _abort(reason) {
        this._fail(reason);
        return Promise.resolve(this._sink.abort ? this._sink.abort(reason) : undefined).then(() => {});
    }
    abort(reason) { return this._writer ? Promise.reject(new TypeError("stream is locked")) : this._abort(reason); }
    close() { return this._writer ? Promise.reject(new TypeError("stream is locked")) : this._close(); }
    getWriter() {
        if (this._writer) throw new TypeError("stream is locked");
        return this._writer = new WritableStreamDefaultWriter(this);
    }
}

class WritableStreamDefaultWriter {
    constructor(stream) { this._stream = stream; }
    get ready() { return this._stream ? this._stream._chain : Promise.reject(new TypeError("writer released")); }
    get closed() { return this._stream ? this._stream._chain.then(() => { if (this._stream && this._stream._state === "errored") throw this._stream._error; }) : Promise.resolve(); }
    get desiredSize() { return this._stream && this._stream._state === "writable" ? 1 : 0; }
    write(chunk) { return this._stream ? this._stream._write(chunk) : Promise.reject(new TypeError("writer released")); }
    close() { return this._stream ? this._stream._close() : Promise.reject(new TypeError("writer released")); }
    abort(reason) { return this._stream ? this._stream._abort(reason) : Promise.resolve(); }
    releaseLock() { if (this._stream) { this._stream._writer = null; this._stream = null; } }
}

class TransformStream {
    constructor(t = {}) {
        let rc;
        this.readable = new ReadableStream({ start(c) { rc = c; } }, { highWaterMark: Infinity });
        const controller = {
            enqueue: (c) => rc.enqueue(c),
            error: (e) => rc.error(e),
            terminate: () => rc.close(),
            get desiredSize() { return rc.desiredSize; },
        };
        if (t.start) t.start(controller);
        this.writable = new WritableStream({
            write: (chunk) => t.transform ? t.transform(chunk, controller) : controller.enqueue(chunk),
            close: async () => { if (t.flush) await t.flush(controller); rc.close(); },
            abort: (e) => rc.error(e),
        });
    }
}

class TextEncoderStream extends TransformStream {
    constructor() { const e = new TextEncoder(); super({ transform: (s, c) => c.enqueue(e.encode(s)) }); }
}

class TextDecoderStream extends TransformStream {
    constructor() {
        let rest = new Uint8Array(0);
        super({
            transform(chunk, c) {
                const b = concat([rest, asBytes(chunk)]);
                let end = b.length;
                for (let i = Math.max(0, end - 3); i < end; i++) {
                    const x = b[i];
                    const need = x >= 0xF0 ? 4 : x >= 0xE0 ? 3 : x >= 0xC0 ? 2 : 1;
                    if (i + need > end) { end = i; break; }
                }
                rest = b.slice(end);
                if (end) c.enqueue(bk.decode(b.subarray(0, end), false));
            },
            flush(c) { if (rest.length) c.enqueue(bk.decode(rest, false)); },
        });
    }
}

def("ReadableStream", ReadableStream);
def("ReadableStreamDefaultReader", ReadableStreamDefaultReader);
def("WritableStream", WritableStream);
def("WritableStreamDefaultWriter", WritableStreamDefaultWriter);
def("TransformStream", TransformStream);
def("TextEncoderStream", TextEncoderStream);
def("TextDecoderStream", TextDecoderStream);

function concat(chunks) {
    let n = 0;
    for (const c of chunks) n += c.length;
    const out = new Uint8Array(n);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
}
bk.concat = concat;

async function readAll(stream) {
    const chunks = [];
    for await (const c of stream) chunks.push(typeof c === "string" ? bk.encode(c) : asBytes(c));
    return concat(chunks);
}
bk.readAll = readAll;

// ---- Blob ----

class Blob {
    constructor(parts = [], opts = {}) {
        const chunks = [];
        for (const p of parts) {
            if (typeof p === "string") chunks.push(bk.encode(p));
            else if (p instanceof Blob) chunks.push(p._bytes);
            else chunks.push(asBytes(p).slice());
        }
        this._bytes = concat(chunks);
        this.type = opts.type ? String(opts.type).toLowerCase() : "";
    }
    get size() { return this._bytes.length; }
    slice(start = 0, end = this.size, type = "") {
        const b = new Blob([], { type });
        b._bytes = this._bytes.slice(start, end);
        return b;
    }
    text() { return Promise.resolve(bk.decode(this._bytes, false)); }
    bytes() { return Promise.resolve(this._bytes.slice()); }
    arrayBuffer() { return Promise.resolve(this._bytes.slice().buffer); }
    stream() { return bytesStream(this._bytes); }
}

class File extends Blob {
    constructor(parts, name, opts = {}) {
        super(parts, opts);
        this.name = String(name);
        this.lastModified = opts.lastModified === undefined ? Date.now() : opts.lastModified;
    }
}

def("Blob", Blob);
def("File", File);

function bytesStream(bytes) {
    return new ReadableStream({ start(c) { if (bytes.length) c.enqueue(bytes); c.close(); } });
}

// ---- URLSearchParams / URL ----

function formDecode(s) {
    s = s.replace(/\+/g, " ");
    try { return decodeURIComponent(s); } catch (e) { return s; }
}

const formEncode = (s) => encodeURIComponent(s).replace(/%20/g, "+");

class URLSearchParams {
    constructor(init) {
        this._list = [];
        this._url = null;
        if (init === undefined || init === null) return;
        if (init instanceof URLSearchParams) {
            for (const p of init._list) this._list.push([p[0], p[1]]);
        } else if (typeof init === "object" && typeof init[Symbol.iterator] === "function") {
            for (const e of init) this._list.push([String(e[0]), String(e[1])]);
        } else if (typeof init === "object") {
            for (const k of Object.keys(init)) this._list.push([k, String(init[k])]);
        } else {
            this._parse(String(init));
        }
    }
    _parse(s) {
        this._list = [];
        if (s.charAt(0) === "?") s = s.slice(1);
        if (s === "") return;
        for (const part of s.split("&")) {
            if (part === "") continue;
            const eq = part.indexOf("=");
            if (eq < 0) this._list.push([formDecode(part), ""]);
            else this._list.push([formDecode(part.slice(0, eq)), formDecode(part.slice(eq + 1))]);
        }
    }
    _update() { if (this._url) this._url._setSearch(this.toString()); }
    get size() { return this._list.length; }
    append(k, v) { this._list.push([String(k), String(v)]); this._update(); }
    delete(k) { k = String(k); this._list = this._list.filter((p) => p[0] !== k); this._update(); }
    get(k) { k = String(k); for (const p of this._list) if (p[0] === k) return p[1]; return null; }
    getAll(k) { k = String(k); return this._list.filter((p) => p[0] === k).map((p) => p[1]); }
    has(k) { k = String(k); return this._list.some((p) => p[0] === k); }
    set(k, v) {
        k = String(k); v = String(v);
        const out = [];
        let done = false;
        for (const p of this._list) {
            if (p[0] !== k) out.push(p);
            else if (!done) { out.push([k, v]); done = true; }
        }
        if (!done) out.push([k, v]);
        this._list = out;
        this._update();
    }
    sort() { this._list.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); this._update(); }
    forEach(fn, self) { for (const p of this._list) fn.call(self, p[1], p[0], this); }
    keys() { return this._list.map((p) => p[0])[Symbol.iterator](); }
    values() { return this._list.map((p) => p[1])[Symbol.iterator](); }
    entries() { return this._list.map((p) => [p[0], p[1]])[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
    toString() { return this._list.map((p) => formEncode(p[0]) + "=" + formEncode(p[1])).join("&"); }
}

// indexOf beats a character loop here, and covers every request URL; the
// regex takes anything unusual.
function urlSplit(u) {
    const se = u.indexOf("://");
    if (se <= 0 || se >= 10) return URL_RE.exec(u);
    const a = se + 3;
    const h = u.indexOf("#", a);
    const end = h < 0 ? u.length : h;
    let q = u.indexOf("?", a);
    if (q > end) q = -1;
    const stop = q < 0 ? end : q;
    let p = u.indexOf("/", a);
    if (p < 0 || p > stop) p = stop;
    return [u, u.slice(0, se + 1), u.slice(a, p), u.slice(p, stop),
            q < 0 ? undefined : u.slice(q, end), h < 0 ? undefined : u.slice(h)];
}

const URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/;
const OPAQUE_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)([^?#]*)(\?[^#]*)?(#.*)?$/;

function normalizePath(p) {
    if (p.indexOf(".") < 0) return p;
    const segs = p.split("/"), out = [];
    for (let i = 0; i < segs.length; i++) {
        const s = segs[i];
        if (s === ".." || s === "%2e%2e") { if (out.length > 1) out.pop(); if (i === segs.length - 1) out.push(""); }
        else if (s === "." || s === "%2e") { if (i === segs.length - 1) out.push(""); }
        else out.push(s);
    }
    const r = out.join("/");
    return r.charAt(0) === "/" ? r : "/" + r;
}

const DEFAULT_PORTS = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443" };

class URL {
    _expand() {
        const url = this._raw;
        const f = this._f;
        this._raw = null;
        const slash = f % 65536;
        const query = Math.floor(f / 65536) % 65536;
        const colon = Math.floor(f / 4294967296);
        const https = url.charCodeAt(4) === 115;
        const lead = https ? 8 : 7;
        const port = colon === 65535 ? "" : url.slice(colon + 1, slash);
        this._protocol = https ? "https:" : "http:";
        this._hostname = url.slice(lead, colon === 65535 ? slash : colon);
        this._port = port === (https ? "443" : "80") ? "" : port;
        this._pathname = slash === url.length ? "/" : query === 65535 ? url.slice(slash) : url.slice(slash, query);
        this._search = query === 65535 || query === url.length - 1 ? "" : url.slice(query);
    }
    constructor(url, base) {
        url = String(url);
        // Plain http(s) URLs, the server's common case, skip the general split.
        const f = bk.urlFast(url);
        if (f >= 0) {
            // Fields are cut from the string only when one is read.
            this._raw = url;
            this._f = f;
            return;
        }
        url = url.trim();
        let m = urlSplit(url);
        if (!m && base !== undefined) {
            const b = base instanceof URL ? base : new URL(String(base));
            if (url.startsWith("//")) m = urlSplit(b.protocol + url);
            else if (url.charAt(0) === "/") m = urlSplit(b.origin + url);
            else if (url.charAt(0) === "?") m = urlSplit(b.origin + b.pathname + url);
            else if (url.charAt(0) === "#") m = urlSplit(b.origin + b.pathname + b.search + url);
            else if (url === "") m = urlSplit(b.origin + b.pathname + b.search);
            else m = urlSplit(b.origin + b.pathname.slice(0, b.pathname.lastIndexOf("/") + 1) + url);
        }
        if (!m) {
            const o = OPAQUE_RE.exec(url);
            if (!o) throw new TypeError("Invalid URL: " + url);
            this._protocol = o[1].toLowerCase();
            this._username = this._password = this._hostname = this._port = "";
            this._pathname = o[2];
            this._search = o[3] && o[3] !== "?" ? o[3] : "";
            this._hash = o[4] && o[4] !== "#" ? o[4] : "";
            this._params = null;
            this._opaque = true;
            return;
        }
        this._protocol = m[1] === "http:" || m[1] === "https:" ? m[1] : m[1].toLowerCase();
        let host = m[2];
        const at = host.lastIndexOf("@");
        this._username = "";
        this._password = "";
        if (at >= 0) {
            const cred = host.slice(0, at);
            host = host.slice(at + 1);
            const c = cred.indexOf(":");
            if (c < 0) this._username = cred;
            else { this._username = cred.slice(0, c); this._password = cred.slice(c + 1); }
        }
        const colon = host.lastIndexOf(":");
        if (colon >= 0 && host.indexOf("]", colon) < 0) {
            this._hostname = host.slice(0, colon).toLowerCase();
            this._port = host.slice(colon + 1);
            if (!/^\d*$/.test(this._port)) throw new TypeError("Invalid URL: " + url);
        } else {
            this._hostname = host.toLowerCase();
            this._port = "";
        }
        if (DEFAULT_PORTS[this._protocol] === this._port) this._port = "";
        if (this._hostname === "" && (this._protocol === "http:" || this._protocol === "https:")) throw new TypeError("Invalid URL: " + url);
        this._pathname = normalizePath(m[3] || "/");
        this._search = m[4] && m[4] !== "?" ? m[4] : "";
        this._hash = m[5] && m[5] !== "#" ? m[5] : "";
        this._params = null;
    }
    get protocol() { if (this._raw !== null) this._expand(); return this._protocol; }
    set protocol(v) { if (this._raw !== null) this._expand(); this._protocol = String(v); }
    get username() { if (this._raw !== null) this._expand(); return this._username; }
    set username(v) { if (this._raw !== null) this._expand(); this._username = String(v); }
    get password() { if (this._raw !== null) this._expand(); return this._password; }
    set password(v) { if (this._raw !== null) this._expand(); this._password = String(v); }
    get hostname() { if (this._raw !== null) this._expand(); return this._hostname; }
    set hostname(v) { if (this._raw !== null) this._expand(); this._hostname = String(v); }
    get port() { if (this._raw !== null) this._expand(); return this._port; }
    set port(v) { if (this._raw !== null) this._expand(); this._port = String(v); }
    get pathname() {
        const url = this._raw;
        if (url === null) return this._pathname;
        const lo = this._f % 4294967296;
        const slash = lo & 65535;
        const query = lo >>> 16;
        return slash === url.length ? "/" : query === 65535 ? url.slice(slash) : url.slice(slash, query);
    }
    set pathname(v) { if (this._raw !== null) this._expand(); this._pathname = String(v); }
    get hash() { if (this._raw !== null) this._expand(); return this._hash; }
    set hash(v) { if (this._raw !== null) this._expand(); this._hash = String(v); }
    get host() { return this.port ? this.hostname + ":" + this.port : this.hostname; }
    get origin() { return this._opaque || this.protocol === "file:" ? "null" : this.protocol + "//" + this.host; }
    get search() { if (this._raw !== null) this._expand(); return this._search; }
    set search(s) {
        if (this._raw !== null) this._expand();
        s = String(s);
        if (s !== "" && s.charAt(0) !== "?") s = "?" + s;
        this._search = s === "?" ? "" : s;
        if (this._params) this._params._parse(this._search);
    }
    _setSearch(qs) {
        if (this._raw !== null) this._expand();
        this._search = qs ? "?" + qs : "";
    }
    get searchParams() {
        if (!this._params) { this._params = new URLSearchParams(this.search); this._params._url = this; }
        return this._params;
    }
    get href() {
        if (this._opaque) return this.protocol + this.pathname + this._search + this.hash;
        const auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
        return this.protocol + "//" + auth + this.host + this.pathname + this._search + this.hash;
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
    static canParse(u, b) { try { new URL(u, b); return true; } catch (e) { return false; } }
    static parse(u, b) { try { return new URL(u, b); } catch (e) { return null; } }
}

protoDefaults(URL, { _raw: null, _f: 0, _protocol: "", _username: "", _password: "", _hostname: "", _port: "", _pathname: "", _search: "", _hash: "", _params: null, _opaque: false });
def("URL", URL);
def("URLSearchParams", URLSearchParams);

// ---- Headers ----

class Headers {
    constructor(init) {
        this._map = new Map();
        this._cookies = null;
        if (init === INTERNAL || init === undefined || init === null) return;
        if (init instanceof Headers) {
            for (const e of init._map) this._map.set(e[0], e[1]);
            if (init._cookies) this._cookies = init._cookies.slice();
        } else if (typeof init[Symbol.iterator] === "function") {
            for (const p of init) this.append(p[0], p[1]);
        } else {
            for (const k of Object.keys(init)) {
                const name = k.toLowerCase();
                if (name === "set-cookie") this.append(k, init[k]);
                else this._map.set(name, String(init[k]).trim());
            }
        }
    }
    // Set-Cookie is the one header never joined with commas.
    append(k, v) {
        k = String(k).toLowerCase();
        v = String(v).trim();
        if (k === "set-cookie") { (this._cookies || (this._cookies = [])).push(v); return; }
        const cur = this._map.get(k);
        this._map.set(k, cur === undefined ? v : cur + ", " + v);
    }
    set(k, v) {
        k = String(k).toLowerCase();
        v = String(v).trim();
        if (k === "set-cookie") { this._cookies = [v]; return; }
        this._map.set(k, v);
    }
    get(k) {
        k = String(k).toLowerCase();
        if (k === "set-cookie") return this._cookies ? this._cookies.join(", ") : null;
        const v = this._map.get(k);
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
    forEach(fn, self) { for (const e of this.entries()) fn.call(self, e[1], e[0], this); }
    *entries() {
        const keys = Array.from(this._map.keys());
        if (this._cookies) keys.push("set-cookie");
        keys.sort();
        for (const k of keys) {
            if (k === "set-cookie") { for (const c of this._cookies) yield [k, c]; }
            else yield [k, this._map.get(k)];
        }
    }
    *keys() { for (const e of this.entries()) yield e[0]; }
    *values() { for (const e of this.entries()) yield e[1]; }
    [Symbol.iterator]() { return this.entries(); }
    toJSON() { const o = {}; for (const e of this.entries()) o[e[0]] = e[1]; return o; }
    _blob() {
        let s = "";
        for (const e of this._map) s += e[0] + "\n" + e[1] + "\n";
        if (this._cookies) for (const c of this._cookies) s += "set-cookie\n" + c + "\n";
        return s;
    }
    _wire() {
        let s = "";
        for (const e of this._map) s += e[0] + ": " + e[1] + "\r\n";
        if (this._cookies) for (const c of this._cookies) s += "set-cookie: " + c + "\r\n";
        return s;
    }
    static _fromBlob(blob) {
        const h = new Headers(INTERNAL);
        if (blob === "") return h;
        const parts = blob.split("\n");
        for (let i = 0; i + 1 < parts.length; i += 2) h.append(parts[i], parts[i + 1]);
        return h;
    }
}
hidden(Headers, { INTERNAL });
def("Headers", Headers);

// ---- bodies ----

// A body is held as given -- null, a string, bytes or a ReadableStream --
// and converted only when read, so a string handler's string reaches the
// wire untouched.
function bodyInit(body, headers) {
    if (body === undefined || body === null) return null;
    const ct = (t) => { if (!headers.has("content-type")) headers.set("content-type", t); };
    if (typeof body === "string") { ct("text/plain;charset=UTF-8"); return body; }
    if (body instanceof Uint8Array) return body;
    if (body instanceof ReadableStream) return body;
    if (body instanceof URLSearchParams) { ct("application/x-www-form-urlencoded;charset=UTF-8"); return body.toString(); }
    if (body instanceof Blob) { if (body.type) ct(body.type); return body._bytes; }
    if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return asBytes(body).slice();
    if (body instanceof Request || body instanceof Response) return body._body;
    if (typeof body[Symbol.asyncIterator] === "function") return ReadableStream.from(body);
    ct("text/plain;charset=UTF-8");
    return String(body);
}

function bodyStream(b) {
    if (b === null || b instanceof ReadableStream) return b;
    return bytesStream(typeof b === "string" ? bk.encode(b) : b);
}

const BodyMixin = {
    get body() {
        if (this._body !== null && !(this._body instanceof ReadableStream)) this._body = bodyStream(this._body);
        return this._body;
    },
    get bodyUsed() { return this._used; },
    _take() {
        if (this._used) return Promise.reject(new TypeError("Body already used"));
        this._used = true;
        return Promise.resolve(this._body);
    },
    text() {
        return this._take().then((b) => b === null ? "" : typeof b === "string" ? b
            : b instanceof ReadableStream ? readAll(b).then((u) => bk.decode(u, false)) : bk.decode(b, false));
    },
    bytes() {
        return this._take().then((b) => b === null ? new Uint8Array(0) : typeof b === "string" ? bk.encode(b)
            : b instanceof ReadableStream ? readAll(b) : b);
    },
    json() { return this.text().then(JSON.parse); },
    arrayBuffer() { return this.bytes().then((u) => u.byteOffset === 0 && u.byteLength === u.buffer.byteLength ? u.buffer : u.slice().buffer); },
    blob() {
        const type = this.headers.get("content-type") || "";
        return this.bytes().then((u) => new Blob([u], { type }));
    },
    formData() { return Promise.reject(new TypeError("formData() is not supported")); },
};

function mixBody(cls) {
    for (const k of Object.getOwnPropertyNames(BodyMixin))
        Object.defineProperty(cls.prototype, k, Object.getOwnPropertyDescriptor(BodyMixin, k));
}

// Defaults on the prototype: an own property per constructor call costs a
// shape transition, which on the request path is most of building one.
function protoDefaults(cls, d) {
    for (const k of Object.keys(d))
        Object.defineProperty(cls.prototype, k, { value: d[k], writable: true, configurable: true });
}

// ---- Request ----

class Request {
    constructor(input, init, id, body) {
        if (input === INTERNAL) {
            // From the server: the URL and headers come from C3 only if read.
            this.method = init;
            this._id = id;
            if (body !== undefined) this._body = body;
            return;
        }
        init = init || {};
        const src = input instanceof Request ? input : null;
        this._url = src ? src.url : new URL(String(input)).href;
        this.method = String(init.method || (src ? src.method : "GET")).toUpperCase();
        this._headers = new Headers(init.headers !== undefined ? init.headers : src ? src.headers : undefined);
        this._body = init.body !== undefined && init.body !== null ? bodyInit(init.body, this._headers) : src ? src._body : null;
        if (this._body !== null && (this.method === "GET" || this.method === "HEAD")) throw new TypeError("GET/HEAD requests cannot have a body");
        this.redirect = init.redirect || (src ? src.redirect : "follow");
        if (init.signal) this._signal = init.signal;
        else if (src) this._signal = src._signal;
    }
    get url() {
        if (this._url === null) this._url = bk.reqUrl(this._id);
        return this._url;
    }
    get headers() {
        if (this._headers === null) this._headers = Headers._fromBlob(bk.reqHeaders(this._id));
        return this._headers;
    }
    get signal() { return this._signal || (this._signal = new AbortController().signal); }
    clone() {
        if (this._used) throw new TypeError("Body already used");
        if (this._body instanceof ReadableStream) {
            const [a, b] = this._body.tee();
            this._body = a;
            return new Request(this, { body: b });
        }
        return new Request(this);
    }
}
mixBody(Request);
protoDefaults(Request, { _id: 0, _url: null, _headers: null, _body: null, _used: false, _signal: null, redirect: "follow" });
def("Request", Request);

// ---- Response ----

const STATUS_TEXT = {
    100: "Continue", 101: "Switching Protocols",
    200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
    301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
    307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
    405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
    411: "Length Required", 413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
    416: "Range Not Satisfiable", 418: "I'm a teapot", 422: "Unprocessable Content", 429: "Too Many Requests",
    500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
    503: "Service Unavailable", 504: "Gateway Timeout",
};

const CT_TEXT = "text/plain;charset=UTF-8";
const BLOB_TEXT = "content-type\n" + CT_TEXT + "\n";
const CT_JSON = "application/json";
const BLOB_JSON = "content-type\n" + CT_JSON + "\n";

// The common Response is a string with no init: it keeps the implied
// content-type as a constant blob and never builds a Headers.
class Response {
    constructor(body, init) {
        if (init === undefined && (body instanceof Uint8Array || body instanceof ReadableStream)) {
            this._ct = null;
            this._body = body;
            return;
        }
        if (typeof body === "string" && init === undefined) {
            this._body = body;
            return;
        }
        if (init !== undefined && init !== null) {
            const status = init.status === undefined ? 200 : init.status | 0;
            if (status < 200 || status > 599) throw new RangeError("Invalid status: " + init.status);
            this.status = status;
            if (init.statusText !== undefined) this._statusText = String(init.statusText);
            if (init.headers !== undefined) this._headers = init.headers instanceof Headers && init[INTERNAL] ? init.headers : new Headers(init.headers);
        }
        if (typeof body === "string" && this._headers === null) {
            this._body = body;
        } else {
            this._ct = null;
            if (body !== undefined && body !== null) this._body = bodyInit(body, this.headers);
        }
    }
    get headers() {
        if (this._headers === null) {
            this._headers = new Headers(INTERNAL);
            if (this._ct !== null) this._headers.set("content-type", this._ct);
        }
        return this._headers;
    }
    get statusText() { return this._statusText !== null ? this._statusText : (STATUS_TEXT[this.status] || ""); }
    get ok() { return this.status >= 200 && this.status < 300; }
    _blob() {
        if (this._headers !== null) return this._headers._blob();
        return this._ct === CT_TEXT ? BLOB_TEXT : this._ct === CT_JSON ? BLOB_JSON : "";
    }
    clone() {
        if (this._used) throw new TypeError("Body already used");
        const r = new Response(null, { status: this.status, statusText: this._statusText === null ? undefined : this._statusText, headers: this.headers });
        if (this._body instanceof ReadableStream) {
            const [a, b] = this._body.tee();
            this._body = a;
            r._body = b;
        } else {
            r._body = this._body;
        }
        r.url = this.url;
        r.type = this.type;
        return r;
    }
    static json(data, init) {
        if (init === undefined) {
            const r = new Response(null);
            r._ct = CT_JSON;
            r._body = JSON.stringify(data);
            return r;
        }
        const h = new Headers(init.headers);
        if (!h.has("content-type")) h.set("content-type", "application/json");
        return new Response(JSON.stringify(data), { status: init.status, statusText: init.statusText, headers: h, [INTERNAL]: true });
    }
    static redirect(url, status = 302) {
        if ([301, 302, 303, 307, 308].indexOf(status) < 0) throw new RangeError("Invalid redirect status: " + status);
        const h = new Headers(INTERNAL);
        h.set("location", new URL(String(url)).href);
        return new Response(null, { status, headers: h, [INTERNAL]: true });
    }
    static error() {
        const r = new Response(null, { status: 500 });
        r.type = "error";
        r.status = 0;
        return r;
    }
}
mixBody(Response);
protoDefaults(Response, { status: 200, type: "default", url: "", redirected: false, _used: false,
                          _statusText: null, _headers: null, _ct: CT_TEXT, _body: null });
def("Response", Response);

// ---- server dispatch ----

const handlers = [];

bk.addHandler = function (h) {
    handlers.push(h);
    return handlers.length - 1;
};

function report(e) { console.error(e && e.stack ? e.stack : String(e)); }

function fail(id, e, h) {
    if (h && h.error) {
        let r;
        try { r = h.error(e); } catch (e2) { r = undefined; report(e2); }
        if (r instanceof Response) { send(id, r); return; }
        if (r !== undefined) { Promise.resolve(r).then((res) => res instanceof Response ? send(id, res) : fail(id, e), (e2) => fail(id, e2)); return; }
    }
    report(e);
    bk.respond(id, 500, "Internal Server Error", BLOB_TEXT, "Internal Server Error");
}

const streams = new Map();

bk.drain = function (id) {
    const s = streams.get(id);
    if (s && s.wake) { const w = s.wake; s.wake = null; w(); }
};

bk.aborted = function (id) {
    const s = streams.get(id);
    if (!s) return;
    s.aborted = true;
    if (s.wake) { const w = s.wake; s.wake = null; w(); }
};

const BATCH = 65536;
const encoder = new TextEncoder();

function joinChunks(parts, size) {
    const out = new Uint8Array(size);
    let at = 0;
    for (const p of parts) {
        out.set(p, at);
        at += p.length;
    }
    return out;
}

// A stream nobody else touched is driven straight from its source: pull
// feeds a local batch instead of the stream's queue and promises.
function directSource(stream) {
    const src = stream._source;
    return stream._reader === null && stream._state === "readable" && stream._queue.length === 0 && !src.start && typeof src.pull === "function";
}

const isThenable = (r) => r !== undefined && r !== null && typeof r.then === "function";

// Stands in for the stream controller while a direct source is pumped.
class Sink {
    constructor() {
        this.parts = [];
        this.size = 0;
        this.closed = false;
        this.failed = null;
        this.nudge = null;
    }
    get desiredSize() { return 1; }
    enqueue(value) {
        const chunk = typeof value === "string" ? encoder.encode(value) : asBytes(value);
        this.parts.push(chunk);
        this.size += chunk.length;
        this._wake();
    }
    close() { this.closed = true; this._wake(); }
    error(e) { this.failed = e; this.closed = true; this._wake(); }
    _wake() {
        if (this.nudge === null) return;
        const n = this.nudge;
        this.nudge = null;
        n();
    }
    take() {
        const out = this.parts.length === 1 ? this.parts[0] : joinChunks(this.parts, this.size);
        this.parts = [];
        this.size = 0;
        return out;
    }
}

function pump(id, res) {
    const stream = res._body;
    bk.streamStart(id, res.status, res.status === 200 ? "" : res.statusText, res._blob());
    if (!directSource(stream)) { pumpQueued(id, stream); return; }
    stream._reader = stream;
    const src = stream._source;
    const sink = new Sink();
    // Chunks that arrive together go out as one write; a source that
    // produces synchronously never leaves this loop or makes a promise.
    try {
        while (!sink.closed && sink.size < BATCH) {
            const r = src.pull(sink);
            if (isThenable(r)) { pumpSource(id, stream, sink, r); return; }
        }
        if (sink.failed === null && sink.parts.length > 0 && !sink.closed) { pumpSource(id, stream, sink, undefined); return; }
        if (sink.failed === null && sink.parts.length > 0) bk.streamWrite(id, sink.take());
    } catch (e) {
        report(e);
        bk.streamEnd(id);
        return;
    }
    if (sink.failed !== null) report(sink.failed);
    stream._state = "closed";
    bk.streamEnd(id);
}

// The general case: pulls that take time, big or endless sources, or a peer that is slow to read.
async function pumpSource(id, stream, sink, waiting) {
    const s = { wake: null, aborted: false };
    streams.set(id, s);
    const src = stream._source;
    try {
        for (;;) {
            if (waiting !== undefined) await waiting;
            waiting = undefined;
            if (s.aborted) break;
            if (sink.parts.length === 0 && !sink.closed) await new Promise((r) => { sink.nudge = r; });
            if (sink.parts.length > 0) {
                if (!bk.streamWrite(id, sink.take()) && !s.aborted) await new Promise((r) => { s.wake = r; });
            }
            if (sink.closed || s.aborted) break;
            waiting = src.pull(sink);
            if (!isThenable(waiting)) waiting = undefined;
        }
        if (sink.failed !== null) throw sink.failed;
        if (s.aborted && src.cancel) src.cancel();
        stream._state = "closed";
    } catch (e) {
        report(e);
    } finally {
        streams.delete(id);
        bk.streamEnd(id);
    }
}

async function pumpQueued(id, stream) {
    const s = { wake: null, aborted: false };
    streams.set(id, s);
    const reader = stream.getReader();
    const parts = [];
    try {
        while (!s.aborted) {
            let size = 0;
            while (stream._queue.length && size < BATCH) {
                const value = stream._takeQueued();
                const chunk = typeof value === "string" ? encoder.encode(value) : asBytes(value);
                parts.push(chunk);
                size += chunk.length;
            }
            if (parts.length === 0) {
                if (stream._state === "closed") break;
                const r = await reader.read();
                if (r.done) break;
                const chunk = typeof r.value === "string" ? encoder.encode(r.value) : asBytes(r.value);
                parts.push(chunk);
                size = chunk.length;
            }
            const out = parts.length === 1 ? parts[0] : joinChunks(parts, size);
            parts.length = 0;
            if (!bk.streamWrite(id, out) && !s.aborted) await new Promise((r) => { s.wake = r; });
        }
        if (s.aborted) reader.cancel();
    } catch (e) {
        report(e);
    } finally {
        streams.delete(id);
        bk.streamEnd(id);
    }
}

function send(id, res) {
    if (!(res instanceof Response)) {
        fail(id, new TypeError("fetch handler must return a Response, got " + typeof res));
        return;
    }
    res._used = true;
    const st = res.status;
    const b = res._body;
    if (b instanceof ReadableStream) { pump(id, res); return; }
    bk.respond(id, st, st === 200 ? "" : res.statusText, res._blob(), b === null ? "" : b);
}

bk.dispatch = function (index, id, method, body) {
    const h = handlers[index];
    const req = new Request(INTERNAL, method, id, body);
    let r;
    try { r = h.fetch(req, h.server); }
    catch (e) { fail(id, e, h); return; }
    if (r instanceof Response) {
        r._used = true;
        const st = r.status;
        const b = r._body;
        if (typeof b === "string") { bk.respond(id, st, st === 200 ? "" : r.statusText, r._blob(), b); return; }
        send(id, r);
        return;
    }
    Promise.resolve(r).then((res) => send(id, res), (e) => fail(id, e, h));
};

// ---- resource handles ----

bk.Handle = class Handle {
    #rid;
    #readable = null;
    #writable = null;
    constructor(rid) {
        this.#rid = rid;
    }
    get readable() {
        return this.#readable ??= new ReadableStream({
            pull: async (c) => {
                const chunk = await bk.op(bk.read, this.#rid);
                if (chunk === null) c.close();
                else c.enqueue(chunk);
            },
            cancel: () => this.close(),
        });
    }
    get writable() {
        return this.#writable ??= new WritableStream({
            write: (chunk) => bk.op(bk.write, this.#rid, chunk),
            close: () => this.closeWrite(),
            abort: () => this.close(),
        });
    }
    get rid() { return this.#rid; }
    read() { return bk.op(bk.read, this.#rid); }
    write(data) {
        if (typeof data === "string") data = new TextEncoder().encode(data);
        return bk.op(bk.write, this.#rid, data);
    }
    closeWrite() { this.close(); }
    close() { bk.close(this.#rid); }
};

})(__bk);
