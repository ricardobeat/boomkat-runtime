// Observable results are compared with the unchanged runtime by run_native_web.py.
import { args } from "process";
const rows = [];
function observe(name, fn) {
    try { rows.push([name, fn()]); }
    catch (e) { rows.push([name, "throw", e.name]); }
}
function urlView(u) {
    return [u.pathname, u.href, u.protocol, u.host, u.search, u.hash,
            Object.keys(u), u instanceof URL, u.constructor === URL];
}
for (const text of ["http://example.com", "http://example.com/", "https://example.com:443/a?b=c",
                    "http://example.com:8080/a/b?", "http://EXAMPLE.com/a#b", "http://user:pass@example.com/a",
                    "http://example.com/a/../b", "http://example.com/.", "http://example.com/..",
                    "http://example.com/café😀?q=1", "mailto:a@example.com",
                    "http:///bad", "bad", "http://example.com/a/%2e%2e/b"]) {
    observe(text, () => urlView(new URL(text)));
}
observe("relative", () => urlView(new URL("../c?q=1", "http://example.com/a/b")));
observe("coercion", () => {
    const order = [];
    const u = new URL({ toString() { order.push("url"); return "http://example.com/a"; } },
                      { toString() { order.push("base"); return "http://base.com/"; } });
    return [u.pathname, order];
});
observe("URL subclass", () => {
    class Child extends URL { constructor(...args) { super(...args); this.extra = 1; } }
    const u = new Child("http://example.com/a?x=1");
    return [u.pathname, u instanceof Child, u instanceof URL, u.constructor === Child, u.extra];
});
observe("URL foreign new.target", () => {
    function Other() {}
    Other.prototype = Object.create(URL.prototype);
    const u = Reflect.construct(URL, ["http://example.com/a"], Other);
    return [u.pathname, Object.getPrototypeOf(u) === Other.prototype];
});
observe("URL plain call", () => URL("http://example.com/a"));
observe("native installation invalid input", () => __bk.nativeClass("bad", null, "URL"));
observe("native installation repeated", () => __bk.nativeClass(URL, () => {}, "URL", String));
observe("URL static factories", () => [URL.canParse("http://example.com/a"), URL.canParse("bad"),
                                        URL.parse("http://example.com/a").pathname, URL.parse("bad")]);
observe("URL public mutations", () => {
    const u = new URL("http://example.com/a?x=1");
    u.pathname = "/changed"; u.search = "?y=2";
    return [u.pathname, u.href];
});
const pathGetter = Object.getOwnPropertyDescriptor(URL.prototype, "pathname").get;
observe("URL accessor fields", () => {
    const order = [];
    const u = new URL("http://example.com/a?x=1");
    const f = u._f;
    Object.defineProperty(u, "_raw", { get() { order.push("raw"); return "http://example.com/a?x=1"; } });
    Object.defineProperty(u, "_f", { get() { order.push("flags"); return f; } });
    return [u.pathname, order];
});
observe("URL proxy receiver", () => {
    const order = [];
    const u = new URL("http://example.com/a");
    const proxy = new Proxy(u, { get(target, key, receiver) {
        order.push(key); return Reflect.get(target, key, receiver);
    } });
    return [pathGetter.call(proxy), order];
});
for (const flags of [-1, 1.5, NaN, Infinity, 65535, 4294967295, 9007199254740991])
    observe("URL altered flags " + flags, () => pathGetter.call({ _raw: "http://example.com/a", _f: flags }));
observe("URL altered raw", () => pathGetter.call({ _raw: 1, _f: 0 }));
observe("URL slice patch", () => {
    const saved = String.prototype.slice;
    try {
        String.prototype.slice = function () { return "patched"; };
        return new URL("http://example.com/a").pathname;
    } finally { String.prototype.slice = saved; }
});
observe("URL String patch", () => {
    const saved = globalThis.String;
    try {
        globalThis.String = function () { return "http://example.com/changed"; };
        return new URL("http://example.com/a").pathname;
    } finally { globalThis.String = saved; }
});
observe("URL parser patch", () => {
    const saved = __bk.urlFast;
    let calls = 0;
    try {
        __bk.urlFast = function (u) { calls++; return saved(u); };
        return [new URL("http://example.com/a").pathname, calls];
    } finally { __bk.urlFast = saved; }
});
for (const key of ["_raw", "_f"]) {
    observe("URL prototype setter " + key, () => {
        const saved = Object.getOwnPropertyDescriptor(URL.prototype, key);
        const calls = [];
        try {
            Object.defineProperty(URL.prototype, key, { configurable: true, set(v) { calls.push(v); } });
            const u = new URL("http://example.com/a");
            return [calls, Object.keys(u)];
        } finally { Object.defineProperty(URL.prototype, key, saved); }
    });
}
function responseView(r) {
    const keys = Object.keys(r);
    return [r.status, r.statusText, r.headers.get("content-type"), keys,
            typeof r._body === "string" ? r._body : r._body === null ? null : "object",
            r instanceof Response, r.constructor === Response];
}
for (const [name, body, init] of [["string", "café😀", undefined], ["null", null, undefined],
                                ["missing", undefined, undefined], ["bytes", new Uint8Array([1, 2]), undefined],
                                ["null init", "x", null], ["options", "x", { status: 201, headers: { "x-test": "yes" } }],
                                ["invalid status", "x", { status: 600 }], ["coerce body", 42, undefined]])
    observe("Response " + name, () => responseView(new Response(body, init)));
observe("Response json", () => responseView(Response.json({ x: 1 })));
observe("Response plain call", () => Response("x"));
observe("Response subclass", () => {
    class Child extends Response { constructor(body) { super(body); this.extra = true; } }
    const r = new Child("x");
    return [r instanceof Child, r instanceof Response, r.constructor === Child, r.extra, r._body];
});
observe("Response foreign new.target", () => {
    function Other() {}
    Other.prototype = Object.create(Response.prototype);
    const r = Reflect.construct(Response, ["x"], Other);
    return [r._body, Object.getPrototypeOf(r) === Other.prototype];
});
observe("Response Uint8Array patch", () => {
    const saved = globalThis.Uint8Array;
    const order = [];
    try {
        globalThis.Uint8Array = { [Symbol.hasInstance](v) { order.push(v); return true; } };
        const r = new Response("x");
        return [r._ct, r._body, order];
    } finally { globalThis.Uint8Array = saved; }
});
observe("Response custom hasInstance", () => {
    const saved = Object.getOwnPropertyDescriptor(Uint8Array, Symbol.hasInstance);
    const order = [];
    try {
        Object.defineProperty(Uint8Array, Symbol.hasInstance, { configurable: true, value(v) { order.push(v); return true; } });
        const r = new Response("x");
        return [r._ct, r._body, order];
    } finally {
        if (saved) Object.defineProperty(Uint8Array, Symbol.hasInstance, saved);
        else delete Uint8Array[Symbol.hasInstance];
    }
});
observe("Response proxy body", () => {
    const order = [];
    const body = new Proxy(new Uint8Array([1]), { getPrototypeOf(target) {
        order.push("prototype"); return Reflect.getPrototypeOf(target);
    } });
    const r = new Response(body);
    return [r._body === body, r._ct, order];
});
for (const [name, ctor] of [["stream", ReadableStream], ["file", __bk.FileBody]]) {
    observe("Response " + name + " hasInstance", () => {
        const saved = Object.getOwnPropertyDescriptor(ctor, Symbol.hasInstance);
        const order = [];
        try {
            Object.defineProperty(ctor, Symbol.hasInstance, { configurable: true, value(v) { order.push(v); return true; } });
            const r = new Response("x");
            return [r._body, r._ct, order];
        } finally {
            if (saved) Object.defineProperty(ctor, Symbol.hasInstance, saved);
            else delete ctor[Symbol.hasInstance];
        }
    });
}
for (const [name, body] of [["stream", new ReadableStream({ start(c) { c.close(); } })],
                           ["file", new __bk.FileBody("payload")]])
    observe("Response " + name + " body", () => [new Response(body)._body === body, new Response(body)._ct]);
for (const key of ["_body", "_ct"]) {
    observe("Response prototype setter " + key, () => {
        const saved = Object.getOwnPropertyDescriptor(Response.prototype, key);
        const calls = [];
        try {
            Object.defineProperty(Response.prototype, key, { configurable: true, set(v) { calls.push(v); } });
            const r = new Response(key === "_body" ? "x" : null);
            return [calls, Object.keys(r)];
        } finally { Object.defineProperty(Response.prototype, key, saved); }
    });
}
for (const [ctor, key, args] of [[URL, "_raw", ["http://example.com/a"]],
                               [Response, "_body", ["x"]], [Response, "_ct", [null]]]) {
    observe(ctor.name + " readonly " + key, () => {
        const saved = Object.getOwnPropertyDescriptor(ctor.prototype, key);
        try {
            Object.defineProperty(ctor.prototype, key, { ...saved, writable: false });
            return Reflect.construct(ctor, args);
        } finally { Object.defineProperty(ctor.prototype, key, saved); }
    });
}
observe("Headers blob order and mutations", () => {
    const h = new Headers({"X-One":" first ", "x-two":"second"});
    const first = h._blob();
    h.append("X-One", "third"); h.delete("x-two"); h.set("x-last", "last");
    return [first, h._blob(), new Headers()._blob(), h._blob.name, h._blob.length];
});
observe("Headers blob Unicode and NUL", () => new Headers({"x-text":"é😀\0\ud800"})._blob());
observe("Headers blob cookies", () => {
    const h = new Headers({"x-first":"yes"});
    h.append("set-cookie", "one=1"); h.append("set-cookie", "two=2");
    return h._blob();
});
observe("Headers blob borrowed receiver", () => Headers.prototype._blob.call({_map:new Map([["x","yes"]]),_cookies:null}));
observe("Headers blob numeric map values", () => {
    const h = new Headers(); h._map.set("x-number", 17); return h._blob();
});
observe("Headers blob Symbol value", () => {
    const h = new Headers(); h._map.set("x-symbol", Symbol()); return h._blob();
});
observe("Headers blob iterator and cookies order", () => {
    const h = new Headers(), order=[];
    h._map[Symbol.iterator] = function* () { order.push("iterator"); yield ["x","yes"]; order.push("end"); };
    Object.defineProperty(h,"_cookies",{get(){order.push("cookies");return null;}});
    return [h._blob(), order];
});
observe("Headers blob Map iterator override", () => {
    const saved=Map.prototype[Symbol.iterator]; let calls=0;
    try {
        Map.prototype[Symbol.iterator]=function*(){calls++;yield ["changed","yes"];};
        return [new Headers({x:"original"})._blob(), calls];
    } finally {Map.prototype[Symbol.iterator]=saved;}
});
observe("Headers blob Map iterator next override", () => {
    const proto=Object.getPrototypeOf(new Map().entries()),saved=proto.next;let calls=0;
    try {
        proto.next=function(){calls++;return {done:true};};
        return [new Headers({x:"original"})._blob(),calls];
    } finally {proto.next=saved;}
});
observe("Headers blob Map iterator next getter", () => {
    const proto=Object.getPrototypeOf(new Map().entries()),saved=Object.getOwnPropertyDescriptor(proto,"next");let calls=0;
    try {
        Object.defineProperty(proto,"next",{configurable:true,get(){calls++;return saved.value;}});
        return [new Headers({x:"original"})._blob(),calls];
    } finally {Object.defineProperty(proto,"next",saved);}
});
observe("Headers blob accessor fields", () => {
    const h=new Headers({x:"original"}),map=h._map,order=[];
    Object.defineProperty(h,"_map",{get(){order.push("map");return map;}});
    Object.defineProperty(h,"_cookies",{get(){order.push("cookies");return null;}});
    return [h._blob(),order];
});
observe("Headers blob proxy receiver", () => {
    const h=new Headers({x:"original"}),order=[];
    const proxy=new Proxy(h,{get(target,key,receiver){order.push(key);return Reflect.get(target,key,receiver);}});
    return [Headers.prototype._blob.call(proxy),order];
});
observe("Headers blob proxy map", () => {
    const h=new Headers(),order=[];
    h._map=new Proxy(new Map(),{get(target,key){order.push(String(key));if(key===Symbol.iterator)return function*(){yield ["x","proxy"];};return Reflect.get(target,key);}});
    return [h._blob(),order];
});
observe("Headers blob throwing iterator", () => {
    const h=new Headers(),error=new Error("iterator stopped");
    h._map[Symbol.iterator]=()=>{throw error;};
    try{h._blob();}catch(caught){return caught===error;}
});
for (let i = 0; i < (args[0] === "stress" ? 300 : 30000); i++) new URL("http://example.com/churn?" + i);
observe("retained after churn", () => [new URL("http://example.com/a").pathname, new Response("x")._body]);
console.log(JSON.stringify(rows));
