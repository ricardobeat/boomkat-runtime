const assert = (ok, message) => { if (!ok) throw new Error(message); };
let invalid = false;
try { setImmediate(1); } catch (e) { invalid = e instanceof TypeError; }
assert(invalid, "non-callable immediate accepted");
const order = [];
const never = setImmediate(() => { throw new Error("canceled immediate fired"); });
clearImmediate(never);
let canceled;
await new Promise((resolve) => {
    setImmediate(() => {
        order.push("first");
        clearImmediate(canceled);
        Promise.resolve().then(() => order.push("microtask"));
        setImmediate(() => order.push("nested"));
    });
    canceled = setImmediate(() => { throw new Error("running batch cancellation lost"); });
    setImmediate(() => {
        order.push("second");
        setImmediate(resolve);
    });
});
assert(order.join() === "first,second,microtask,nested", "batch or microtask ordering changed: " + order);
const args = await new Promise((resolve) => setImmediate((...values) => resolve(values), 1, "two", null, 4, 5, 6));
assert(args.join() === "1,two,,4,5,6", "immediate arguments lost");
let fired = false;
await new Promise((resolve) => {
    const id = setImmediate(() => { fired = true; });
    clearImmediate(id + .5);
    clearImmediate(String(id));
    clearImmediate(NaN);
    clearImmediate(Infinity);
    setImmediate(resolve);
});
assert(fired, "invalid cancellation ID canceled another callback");
const target = {};
await new Promise((resolve) => {
    setImmediate(Object.assign, target, { builtin: true });
    setImmediate(resolve);
});
assert(target.builtin, "builtin callback rejected or skipped");
console.log("immediates: passed");
