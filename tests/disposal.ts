import { Database } from "sqlite";
import { serve } from "http";
import { transpile } from "typescript";
const assert = (ok, message) => { if (!ok) throw new Error(message); };
const throws = fn => { try { fn(); } catch (_) { return true; } return false; };
let db, stmt;
{
    using database = new Database();
    db = database;
    { using query = db.prepare("SELECT 42 AS n"); stmt = query; assert(query.get().n === 42, "query"); }
    assert(throws(() => stmt.get()), "statement must be finalized");
}
assert(throws(() => db.exec("SELECT 1")), "database must be closed");
db[Symbol.dispose](); stmt[Symbol.dispose]();
let failed;
try {
    using database = new Database();
    failed = database;
    throw new Error("body");
} catch (e) { assert(e.message === "body", "body error"); }
assert(throws(() => failed.exec("SELECT 1")), "throw must close database");
async function fallback() { await using database = new Database(); db = database; }
await fallback();
assert(throws(() => db.exec("SELECT 1")), "async fallback must close database");
let server;
async function lifetime() {
    await using scoped = serve({port: 0, hostname: "127.0.0.1", onListen() {}, fetch() { return new Response("ok"); }});
    server = scoped;
    await server.ready;
}
await lifetime();
await server.finished;
await server[Symbol.asyncDispose]();
const emitted = transpile('async function f(){await using x = null;} function g(){using x = null;}');
assert(emitted.includes('await using ') && emitted.includes('using '), "transpiler preserves disposal declarations");
const log = [];
async function ordering() {
    await using resource = { async [Symbol.asyncDispose]() { await Promise.resolve(); log.push("disposed"); } };
    log.push("body");
}
await ordering();
assert(log.join() === "body,disposed", "async cleanup must finish before return");

console.log("disposal ok");
