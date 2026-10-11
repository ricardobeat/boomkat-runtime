import { serve } from "http";
import * as file from "file";
import { args } from "process";
const [port, payload] = args;
let saved;
let canceled = 0;
let later;
let failedStream;
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
