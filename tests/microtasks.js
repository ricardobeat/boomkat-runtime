import { execPath, run } from "process";
import { writeText, remove } from "file";
const assert = (ok, message) => { if (!ok) throw new Error(message); };
for (const value of [undefined, null, 0, {}, "callback"]) {
    let error;
    try { queueMicrotask(value); } catch (e) { error = e; }
    assert(error instanceof TypeError, "noncallable callback must throw synchronously");
}
const order = [];
const oldResolve = Promise.resolve, oldThen = Promise.prototype.then;
const NativePromise = Promise;
const tick = new NativePromise(resolve => setImmediate(resolve));
try {
    // The first promise reaction is already queued; native jobs must join the
    // same FIFO and must not consult these mutable factories at enqueue time.
    oldThen.call(oldResolve.call(NativePromise), () => order.push("promise"));
    Promise.resolve = () => { throw new Error("patched resolve"); };
    Promise.prototype.then = () => { throw new Error("patched then"); };
    globalThis.Promise = class { constructor() { throw new Error("patched Promise"); } };
    queueMicrotask(function () {
        assert(arguments.length === 0, "microtask receives no arguments");
        assert(this === undefined, "microtask this is undefined");
        order.push("first");
        queueMicrotask(() => order.push("nested"));
        return { get then() { throw new Error("callback return value was adopted"); } };
    });
    queueMicrotask(() => order.push("second"));
    assert(order.length === 0, "microtasks must not run inline");
    await tick;
} finally {
    globalThis.Promise = NativePromise;
    NativePromise.resolve = oldResolve;
    NativePromise.prototype.then = oldThen;
}
assert(order.join(",") === "promise,first,second,nested", "microtask FIFO: " + order);
const path = `/tmp/bkr-microtask-throw-${Date.now()}.js`;
try {
    await writeText(path, `addEventListener("unhandledrejection", e => { e.preventDefault(); console.log("wrong rejection"); });
queueMicrotask(() => { throw new Error("microtask boom"); });`);
    const result = await run(execPath, { args: ["--no-sandbox", path] });
    const error = new TextDecoder().decode(result.stderr);
    assert(result.code === 1, "microtask throw must terminate as an uncaught exception");
    assert(error.includes("Error: microtask boom"), "microtask throw preserves error");
    assert(!error.includes("in promise"), "microtask throw must not become a rejection");
    assert(!new TextDecoder().decode(result.stdout).includes("wrong rejection"), "rejection listener must not intercept microtask throw");
} finally { await remove(path); }
console.log("microtasks: PASS");
