import { serve } from "http";
import { Database } from "sqlite";
import { args } from "process";
const db = new Database();
const sql = "SELECT 42 AS n";
function manual() {
    const stmt = db.prepare(sql);
    try { return Response.json(stmt.get()); }
    finally { stmt.finalize(); }
}
function scoped() {
    using stmt = db.prepare(sql);
    return Response.json(stmt.get());
}
async function manualAsync() {
    const stmt = db.prepare(sql);
    try { return Response.json(stmt.get()); }
    finally { await stmt.finalize(); }
}
async function scopedAsync() {
    await using stmt = db.prepare(sql);
    return Response.json(stmt.get());
}
async function scopedRealAsync() {
    const stmt = db.prepare(sql);
    await using resource = {
        [Symbol.asyncDispose]() { stmt.finalize(); return Promise.resolve(); }
    };
    return Response.json(stmt.get());
}
const cached = db.prepare(sql);
serve({port: Number(args[0]), hostname: "127.0.0.1", onListen() {}, fetch(req) {
    switch (new URL(req.url).pathname) {
        case "/hello": return new Response("hello world");
        case "/manual": return manual();
        case "/using": return scoped();
        case "/finallyasync": return manualAsync();
        case "/awaitusing": return scopedAsync();
        case "/asyncdispose": return scopedRealAsync();
        case "/cached": return Response.json(cached.get());
    }
    return new Response("missing", {status: 404});
}});
