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
// A later deadline must not postpone a newly inserted earlier timer.
const order = [];
await new Promise((resolve) => {
    setTimeout(() => { order.push(3); resolve(); }, 12);
    setTimeout(() => order.push(1), 2);
    setTimeout(() => order.push(2), 6);
});
assert(order.join() === "1,2,3", "timer re-arm lost deadline order");
// Cancel the earliest deadline while another timer still needs a wake-up.
await new Promise((resolve) => {
    const early = setTimeout(() => { throw new Error("canceled heap head fired"); }, 2);
    setTimeout(resolve, 4);
    clearTimeout(early);
});
// Sub-millisecond re-arms must never advance a JS timer's deadline.
await Promise.all(Array.from({ length: 128 }, () => new Promise((resolve) => {
    const scheduled = performance.now();
    setTimeout(() => {
        assert(performance.now() - scheduled >= .95, "precise timer fired early");
        resolve();
    }, 0);
})));
let expired = 0;
// Timers that become overdue while JS runs must all get another loop turn.
const pending = Array.from({ length: 128 }, () => new Promise((resolve) => {
    const scheduled = performance.now();
    setTimeout(() => {
        assert(performance.now() - scheduled >= .95, "timer fired early");
        expired++;
        resolve();
    }, 0);
}));
const busyStart = performance.now();
while (performance.now() - busyStart < 3) {}
await Promise.all(pending);
assert(expired === 128, "overdue timer batch did not finish");
console.log("timers: passed");
