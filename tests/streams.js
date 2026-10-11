const assert = (ok, message) => { if (!ok) throw new Error(message); };
const first = new ReadableStream({ start(c) { c.enqueue("first"); c.close(); } });
const second = new ReadableStream({ async pull(c) { await 0; c.enqueue("second"); c.close(); } });
assert(!first.locked && !second.locked, "fresh streams are locked");
const reader = first.getReader();
assert(first.locked && !second.locked, "reader state leaked between streams");
assert((await reader.read()).value === "first", "queued chunk lost");
assert((await reader.read()).done, "queued close lost");
await reader.closed;
assert(await new Response(second).text() === "second", "async pull lost");

const failure = new Error("expected");
const broken = new ReadableStream({ start(c) { c.error(failure); } }).getReader();
assert(await broken.read().then(() => false, (e) => e === failure), "read error lost");
assert(await broken.closed.then(() => false, (e) => e === failure), "closed error lost");

let reason;
const canceled = new ReadableStream({ cancel(r) { reason = r; } }, { highWaterMark: 0 }).getReader();
const pending = canceled.read();
await canceled.cancel("stop");
assert((await pending).done && reason === "stop", "cancellation did not settle pending read");
await canceled.closed;
console.log("streams: passed");
