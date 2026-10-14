import { serve } from "http";
import { args, main } from "process";
import { readText } from "file";

const text = (value, status = 200) => new Response(value, { status });
const json = value => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
const fixed = text("cached", 201);
const staticHeaders = new Headers({ "x-static": "yes", "content-length": "999", "transfer-encoding": "chunked" });
staticHeaders.append("set-cookie", "a=1");
staticHeaders.append("set-cookie", "b=2");
// Starting after await must retain the server ID used by error callbacks.
await readText(main);
const server = serve({
    hostname: "127.0.0.1", port: Number(args[0]),
    static: { "/legacy-static": new Response("legacy", { headers: staticHeaders }) },
    routes: {
        "/static-headers": new Response("static", { status: 201, statusText: "Custom", headers: staticHeaders }),
        "/static-empty": new Response(null, { status: 204, headers: staticHeaders }),
        "/static-unmodified": new Response(null, { status: 304, headers: staticHeaders }),
        "/static-large": new Response("x".repeat(2 * 1024 * 1024), { headers: { "x-large": "y".repeat(32768) } }),
        "/items/:id": {
            GET: req => json({ id: req.params.id, query: new URL(req.url).search }),
            POST: async req => {
                const body = await req.text();
                await new Promise(resolve => setTimeout(resolve, 2));
                return json({ id: req.params.id, body });
            },
        },
        "/items/new": { GET: text("exact") },
        "/pairs/:first/:second": req => json(req.params),
        "/special/:__proto__/:constructor": req => json(req.params),
        "/api/*": text("wildcard"),
        "/api/:id": req => text("parameter:" + req.params.id),
        "/api/exact": text("exact-api"),
        "/method": { GET: () => text("get"), POST: text("post", 202), DELETE: () => text("delete") },
        "/cached": fixed,
        "/bytes": { POST: new Response(new Uint8Array([0, 1, 255])) },
        "/async/:id": async req => {
            await new Promise(resolve => setTimeout(resolve, 2));
            return text(req.params.id);
        },
        "/headers/:kind": req => {
            const h = new Headers({ "x-first": "one", "x-delete": "gone" });
            h.delete("x-delete"); h.set("x-second", "two");
            const response = new Response("headers", { headers: h });
            if (req.params.kind === "iterator") response.headers._map[Symbol.iterator] = function* () { yield ["x-custom", "iterator"]; };
            if (req.params.kind === "header-method") response.headers._blob = () => "x-custom\nheader-method\n";
            if (req.params.kind === "response-method") response._blob = () => "x-custom\nresponse-method\n";
            if (req.params.kind === "cookies") { response.headers.append("set-cookie", "a=1"); response.headers.append("set-cookie", "b=2"); }
            if (req.params.kind === "instance-guard") Object.defineProperty(Response, Symbol.hasInstance, { configurable: true, get() {
                delete Response[Symbol.hasInstance]; response.headers.set("x-classified", "yes");
                return Function.prototype[Symbol.hasInstance];
            } });
            return response;
        },
        "/throw/:id": () => { throw new Error("route error"); },
        "/reject/:id": async () => { throw new Error("async route error"); },
        "/disabled": false,
    },
    fetch: () => text("fallback", 404),
    error: e => text(e.message, 503),
    onListen: () => console.log("READY"),
});
// Invalid route definitions must fail before binding any sockets.
for (const routes of [null, [], { "bad": text("bad") }, { "/:id/:id": text("bad") }, { "/x": { BAD: () => text("bad") } }, { "/x": {} }]) {
    let rejected = false;
    try { serve({ hostname: "127.0.0.1", port: Number(args[0]), routes }); } catch (e) { rejected = e instanceof TypeError; }
    if (!rejected) throw new Error("invalid routes accepted");
}
