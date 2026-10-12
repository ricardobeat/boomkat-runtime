import { args } from "process";
const assert = (ok, message) => { if (!ok) throw new Error(message); };
let unavailable = false;
try { await import("sqlite"); } catch (_) { unavailable = true; }
assert(unavailable, "SQLite module registered without usable library");
assert(__bk.sqliteOpen === undefined, "SQLite natives installed without usable library");
assert(Array.isArray(args), "other builtins failed without SQLite");
console.log("sqlite unavailable: passed");
