const assert = (ok, message) => { if (!ok) throw new Error(message); };
const start = performance.now();
let count = 0;
let otherTurn = false;
let id;
const done = new Promise((resolve) => {
    id = setInterval(() => {
        if (++count === 10) { clearInterval(id); resolve(); }
    }, 1);
});
setImmediate(() => { otherTurn = true; });
await done;
assert(otherTurn, "interval starved another loop turn");
assert(performance.now() - start >= 9, "interval fired repeatedly within one tick");
const seen = [];
const canceled = setTimeout(() => { throw new Error("cleared timer fired"); }, 5);
clearTimeout(canceled);
await new Promise((resolve) => setTimeout((...args) => { seen.push(...args); resolve(); }, 2, 1, 2, 3, 4, 5, 6));
assert(seen.join() === "1,2,3,4,5,6", "timer arguments lost");
let nested = false;
await new Promise((resolve) => setTimeout(() => setTimeout(() => { nested = true; resolve(); }, 0), 0));
assert(nested, "nested timer lost");
console.log("timers: passed");
