import { readText, writeText, remove } from "file";
const assert = (ok, message) => { if (!ok) throw new Error(message); };
const path = `/tmp/bkr-native-ops-${Date.now()}`;
const original = { Promise, withResolvers: Promise.withResolvers, resolve: Promise.resolve, Map };
try {
    // Native capabilities must not consult mutable JS factories or pending maps.
    Promise.withResolvers = () => { throw new Error("patched withResolvers"); };
    Promise.resolve = () => { throw new Error("patched resolve"); };
    globalThis.Map = class { constructor() { throw new Error("patched Map"); } };
    await writeText(path, "native promise: café 😀");
    const pending = readText(path);
    assert(pending instanceof original.Promise, "operation must return an intrinsic promise");
    assert(await pending === "native promise: café 😀", "native async settlement");
    let failure;
    try { await readText(path + ".missing"); } catch (e) { failure = e; }
    assert(failure instanceof SystemError, "native rejection keeps SystemError prototype");
    assert(failure instanceof Error && failure.code === "ENOENT", "native rejection keeps error code");
    assert(failure.name === "SystemError" && typeof failure.stack === "string", "native rejection keeps diagnostics");
    // A throwing native entry must propagate the original value, then leave
    // the next operation free to complete normally.
    const thrown = {};
    for (let i = 0; i < 1000; i++) {
        try { __bk.op(() => { throw thrown; }); throw new Error("missing throw"); }
        catch (e) { assert(e === thrown, "synchronous throw identity"); }
    }
    assert(await readText(path) === "native promise: café 😀", "operations recover after throws");
    // Completing twice for one id must not settle the next operation.
    const duplicate = __bk.op((id) => { __bk.readText(id, path); __bk.readText(id, path); });
    assert(await duplicate === "native promise: café 😀", "duplicate completion");
} finally {
    globalThis.Map = original.Map;
    Promise.withResolvers = original.withResolvers;
    Promise.resolve = original.resolve;
    await remove(path);
}
console.log("native ops: PASS");
