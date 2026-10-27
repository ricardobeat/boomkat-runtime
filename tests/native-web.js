// Observable results are compared with native-web.expected.json. Pass "update"
// (with --allow-write) to rewrite it after an intended change, or "stress" for
// fewer GC-churn URLs.
import { write } from "file";
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
for (const blob of ["", "ignored", "X-One\n first \nX-One\nsecond\nX-Two\n\ttrim\r\n", "key\n", "\n", "a\nb\nc", "x\n\bno trim\0\n", "x\né😀\n", "Set-Cookie\na=1\nset-cookie\nb=2\n"]) {
    observe("Headers parse " + JSON.stringify(blob), () => {
        const h=Headers._fromBlob(blob);
        return [h._blob(),h.get("x-one"),h.getSetCookie(),Object.keys(h),h instanceof Headers];
    });
}
observe("Headers parse large map and mutations",()=>{
    let blob="";for(let i=0;i<100;i++)blob+=`X-${i}\nv${i}\n`;
    const h=Headers._fromBlob(blob);
    h.set("x-5","updated");h.delete("x-7");h.append("x-99","last");h.set("x-new","new");
    return [h._map.size,h.get("x-5"),h.get("x-7"),h.get("x-99"),h.get("x-new"),h._blob()];
});
observe("Headers parse Map constructor patch",()=>{
    const saved=globalThis.Map;let calls=0;
    try {globalThis.Map=class extends saved{constructor(){super();calls++;}};return [Headers._fromBlob("x\ny\n")._blob(),calls];}
    finally{globalThis.Map=saved;}
});
observe("Headers parse String patch",()=>{
    const saved=globalThis.String;let calls=0;
    try {globalThis.String=function(value){calls++;return saved(value);};return [Headers._fromBlob("x\ny\n")._blob(),calls];}
    finally{globalThis.String=saved;}
});
for(const method of ["split","toLowerCase","trim"]){
    observe("Headers parse String method patch "+method,()=>{
        const saved=String.prototype[method];let calls=0;
        try {String.prototype[method]=function(...args){calls++;return saved.apply(this,args);};return [Headers._fromBlob("X\n y \n")._blob(),calls];}
        finally{String.prototype[method]=saved;}
    });
}
for(const method of ["get","set"]){
    observe("Headers parse Map method patch "+method,()=>{
        const saved=Map.prototype[method];let calls=0;
        try {Map.prototype[method]=function(...args){calls++;return saved.apply(this,args);};return [Headers._fromBlob("x\ny\nx\nz\n")._blob(),calls];}
        finally{Map.prototype[method]=saved;}
    });
}
observe("Headers parse append patch",()=>{
    const saved=Headers.prototype.append;let calls=0;
    try {Headers.prototype.append=function(...args){calls++;return saved.apply(this,args);};return [Headers._fromBlob("x\ny\n")._blob(),calls];}
    finally{Headers.prototype.append=saved;}
});
observe("Headers parse append getter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Headers.prototype,"append");let calls=0;
    try {Object.defineProperty(Headers.prototype,"append",{configurable:true,get(){calls++;return saved.value;}});return [Headers._fromBlob("x\ny\n")._blob(),calls];}
    finally{Object.defineProperty(Headers.prototype,"append",saved);}
});
observe("Headers parse field setter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Headers.prototype,"_map");let calls=0;
    try {Object.defineProperty(Headers.prototype,"_map",{configurable:true,set(v){calls++;Object.defineProperty(this,"_map",{value:v,writable:true,configurable:true,enumerable:true});}});return [Headers._fromBlob("x\ny\n")._blob(),calls];}
    finally{if(saved)Object.defineProperty(Headers.prototype,"_map",saved);else delete Headers.prototype._map;}
});
observe("Headers parse malformed argument",()=>Headers._fromBlob(42));
observe("Headers parse custom split",()=>Headers._fromBlob({split(){return ["x","object"];}})._blob());
observe("Headers parse metadata",()=>[Headers._fromBlob.name,Headers._fromBlob.length]);
for (let i = 0; i < (args[0] === "stress" ? 300 : 30000); i++) new URL("http://example.com/churn?" + i);
observe("retained after churn", () => [new URL("http://example.com/a").pathname, new Response("x")._body]);

observe("Headers record ASCII",()=>{
    const h=new Headers({"X-Test":" \t first \r\n", "x-test":"second", "x-empty":""});
    return [h._blob(),h.get("x-test"),h.get("x-empty"),h._map.size];
});
observe("Headers record null prototype",()=>{
    const o=Object.create(null);o[2]="two";o[1]="one";o["X-Name"]="yes";
    Object.defineProperty(o,"hidden",{value:"ignored"});o[Symbol("secret")]="ignored";
    return new Headers(o)._blob();
});
observe("Headers record non-ASCII",()=>new Headers({"X-Name":"\u00a0 café 😀 \u00a0"})._blob());
observe("Headers record getters and conversion",()=>{
    const calls=[];const o={a:"one",b:{toString(){calls.push("convert");return " two ";}}};
    Object.defineProperty(o,"c",{enumerable:true,get(){calls.push("get");return "three";}});
    return [new Headers(o)._blob(),calls];
});
observe("Headers record Object.keys patch",()=>{
    const saved=Object.keys;let calls=0;
    try {Object.keys=()=>{calls++;return ["b","a"];};return [new Headers({a:"one",b:"two"})._blob(),calls];}
    finally{Object.keys=saved;}
});
observe("Headers record Object replacement",()=>{
    const saved=Object;
    try {globalThis.Object={keys:saved.keys};return new Headers({x:"y"})._blob();}
    finally{globalThis.Object=saved;}
});
observe("Headers record Symbol replacement",()=>{
    const saved=Symbol;let calls=0;const o={x:"y"};
    Object.defineProperty(o,"probe",{get(){calls++;return undefined;}});
    try {globalThis.Symbol={iterator:"probe"};return [new Headers(o)._blob(),calls];}
    finally{globalThis.Symbol=saved;}
});
observe("Headers record iterator getter",()=>{
    let calls=0;const o={x:"y"};
    Object.defineProperty(o,Symbol.iterator,{get(){calls++;return undefined;}});
    return [new Headers(o)._blob(),calls];
});
observe("Headers record custom iterator",()=>{
    const o={x:"ignored",*[Symbol.iterator](){yield ["X-One","one"];yield ["x-two","two"];}};
    return new Headers(o)._blob();
});
observe("Headers record array iterator patch",()=>{
    const key=Symbol.iterator,saved=Array.prototype[key];
    try {Array.prototype[key]=function*(){yield "b";};return new Headers({a:"one",b:"two"})._blob();}
    finally{Array.prototype[key]=saved;}
});
observe("Headers record array next getter",()=>{
    const proto=Object.getPrototypeOf([][Symbol.iterator]());const saved=Object.getOwnPropertyDescriptor(proto,"next");let calls=0;
    try {Object.defineProperty(proto,"next",{configurable:true,get(){calls++;return saved.value;}});return [new Headers({x:"y"})._blob(),calls];}
    finally{Object.defineProperty(proto,"next",saved);}
});
observe("Headers record instance getter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Headers,Symbol.hasInstance);let calls=0;
    try {Object.defineProperty(Headers,Symbol.hasInstance,{configurable:true,get(){calls++;return Function.prototype[Symbol.hasInstance];}});return [new Headers({x:"y"})._blob(),calls];}
    finally{if(saved)Object.defineProperty(Headers,Symbol.hasInstance,saved);else delete Headers[Symbol.hasInstance];}
});
for (const method of ["toLowerCase","trim"]) {
    observe("Headers record string getter "+method,()=>{
        const saved=Object.getOwnPropertyDescriptor(String.prototype,method);let calls=0;
        try {Object.defineProperty(String.prototype,method,{configurable:true,get(){calls++;return saved.value;}});return [new Headers({X:" y ",Y:" z "})._blob(),calls];}
        finally{Object.defineProperty(String.prototype,method,saved);}
    });
}
observe("Headers record String replacement",()=>{
    const saved=String;let calls=0;
    try {globalThis.String=value=>{calls++;return saved(value);};return [new Headers({x:"y"})._blob(),calls];}
    finally{globalThis.String=saved;}
});
observe("Headers record Map.set getter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Map.prototype,"set");let calls=0;
    try {Object.defineProperty(Map.prototype,"set",{configurable:true,get(){calls++;return saved.value;}});return [new Headers({x:"y",a:"b"})._blob(),calls];}
    finally{Object.defineProperty(Map.prototype,"set",saved);}
});
observe("Headers record cookie append getter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Headers.prototype,"append");let calls=0;
    try {Object.defineProperty(Headers.prototype,"append",{configurable:true,get(){calls++;return saved.value;}});const h=new Headers({x:"y","Set-Cookie":"a=1"});return [h._blob(),h.getSetCookie(),calls];}
    finally{Object.defineProperty(Headers.prototype,"append",saved);}
});
observe("Headers record receiver setter",()=>{
    const saved=Object.getOwnPropertyDescriptor(Headers.prototype,"_map");let calls=0;
    try {Object.defineProperty(Headers.prototype,"_map",{configurable:true,set(value){calls++;Object.defineProperty(this,"_map",{value,writable:true,configurable:true,enumerable:true});}});return [new Headers({x:"y"})._blob(),calls];}
    finally{if(saved)Object.defineProperty(Headers.prototype,"_map",saved);else delete Headers.prototype._map;}
});

const actual = rows.map(row => JSON.stringify(row));
if (args[0] === "update") {
    await write(import.meta.url.replace(/\.js$/, ".expected.json"), "[\n" + actual.join(",\n") + "\n]\n");
    console.log(`native-web: wrote ${actual.length} cases`);
} else {
    const { default: expectedRows } = await import("./native-web.expected.json", { with: { type: "json" } });
    const expected = expectedRows.map(row => JSON.stringify(row));
    const failures = [];
    for (let i = 0; i < Math.max(actual.length, expected.length); i++) {
        if (actual[i] !== expected[i]) failures.push(`  expected ${expected[i]}\n  actual   ${actual[i]}`);
    }
    if (failures.length) throw new Error(`native-web: ${failures.length} cases differ\n${failures.join("\n")}`);
    console.log(`native-web: ${actual.length} cases passed`);
}
