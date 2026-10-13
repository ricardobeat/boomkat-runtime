import { args } from "process";
function assert(value, message) {
	if (!value) throw new Error(message);
}
const deadline = setTimeout(() => {
	throw new Error("workers timed out");
}, 20000);
globalThis.parentMark = "parent only";
function worker(path = "./echo.ts", name = "") {
	const w = new Worker(path, { type: "module", name });
	w.onerror = (e) => {
		throw new Error(e.message);
	};
	w.closed = new Promise((resolve) =>
		w.addEventListener("close", resolve, { once: true }),
	);
	return w;
}
function receive(w) {
	return new Promise((resolve) =>
		w.addEventListener("message", (e) => resolve(e.data), { once: true }),
	);
}
async function request(w, data, transfer) {
	const result = receive(w);
	w.postMessage(data, transfer);
	return await result;
}
const a = worker("./echo.ts", "A"),
	b = worker("./echo.ts", "B");
const buffer = new ArrayBuffer(16),
	bytes = new Uint8Array(buffer, 4, 4);
bytes.set([1, 2, 3, 4]);
const key = { id: 1 },
	sparse = new Array(5);
sparse[3] = undefined;
sparse.extra = "extra";
const payload = {
	key,
	buffer,
	bytes,
	view: new DataView(buffer, 2, 8),
	map: new Map([[key, bytes]]),
	set: new Set([key]),
	sparse,
	missing: undefined,
	big: 123456789012345678901234567890n,
	nan: NaN,
	negzero: -0,
	date: new Date(12345),
	invalidDate: new Date(NaN),
	regex: /a+b/gi,
	text: "é😀\ud800",
	error: new TypeError("cloned error", { cause: key }),
};
payload.self = payload;
const result = await request(a, payload);
const v = result.value;
assert(
	result.count === 1 &&
		result.name === "A" &&
		result.moduleMarker === "imported TS",
	"worker state and TS module",
);
assert(
	result.isolated && result.target && result.receiver,
	"isolated globals and worker event receiver",
);
assert(
	v !== payload &&
		v.self === v &&
		v.map.get(v.key) === v.bytes &&
		v.set.has(v.key),
	"cycles and collection aliases",
);
assert(
	v.bytes.buffer === v.buffer &&
		v.view.buffer === v.buffer &&
		v.bytes.byteOffset === 4 &&
		v.bytes[2] === 3,
	"view aliases and offsets",
);
assert(
	v.sparse.length === 5 &&
		!(0 in v.sparse) &&
		3 in v.sparse &&
		v.sparse.extra === "extra",
	"sparse arrays",
);
assert(
	Object.hasOwn(v, "missing") &&
		v.missing === undefined &&
		v.big === payload.big &&
		Number.isNaN(v.nan) &&
		Object.is(v.negzero, -0),
	"primitive types",
);
assert(
	v.date.getTime() === 12345 &&
		Number.isNaN(v.invalidDate.getTime()) &&
		v.regex.source === "a+b" &&
		v.regex.flags === "gi",
	"date and regexp",
);
assert(
	v.text === payload.text &&
		v.error instanceof TypeError &&
		v.error.cause === v.key,
	"strings and errors",
);
v.bytes[0] = 99;
assert(bytes[0] === 1, "buffers are copied");
const other = await request(b, { second: true });
assert(other.count === 1 && other.name === "B", "independent counters");
const transfer = new ArrayBuffer(8);
new Uint8Array(transfer)[0] = 42;
const transferred = request(a, { buffer: transfer }, [transfer]);
assert(transfer.byteLength === 0, "sender detached synchronously");
assert(
	new Uint8Array((await transferred).value.buffer)[0] === 42,
	"transferred bytes",
);
const failedTransfer = new ArrayBuffer(2);
for (const data of [
	() => {},
	Symbol("x"),
	new WeakMap(),
	new SharedArrayBuffer(4),
	new Proxy({}, {}),
]) {
	let failed = false;
	try {
		a.postMessage(data, [failedTransfer]);
	} catch (e) {
		failed = e.name === "DataCloneError";
	}
	assert(
		failed && failedTransfer.byteLength === 2,
		"unsupported clone preserves transfer",
	);
}
let duplicate = false;
try {
	a.postMessage({}, [failedTransfer, failedTransfer]);
} catch (e) {
	duplicate = e.name === "DataCloneError";
}
assert(
	duplicate && failedTransfer.byteLength === 2,
	"duplicate transfer preserves source",
);
let workerClone = false;
try {
	structuredClone(a);
} catch (e) {
	workerClone = e.name === "DataCloneError";
}
assert(workerClone, "worker handles cannot be cloned");
const originalStringify = JSON.stringify,
	originalParse = JSON.parse,
	originalMapSet = Map.prototype.set;
Object.prototype.toJSON = () => {
	throw new Error("toJSON must not run");
};
Array.prototype.toJSON = Object.prototype.toJSON;
JSON.stringify = Object.prototype.toJSON;
JSON.parse = Object.prototype.toJSON;
Map.prototype.set = Object.prototype.toJSON;
const protectedClone = structuredClone(payload);
delete Object.prototype.toJSON;
delete Array.prototype.toJSON;
JSON.stringify = originalStringify;
JSON.parse = originalParse;
Map.prototype.set = originalMapSet;
assert(
	protectedClone.self === protectedClone &&
		protectedClone.map.get(protectedClone.key) === protectedClone.bytes,
	"codec captures intrinsics and avoids toJSON",
);
const clone = structuredClone(payload);
assert(
	clone.self === clone && clone.map.get(clone.key) === clone.bytes,
	"structuredClone graph",
);
const resizable = new ArrayBuffer(8, { maxByteLength: 32 });
const tracking = new Uint8Array(resizable),
	fixed = new Uint8Array(resizable, 2, 2);
const resized = structuredClone({ resizable, tracking, fixed });
resized.resizable.resize(16);
assert(
	resized.tracking.length === 16 &&
		resized.fixed.length === 2 &&
		resized.resizable.maxByteLength === 32,
	"resizable buffer and tracking views",
);
const order = [],
	ordered = new Promise((resolve) => {
		a.addEventListener("message", function collect(e) {
			order.push(e.data.value.order);
			if (order.length === 30) {
				a.removeEventListener("message", collect);
				resolve();
			}
		});
	});
for (let i = 0; i < 30; i++) a.postMessage({ order: i });
await ordered;
assert(
	order.every((n, i) => n === i),
	"message ordering",
);
const natives = await Promise.all([
	request(a, { command: "native", path: args[0] }),
	request(b, { command: "native", path: args[0] }),
]);
assert(
	natives.every(
		(r) =>
			r.text === "worker fixture" && r.valid && r.saltChars === 43 && r.row > 0,
	),
	"async jobs return to owning loop and SQLite is isolated",
);
const nested = await request(b, { command: "nested" });
assert(nested.value.nested && nested.name === "nested", "nested workers");
const transferReplies = [];
const returning = new Promise((resolve) => {
	a.addEventListener("message", function collect(e) {
		transferReplies.push(e.data);
		if (transferReplies.length === 2) {
			a.removeEventListener("message", collect);
			resolve();
		}
	});
});
a.postMessage({ command: "transfer" });
await returning;
assert(
	transferReplies[0] instanceof Uint8Array &&
		transferReplies[0][0] === 9 &&
		transferReplies[1].detached,
	"worker-to-parent transfer",
);
a.terminate();
b.terminate();
await Promise.all([a.closed, b.closed]);
const selfClosing = worker();
const closeReply = request(selfClosing, { command: "self-close" });
assert((await closeReply) === "closing", "self-close delivers queued message");
await selfClosing.closed;
const bad = worker("./error.ts");
let error = "";
bad.onerror = (e) => {
	e.preventDefault();
	error = e.message;
};
await bad.closed;
assert(
	error.includes("worker failure"),
	"worker errors propagate without terminating parent",
);
const endless = worker("./infinite.ts");
assert((await receive(endless)) === "running", "infinite worker started");
endless.terminate();
await endless.closed;
for (let i = 0; i < 12; i++) {
	const w = worker();
	assert((await request(w, { i })).value.i === i, "repeated creation");
	w.terminate();
	await w.closed;
}
const bootTerminated = worker();
bootTerminated.terminate();
await bootTerminated.closed;
const exiting = worker("./exit.ts");
assert(
	(await receive(exiting)) === "exiting",
	"worker process.exit delivered message",
);
await exiting.closed;
clearTimeout(deadline);
console.log(
	"Workers: cloning, TS/TLA, isolation, async resources, nested workers, lifecycle and interruption passed",
);
