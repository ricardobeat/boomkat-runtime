// The test module: registration, hooks and assertions for `bkr test`.
// Test files register with test() and describe() while they load; the
// runner then runs each file's tests in order, one at a time.
const bk = __bk;

// ---- registration ----

let current = null; // the file being loaded: { root, scope }
const all = [];

function newScope(name, parent, mode) {
    return { name, parent, mode, items: [], beforeAll: [], afterAll: [], beforeEach: [], afterEach: [] };
}

function register(kind, name, fn, mode) {
    if (!current) throw new Error(`${kind}() can only be called while a test file loads`);
    if (typeof name === "function") [name, fn] = [fn?.name || "(anonymous)", name];
    name = String(name);
    if (kind === "describe") {
        const scope = newScope(name, current.scope, mode);
        current.scope.items.push(scope);
        if (typeof fn !== "function") throw new TypeError("describe() needs a function");
        const outer = current.scope;
        current.scope = scope;
        try {
            const r = fn();
            if (r && typeof r.then === "function") throw new TypeError("describe() callbacks must be synchronous");
        } finally {
            current.scope = outer;
        }
        return;
    }
    if (mode !== "todo" && typeof fn !== "function") throw new TypeError("test() needs a function");
    current.scope.items.push({ name, fn, mode, parent: current.scope });
}

const variants = (kind) => {
    const f = (name, fn) => register(kind, name, fn, "");
    f.skip = (name, fn) => register(kind, name, fn, "skip");
    f.only = (name, fn) => register(kind, name, fn, "only");
    if (kind === "test") f.todo = (name) => register(kind, name, undefined, "todo");
    return f;
};

export const test = variants("test");
export const it = test;
export const describe = variants("describe");

const hook = (key) => (fn) => {
    if (!current) throw new Error(`${key}() can only be called while a test file loads`);
    if (typeof fn !== "function") throw new TypeError(`${key}() needs a function`);
    current.scope[key].push(fn);
};
export const beforeAll = hook("beforeAll");
export const afterAll = hook("afterAll");
export const beforeEach = hook("beforeEach");
export const afterEach = hook("afterEach");

// ---- assertions ----

export class AssertionError extends Error {
    constructor(message, details) {
        super(message);
        if (details) Object.assign(this, details);
    }
}
// On the prototype, so the stack captured by Error's constructor names it.
Object.defineProperty(AssertionError.prototype, "name", { value: "AssertionError", configurable: true, writable: true });

function show(v) {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "bigint") return `${v}n`;
    if (typeof v === "function") return `[Function ${v.name || "anonymous"}]`;
    if (v instanceof Error) return `${v.name}: ${v.message}`;
    try {
        const seen = new Set();
        const s = JSON.stringify(v, (k, x) => {
            if (typeof x === "bigint") return `${x}n`;
            if (x instanceof Map) return { "Map": [...x] };
            if (x instanceof Set) return { "Set": [...x] };
            if (x && typeof x === "object") { if (seen.has(x)) return "[Circular]"; seen.add(x); }
            if (x === undefined) return "undefined";
            return x;
        });
        return s === undefined ? String(v) : s;
    } catch { return String(v); }
}

function equal(a, b, seen = new Map()) {
    if (Object.is(a, b)) return true;
    if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
    if (Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
    if (seen.get(a) === b) return true;
    seen.set(a, b);
    if (a instanceof Date) return Object.is(a.getTime(), b.getTime());
    if (a instanceof RegExp) return a.source === b.source && a.flags === b.flags;
    if (a instanceof Error && (a.name !== b.name || a.message !== b.message)) return false;
    if (ArrayBuffer.isView(a) || a instanceof ArrayBuffer) {
        const x = ArrayBuffer.isView(a) ? new Uint8Array(a.buffer, a.byteOffset, a.byteLength) : new Uint8Array(a);
        const y = ArrayBuffer.isView(b) ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength) : new Uint8Array(b);
        return x.length === y.length && x.every((v, i) => v === y[i]);
    }
    if (a instanceof Map) {
        if (a.size !== b.size) return false;
        for (const [k, v] of a) if (!b.has(k) || !equal(v, b.get(k), seen)) return false;
        return true;
    }
    if (a instanceof Set) {
        if (a.size !== b.size) return false;
        outer: for (const v of a) {
            if (b.has(v)) continue;
            for (const w of b) if (equal(v, w, seen)) continue outer;
            return false;
        }
        return true;
    }
    const ka = Reflect.ownKeys(a).filter((k) => Object.prototype.propertyIsEnumerable.call(a, k));
    const kb = Reflect.ownKeys(b).filter((k) => Object.prototype.propertyIsEnumerable.call(b, k));
    if (ka.length !== kb.length) return false;
    for (const k of ka) if (!Object.prototype.propertyIsEnumerable.call(b, k) || !equal(a[k], b[k], seen)) return false;
    return true;
}

export function assert(condition, message = "expected a truthy value") {
    if (!condition) throw new AssertionError(message);
}

export function assertEquals(actual, expected, message) {
    if (!equal(actual, expected)) {
        throw new AssertionError(message ?? `values are not equal\n    expected ${show(expected)}\n    actual   ${show(actual)}`, { actual, expected });
    }
}

export function assertNotEquals(actual, expected, message) {
    if (equal(actual, expected)) throw new AssertionError(message ?? `expected a value other than ${show(expected)}`);
}

export function assertStrictEquals(actual, expected, message) {
    if (!Object.is(actual, expected)) {
        throw new AssertionError(message ?? `values are not identical\n    expected ${show(expected)}\n    actual   ${show(actual)}`, { actual, expected });
    }
}

export function assertMatch(text, pattern, message) {
    if (!pattern.test(text)) throw new AssertionError(message ?? `${show(text)} does not match ${pattern}`);
}

function checkError(e, ErrorClass, includes) {
    if (ErrorClass && !(e instanceof ErrorClass)) {
        throw new AssertionError(`expected ${ErrorClass.name}, got ${show(e)}`);
    }
    if (includes !== undefined && !String(e?.message ?? e).includes(includes)) {
        throw new AssertionError(`expected the error message to include ${show(includes)}, got ${show(e?.message ?? e)}`);
    }
    return e;
}

export function assertThrows(fn, ErrorClass, includes) {
    try { fn(); } catch (e) { return checkError(e, ErrorClass, includes); }
    throw new AssertionError("expected the function to throw");
}

export async function assertRejects(fn, ErrorClass, includes) {
    try { await (typeof fn === "function" ? fn() : fn); } catch (e) { return checkError(e, ErrorClass, includes); }
    throw new AssertionError("expected the promise to reject");
}

export function fail(message = "failed") {
    throw new AssertionError(message);
}

// ---- running ----

const out = (s) => bk.print(1, s);
const color = bk.isatty(1);
const paint = (code, s) => color ? `\x1b[${code}m${s}\x1b[0m` : s;
const ms = (t) => t < 1 ? `${t.toFixed(2)} ms` : t < 1000 ? `${t.toFixed(0)} ms` : `${(t / 1000).toFixed(2)} s`;

function describeError(e) {
    if (!(e instanceof Error)) return `      Uncaught ${show(e)}`;
    // The engine heads the stack with the base constructor's name, and the
    // runner's own frames say nothing about the test.
    const frames = String(e.stack || "").split("\n")
        .filter((l) => /^\s+at /.test(l) && !/ \(test:\d+:\d+\)$/.test(l));
    const text = [`${e.name}: ${e.message}`, ...frames].join("\n");
    return text.split("\n").map((l) => "      " + l).join("\n");
}

function anyOnly(scope) {
    return scope.items.some((x) => x.mode === "only" || (x.items && anyOnly(x)));
}

function fullName(item) {
    const names = [];
    for (let s = item.parent; s && s.parent; s = s.parent) names.unshift(s.name);
    names.push(item.name);
    return names.join(" > ");
}

// Unhandled rejections during a test fail it instead of ending the run.
let stray = [];
addEventListener("unhandledrejection", (e) => { stray.push(e.reason); e.preventDefault(); });

async function runScope(scope, ctx, inherited) {
    const skipped = inherited === "skip" || scope.mode === "skip";
    const runnable = (item) => {
        if (skipped || item.mode === "skip" || item.mode === "todo") return false;
        if (!ctx.only) return true;
        for (let s = item; s; s = s.parent) if (s.mode === "only") return true;
        return item.items ? anyOnly(item) : false;
    };
    const active = scope.items.filter((x) => runnable(x) && (x.items || !ctx.filter || fullName(x).includes(ctx.filter)));
    let hookError = null;
    if (active.length) {
        for (const h of scope.beforeAll) {
            try { await h(); } catch (e) { hookError = e; break; }
        }
    }
    for (const item of scope.items) {
        if (item.items) {
            await runScope(item, ctx, skipped ? "skip" : inherited);
            continue;
        }
        const name = fullName(item);
        if (ctx.filter && !name.includes(ctx.filter)) continue;
        if (!runnable(item)) {
            if (ctx.only && item.mode !== "skip" && item.mode !== "todo" && !skipped) continue;
            ctx.skipped++;
            out(`  ${paint(33, "-")} ${name}${item.mode === "todo" ? paint(2, " (todo)") : ""}\n`);
            continue;
        }
        const started = performance.now();
        let error = hookError;
        stray = [];
        if (!error) {
            const chain = [];
            for (let s = scope; s; s = s.parent) chain.unshift(s);
            try {
                for (const s of chain) for (const h of s.beforeEach) await h();
                await item.fn();
            } catch (e) { error = e; }
            for (const s of chain.reverse()) {
                for (const h of s.afterEach) {
                    try { await h(); } catch (e) { error ??= e; }
                }
            }
            // Let rejections from the test's own promises surface.
            await new Promise((r) => setTimeout(r, 0));
            if (!error && stray.length) error = stray[0];
        }
        const took = performance.now() - started;
        if (error) {
            ctx.failed++;
            ctx.failures.push({ file: ctx.file, name, error });
            out(`  ${paint(31, "✗")} ${name} ${paint(2, `(${ms(took)})`)}\n${describeError(error)}\n`);
        } else {
            ctx.passed++;
            out(`  ${paint(32, "✓")} ${name} ${paint(2, `(${ms(took)})`)}\n`);
        }
    }
    if (active.length) {
        for (const h of scope.afterAll) {
            try { await h(); } catch (e) {
                ctx.failed++;
                ctx.failures.push({ file: ctx.file, name: `${scope.name || "file"} afterAll`, error: e });
                out(`  ${paint(31, "✗")} afterAll hook\n${describeError(e)}\n`);
            }
        }
    }
}

export async function __run(args) {
    let filter = "";
    const files = [];
    for (const a of args) {
        if (a.startsWith("--filter=")) filter = a.slice(9);
        else files.push(a);
    }
    const started = performance.now();
    const ctx = { filter, only: false, passed: 0, failed: 0, skipped: 0, failures: [], file: "" };
    const cwd = bk.cwd();
    const loaded = [];
    for (const file of files) {
        current = { root: newScope("", null, ""), file };
        current.scope = current.root;
        try {
            await import(file);
            loaded.push(current);
        } catch (e) {
            ctx.failed++;
            ctx.failures.push({ file, name: "(loading the file)", error: e });
            loaded.push({ ...current, loadError: e });
        }
        current = null;
    }
    ctx.only = loaded.some((f) => anyOnly(f.root));
    for (const f of loaded) {
        ctx.file = f.file;
        const shown = f.file.startsWith(cwd + "/") ? f.file.slice(cwd.length + 1) : f.file;
        out(`${paint(1, shown)}\n`);
        if (f.loadError) {
            out(`  ${paint(31, "✗")} could not load\n${describeError(f.loadError)}\n`);
            continue;
        }
        await runScope(f.root, ctx, "");
    }
    if (!files.length) out("no test files found\n");
    const summary = [
        paint(ctx.failed ? 31 : 32, `${ctx.passed} passed`),
        ctx.failed ? paint(31, `${ctx.failed} failed`) : "",
        ctx.skipped ? paint(33, `${ctx.skipped} skipped`) : "",
    ].filter(Boolean).join(", ");
    if (ctx.failures.length) {
        out(`\n${paint(31, "failures:")}\n`);
        for (const f of ctx.failures) out(`  ${f.file.startsWith(cwd + "/") ? f.file.slice(cwd.length + 1) : f.file}: ${f.name}\n`);
    }
    out(`\n${summary} ${paint(2, `(${ms(performance.now() - started)})`)}\n`);
    // Servers, sockets and timers the tests left open do not hold the run.
    bk.exit(ctx.failed || !files.length ? 1 : 0);
}
