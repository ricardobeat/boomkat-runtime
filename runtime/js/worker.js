// Isolated module workers. The codec owns its graph and captured intrinsics;
// only encoded metadata and copied byte buffers cross execution threads.
"use strict";
(function (bk) {
	const apply = Reflect.apply,
		keys = Object.keys,
		create = Object.create;
	const define = Object.defineProperty,
		setProto = Object.setPrototypeOf;
	const stringify = JSON.stringify,
		parse = JSON.parse;
	const M = Map,
		S = Set,
		A = Array,
		AB = ArrayBuffer,
		U8 = Uint8Array;
	const D = Date,
		R = RegExp,
		B = BigInt,
		str = String,
		N = Number,
		is = Object.is;
	const CloneError = DOMException;
	const arrayIsArray = A.isArray,
		push = A.prototype.push,
		hasOwn = Object.hasOwn;
	const mapGet = M.prototype.get,
		mapHas = M.prototype.has,
		mapSet = M.prototype.set;
	const mapEntries = M.prototype.entries,
		setValues = S.prototype.values,
		setAdd = S.prototype.add;
	const mapNext = Object.getPrototypeOf(new M().entries()).next;
	const setNext = Object.getPrototypeOf(new S().values()).next;
	const dateTime = D.prototype.getTime;
	const reSource = Object.getOwnPropertyDescriptor(R.prototype, "source").get;
	const flagNames = [
		"hasIndices",
		"global",
		"ignoreCase",
		"multiline",
		"dotAll",
		"unicode",
		"unicodeSets",
		"sticky",
	];
	const flagChars = "dgimsuvy",
		flagGetters = [];
	for (const n of flagNames)
		flagGetters.push(Object.getOwnPropertyDescriptor(R.prototype, n)?.get);
	const errors = setProto(
		{
			Error,
			TypeError,
			RangeError,
			SyntaxError,
			ReferenceError,
			EvalError,
			URIError,
		},
		null,
	);
	const views = create(null);
	for (const n of [
		"Int8Array",
		"Uint8Array",
		"Uint8ClampedArray",
		"Int16Array",
		"Uint16Array",
		"Int32Array",
		"Uint32Array",
		"Float16Array",
		"Float32Array",
		"Float64Array",
		"BigInt64Array",
		"BigUint64Array",
		"DataView",
	])
		views[n] = globalThis[n];
	const info = bk.workerInfo,
		copyBuffer = bk.workerCopyBuffer,
		fillBuffer = bk.workerFillBuffer;
	const detach = bk.workerDetach,
		spawn = bk.workerStart,
		send = bk.workerSend,
		terminate = bk.workerTerminate;
	const opaque = new WeakSet(),
		opaqueAdd = WeakSet.prototype.add,
		opaqueHas = WeakSet.prototype.has;
	const markOpaque = (value) => {
		apply(opaqueAdd, opaque, [value]);
		return value;
	};
	define(bk, "workerOpaque", { value: markOpaque });
	const fail = () => {
		throw new CloneError("Value cannot be cloned", "DataCloneError");
	};
	const append = (a, v) => apply(push, a, [v]);
	const list = (...v) => setProto(v, null);
	const own = (o, k, v) =>
		define(o, k, {
			value: v,
			enumerable: true,
			writable: true,
			configurable: true,
		});
	const transferList = (options) => {
		const source = arrayIsArray(options) ? options : options?.transfer || [];
		if (!arrayIsArray(source)) throw new TypeError("transfer must be an array");
		const count = source.length;
		if (count > 32768) throw new RangeError("Too many transfers");
		const out = list(),
			seen = new M();
		for (let i = 0; i < count; i++) {
			const v = source[i],
				details = info(v);
			if (
				details.kind !== "buffer" ||
				!details.transferable ||
				apply(mapHas, seen, [v])
			)
				fail();
			apply(mapSet, seen, [v, true]);
			append(out, v);
		}
		return out;
	};
	function encode(value) {
		const ids = new M(),
			pending = list(),
			nodes = list(),
			buffers = list();
		let binaryBytes = 0,
			entriesCount = 0;
		function countEntries(count) {
			entriesCount += count;
			if (entriesCount > 32768)
				throw new RangeError("Clone graph is too large");
		}
		function ref(v) {
			if (v === undefined) return list("undefined");
			if (v === null || typeof v === "string" || typeof v === "boolean")
				return list("primitive", v);
			if (typeof v === "number")
				return list("number", is(v, -0) ? "-0" : str(v));
			if (typeof v === "bigint") return list("bigint", str(v));
			if (typeof v !== "object" || apply(opaqueHas, opaque, [v])) fail();
			if (apply(mapHas, ids, [v]))
				return list("reference", apply(mapGet, ids, [v]));
			if (pending.length >= 32768)
				throw new RangeError("Clone graph is too large");
			const id = pending.length;
			apply(mapSet, ids, [v, id]);
			append(pending, v);
			return list("reference", id);
		}
		const root = ref(value);
		for (let i = 0; i < pending.length; i++) {
			const v = pending[i],
				details = info(v);
			let node;
			if (details.kind === "object" || details.kind === "array") {
				const length = details.kind === "array" ? v.length : 0;
				const entries = list(),
					names = keys(v);
				countEntries(names.length);
				for (let j = 0; j < names.length; j++)
					append(entries, list(names[j], ref(v[names[j]])));
				node =
					details.kind === "array"
						? list("array", length, entries)
						: list("object", entries);
			} else if (details.kind === "map" || details.kind === "set") {
				const entries = list(),
					map = details.kind === "map";
				const iterator = apply(map ? mapEntries : setValues, v, []);
				while (true) {
					const step = apply(map ? mapNext : setNext, iterator, []);
					if (step.done) break;
					countEntries(1);
					append(
						entries,
						map
							? list(ref(step.value[0]), ref(step.value[1]))
							: ref(step.value),
					);
				}
				node = list(details.kind, entries);
			} else if (details.kind === "date")
				node = list("date", ref(apply(dateTime, v, [])));
			else if (details.kind === "regexp") {
				let flags = "";
				for (let j = 0; j < flagGetters.length; j++)
					if (flagGetters[j] && apply(flagGetters[j], v, []))
						flags += flagChars[j];
				node = list("regexp", apply(reSource, v, []), flags);
			} else if (details.kind === "buffer") {
				binaryBytes += details.length;
				if (binaryBytes > 16 * 1024 * 1024)
					throw new RangeError("Message is too large");
				const index = buffers.length;
				append(buffers, copyBuffer(v));
				node = list(
					"buffer",
					index,
					details.length,
					details.resizable,
					details.maxLength,
					details.immutable,
				);
			} else if (details.kind === "view")
				node = list(
					"view",
					details.type,
					ref(details.buffer),
					details.offset,
					details.length,
					details.tracking,
				);
			else if (details.kind === "error") {
				const name = str(v.name),
					message = str(v.message),
					stack = v.stack;
				node = list(
					"error",
					errors[name] ? name : "Error",
					message,
					typeof stack === "string" ? stack : "",
					hasOwn(v, "cause") ? ref(v.cause) : list("undefined"),
				);
			} else fail();
			append(nodes, node);
		}
		return { text: stringify(list(root, nodes)), buffers };
	}
	function decode(text, buffers) {
		const graph = parse(text),
			nodes = graph[1],
			values = list();
		function ref(v) {
			switch (v[0]) {
				case "undefined":
					return undefined;
				case "primitive":
					return v[1];
				case "number":
					return N(v[1]);
				case "bigint":
					return B(v[1]);
				case "reference":
					return values[v[1]];
				default:
					return fail();
			}
		}
		for (let i = 0; i < nodes.length; i++) {
			const n = nodes[i];
			switch (n[0]) {
				case "object":
					values[i] = {};
					break;
				case "array":
					values[i] = new A(n[1]);
					break;
				case "map":
					values[i] = new M();
					break;
				case "set":
					values[i] = new S();
					break;
				case "date":
					values[i] = new D(ref(n[1]));
					break;
				case "regexp":
					values[i] = new R(n[1], n[2]);
					break;
				case "error":
					values[i] = new errors[n[1]](n[2]);
					break;
				case "buffer":
					values[i] = n[3]
						? new AB(n[2], { maxByteLength: n[4] })
						: new AB(n[2]);
					fillBuffer(values[i], buffers[n[1]], n[5]);
					break;
				case "view":
					break;
				default:
					fail();
			}
		}
		for (let i = 0; i < nodes.length; i++) {
			const n = nodes[i];
			if (n[0] === "view") {
				const C = views[n[1]];
				if (!C) fail();
				values[i] = n[5]
					? new C(ref(n[2]), n[3])
					: new C(
							ref(n[2]),
							n[3],
							n[1] === "DataView" ? n[4] : n[4] / C.BYTES_PER_ELEMENT,
						);
			}
		}
		for (let i = 0; i < nodes.length; i++) {
			const n = nodes[i],
				v = values[i];
			if (n[0] === "object" || n[0] === "array") {
				const entries = n[n[0] === "array" ? 2 : 1];
				for (let j = 0; j < entries.length; j++)
					own(v, entries[j][0], ref(entries[j][1]));
			} else if (n[0] === "map") {
				for (let j = 0; j < n[1].length; j++)
					apply(mapSet, v, [ref(n[1][j][0]), ref(n[1][j][1])]);
			} else if (n[0] === "set") {
				for (let j = 0; j < n[1].length; j++) apply(setAdd, v, [ref(n[1][j])]);
			} else if (n[0] === "error") {
				if (n[3])
					define(v, "stack", {
						value: n[3],
						writable: true,
						configurable: true,
					});
				if (n[4][0] !== "undefined")
					define(v, "cause", {
						value: ref(n[4]),
						writable: true,
						configurable: true,
					});
			}
		}
		return ref(graph[0]);
	}
	define(globalThis, "structuredClone", {
		configurable: true,
		writable: true,
		value(value, options) {
			const transfers = transferList(options),
				encoded = encode(value);
			const result = decode(encoded.text, encoded.buffers);
			detach(transfers);
			return result;
		},
	});
	class MessageEvent extends Event {
		constructor(type, init = {}) {
			super(type, init);
			this.data = init.data;
			this.origin = "";
			this.source = null;
			this.ports = [];
		}
	}
	class ErrorEvent extends Event {
		constructor(type, init = {}) {
			super(type, init);
			this.message = init.message || "";
			this.filename = init.filename || "";
			this.lineno = 0;
			this.colno = 0;
			this.error = init.error;
		}
	}
	const records = new M(),
		brands = new WeakMap();
	class Worker extends EventTarget {
		constructor(url, options = {}) {
			super();
			markOpaque(this);
			if (options.type !== undefined && options.type !== "module")
				throw new TypeError("Only module workers are supported");
			let path = str(url);
			if (path.startsWith("file://"))
				path = decodeURIComponent(new URL(path).pathname);
			const id = spawn(path, str(options.name || ""));
			const record = { id, worker: this, closed: false };
			brands.set(this, record);
			apply(mapSet, records, [id, record]);
		}
		postMessage(value, options) {
			const record = brands.get(this);
			if (!record) throw new TypeError("Invalid Worker receiver");
			if (record.closed) return;
			const transfers = transferList(options),
				encoded = encode(value);
			send(record.id, encoded.text, encoded.buffers, transfers);
		}
		terminate() {
			const record = brands.get(this);
			if (!record) throw new TypeError("Invalid Worker receiver");
			if (record.closed) return;
			record.closed = true;
			terminate(record.id);
		}
	}
	for (const [n, v] of [
		["Worker", Worker],
		["MessageEvent", MessageEvent],
		["ErrorEvent", ErrorEvent],
	])
		define(globalThis, n, { value: v, writable: true, configurable: true });
	const globalDispatch = dispatchEvent;
	bk.workerEvent = (id, kind, text, buffers) => {
		if (id === 0) {
			globalDispatch(
				new MessageEvent("message", { data: decode(text, buffers) }),
			);
			return;
		}
		const record = apply(mapGet, records, [id]);
		if (!record) return;
		if (kind === 2) {
			record.closed = true;
			records.delete(id);
			record.worker.dispatchEvent(new Event("close"));
		} else if (!record.closed) {
			if (kind === 0)
				record.worker.dispatchEvent(
					new MessageEvent("message", { data: decode(text, buffers) }),
				);
			else {
				const error = new Error(text);
				const event = new ErrorEvent("error", {
					message: text,
					error,
					cancelable: true,
				});
				if (record.worker.dispatchEvent(event)) throw error;
			}
		}
	};
	if (bk.workerIsWorker()) {
		define(globalThis, "self", { value: globalThis, configurable: true });
		define(globalThis, "name", { value: bk.workerName(), configurable: true });
		define(globalThis, "postMessage", {
			value(value, options) {
				const transfers = transferList(options),
					encoded = encode(value);
				send(0, encoded.text, encoded.buffers, transfers);
			},
			configurable: true,
			writable: true,
		});
		define(globalThis, "close", {
			value: bk.workerClose,
			configurable: true,
			writable: true,
		});
	}
})(globalThis.__bk);
