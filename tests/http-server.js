import { serve } from "http";
import * as file from "file";
import { args } from "process";
const [port, payload] = args;
let saved;
let canceled = 0;
let later;
let failedStream;
let streamClassifications = 0;
const enc = new TextEncoder();
const stream = (source, strategy) => new Response(new ReadableStream(source, strategy));
serve({ port: Number(port), hostname: "127.0.0.1", onListen() {},
    error(e) { return new Response(e.code || e.message, { status: 500 }); },
    fetch(req) {
        // Retain an entirely unread Request to test URL and header lifetimes.
        if (req.method === "PUT") { saved = req; return new Response("saved"); }
        const path = new URL(req.url).pathname;
        if (path === "/inspect") return new Response(JSON.stringify({ url: saved.url, header: saved.headers.get("x-test") }));
        if (path === "/stream-error") {
            failedStream = new ReadableStream({ pull(c) { c.error(null); } }, { highWaterMark: 0 });
            return new Response(failedStream);
        }
        if (path === "/stream-error-state") return new Response(failedStream._state);
        if (path === "/stream-short") {
            let n = 0;
            return stream({ pull(c) { if (n++ === 8) c.close(); else c.enqueue(enc.encode("x".repeat(1024))); } });
        }
        if (path === "/stream-direct-promise" || path === "/stream-direct-subclass" || path === "/stream-direct-custom") {
            const body = new ReadableStream({ pull(c) { c.enqueue(enc.encode("direct")); c.close(); } });
            if (path === "/stream-direct-subclass") {
                class Derived extends Response {}
                return new Derived(body);
            }
            if (path === "/stream-direct-custom") return new Response(body, { status: 201, headers: { "x-stream": "yes" } });
            return new Promise(resolve => setImmediate(() => resolve(new Response(body))));
        }
        if (path === "/stream-classification-guard") {
            const response = stream({ pull(c) { c.enqueue(enc.encode("guard")); c.close(); } });
            const intrinsic = Function.prototype[Symbol.hasInstance];
            Object.defineProperty(ReadableStream, Symbol.hasInstance, {
                configurable: true, get() {
                    streamClassifications++;
                    return function (value) { return intrinsic.call(this, value); };
                }
            });
            return response;
        }
        if (path === "/stream-classification-count") {
            delete ReadableStream[Symbol.hasInstance];
            return new Response(String(streamClassifications));
        }
        if (path === "/stream-native-guards") return stream({ pull(c) {
            const check = (ok, message) => { if (!ok) throw new Error(message); };
            const byte = new Uint8Array([65]);
            c.enqueue(byte); c.enqueue(byte);
            const originalPush = Array.prototype.push;
            let pushes = 0;
            Array.prototype.push = function (value) { pushes++; return originalPush.call(this, value); };
            try { c.enqueue(byte); check(pushes === 1, "replaced push bypassed"); }
            finally { Array.prototype.push = originalPush; }
            let lengths = 0;
            const taProto = Object.getPrototypeOf(Uint8Array.prototype);
            const descriptor = Object.getOwnPropertyDescriptor(taProto, "length");
            Object.defineProperty(taProto, "length", { ...descriptor, get() { lengths++; return 1; } });
            try { c.enqueue(byte); check(lengths === 1, "replaced length getter bypassed"); }
            finally { Object.defineProperty(taProto, "length", descriptor); }
            let count = c.size, reads = 0, writes = 0;
            Object.defineProperty(c, "size", { configurable: true, get() { reads++; return count; }, set(v) { writes++; count = v; } });
            c.enqueue(byte);
            check(reads === 1 && writes === 1, "controller accessor bypassed");
            Object.defineProperty(c, "size", { value: count, writable: true, configurable: true, enumerable: true });
            let nudges = 0;
            c.nudge = () => nudges++;
            c.enqueue(byte);
            check(nudges === 1 && c.nudge === null, "wake callback lost");
            const before = c.parts.length;
            Object.defineProperty(c, "size", { writable: false });
            let threw = false;
            try { c.enqueue(byte); } catch (e) { threw = e instanceof TypeError; }
            check(threw && c.parts.length === before + 1, "readonly size changed mutation order");
            Object.defineProperty(c, "size", { writable: true });
            const ctor = Uint8Array;
            let instances = 0;
            Object.defineProperty(ctor, Symbol.hasInstance, { configurable: true, value(value) { instances++; return true; } });
            try { c.enqueue(byte); check(instances === 1, "custom instanceof bypassed"); }
            finally { delete ctor[Symbol.hasInstance]; }
            let conversions = 0;
            class Replacement extends ctor {
                constructor(...args) { super(...args); conversions++; }
                static [Symbol.hasInstance]() { return false; }
            }
            globalThis.Uint8Array = Replacement;
            try { c.enqueue(byte); check(conversions === 1, "replaced global constructor bypassed"); }
            finally { globalThis.Uint8Array = ctor; }
            const globalDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Uint8Array");
            let globals = 0;
            Object.defineProperty(globalThis, "Uint8Array", { configurable: true, get() { globals++; return ctor; } });
            try { c.enqueue(byte); check(globals > 0, "global accessor bypassed"); }
            finally { Object.defineProperty(globalThis, "Uint8Array", globalDescriptor); }
            lengths = 0;
            Object.defineProperty(byte, "length", { configurable: true, get() { lengths++; return 1; } });
            try { c.enqueue(byte); check(lengths === 1, "own length getter bypassed"); }
            finally { delete byte.length; }
            c.enqueue(byte);
            // A failed layout fill must not poison the previously valid layout.
            const fake = { closed: false, parts: [], get size() { return 0; }, set size(v) {}, nudge: null };
            c.enqueue.call(fake, byte);
            c.enqueue(byte);
            let traps = 0;
            const target = { closed: false, parts: [], size: 0, nudge: null };
            const proxy = new Proxy(target, { get(obj, key, recv) { traps++; return Reflect.get(obj, key, recv); } });
            c.enqueue.call(proxy, byte);
            check(traps > 0 && target.parts.length === 1 && target.size === 1, "proxy controller bypassed");
            const buffer = new ArrayBuffer(4, { maxByteLength: 8 });
            const tracking = new ctor(buffer);
            const state = { closed: false, parts: [], size: 0, nudge: null };
            buffer.resize(0);
            c.enqueue.call(state, tracking);
            check(state.size === 0, "resized view length cached");
            buffer.resize(8);
            c.enqueue.call(state, tracking);
            check(state.size === 8, "grown view length cached");
            buffer.transfer();
            c.enqueue.call(state, tracking);
            check(state.size === 8, "detached view length cached");
            const fixedParts = [];
            Object.defineProperty(fixedParts, "length", { writable: false });
            const referenceParts = [];
            Object.defineProperty(referenceParts, "length", { writable: false });
            let referenceThrew = false;
            try { originalPush.call(referenceParts, byte); } catch (e) { referenceThrew = e instanceof TypeError; }
            const fixed = { closed: false, parts: fixedParts, size: 0, nudge: null };
            threw = false;
            try { c.enqueue.call(fixed, byte); } catch (e) { threw = e instanceof TypeError; }
            check(threw === referenceThrew && fixedParts.length === referenceParts.length && fixed.size === 0, "readonly array fallback changed");
            c.enqueue(byte);
            const beforeClose = c.parts.length;
            c.close();
            threw = false;
            try { c.enqueue(byte); } catch (e) { threw = e instanceof TypeError; }
            check(threw && c.parts.length === beforeClose, "closed enqueue mutated parts");
        } }, { highWaterMark: 0 });
        if (path === "/stream-views") return stream({ pull(c) {
            c.enqueue("café😀");
            const bytes = new Uint8Array([0, 65, 66, 0]);
            c.enqueue(bytes.subarray(1, 3));
            c.enqueue(new DataView(bytes.buffer, 1, 2));
            c.close();
        } }, { highWaterMark: 0 });
        if (path === "/stream-bulk") return stream({ pull(c) {
            c.enqueue(enc.encode("x".repeat(48 * 1024)));
            c.enqueue(enc.encode("x".repeat(48 * 1024)));
            c.close();
        } }, { highWaterMark: 0 });
        if (path === "/stream-large") {
            let n = 0;
            const piece = enc.encode("x".repeat(8192));
            return stream({ pull(c) { if (n++ === 1024) c.close(); else c.enqueue(piece); } });
        }
        if (path === "/empty") {
            let n = 0;
            return stream({ async pull(c) { if (++n === 1) return; c.enqueue(enc.encode("done")); c.close(); } }, { highWaterMark: 0 });
        }
        if (path === "/sync-empty") {
            let n = 0;
            return stream({ pull(c) { if (++n === 1) return; c.enqueue(enc.encode("done")); c.close(); } }, { highWaterMark: 0 });
        }
        if (path === "/empty-queued") {
            let n = 0;
            return stream({ start() {}, async pull(c) { if (++n === 1) return; c.enqueue(enc.encode("done")); c.close(); } }, { highWaterMark: 0 });
        }
        if (path === "/pending-data") return stream({
            pull(c) { c.enqueue(enc.encode("done")); c.close(); return new Promise(() => {}); }
        }, { highWaterMark: 0 });
        if (path === "/abort" || path === "/abort-queued") return stream({
            ...(path === "/abort-queued" ? { start() {} } : {}),
            pull() { return new Promise(() => {}); }, cancel() { canceled++; }
        }, { highWaterMark: 0 });
        if (path === "/canceled") return new Response(String(canceled));
        if (path === "/stream" || path === "/stream-queued") {
            let n = 0;
            return stream({ ...(path === "/stream-queued" ? { start() {} } : {}),
                pull(c) { if (n++ === 128) c.close(); else c.enqueue(enc.encode("x".repeat(1024))); } });
        }
        if (path === "/late") return new Promise((resolve) => { later = resolve; });
        if (path === "/finish-late") { later(new Response("stale")); return new Response("finished"); }
        if (path === "/subclass") {
            class SubPromise extends Promise {}
            return SubPromise.resolve(new Response("subclass"));
        }
        if (path === "/promised") return Promise.resolve(new Response("promised"));
        if (path === "/delayed") return new Promise((r) => setTimeout(() => r(new Response("delayed")), 5));
        if (path === "/rejected") return Promise.reject(new Error("rejected"));
        if (path === "/thenable") return { then(resolve) { resolve(new Response("thenable")); } };
        if (path === "/custom-then") {
            const p = Promise.resolve(new Response("unused"));
            p.then = (f) => f(new Response("custom"));
            return p;
        }
        if (path === "/file") return new Response(file.body(payload));
        if (path === "/file-relative") return new Response(file.body("./" + payload.slice(payload.lastIndexOf("/") + 1)));
        if (path === "/file-custom") return new Response(file.body(payload), { status: 201, headers: { "x-file": "yes" } });
        if (path === "/file-missing") return new Response(file.body(payload + ".missing"));
        if (path === "/file-denied") return new Response(file.body("/etc/passwd"));
        if (path === "/file-consume") return new Response(file.body(payload)).bytes().then((b) => new Response(b));
        if (path === "/file-clone") return new Response(file.body(payload)).clone();
        if (path === "/echo") return req.bytes().then((b) => new Response(b));
        return new Response("ok");
    }
});
