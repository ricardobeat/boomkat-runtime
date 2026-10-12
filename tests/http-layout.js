import { serve } from "http";
import { args } from "process";

const descriptors = Object.getOwnPropertyDescriptors(Response.prototype);
let retained;
let accessorReads = 0;
function reset() {
    for (const key of ["status", "_headers", "_used", "_ct", "_body"])
        Object.defineProperty(Response.prototype, key, descriptors[key]);
}
serve({
    port: Number(args[0]), hostname: "127.0.0.1", onListen() {},
    fetch(req) {
        const path = new URL(req.url).pathname;
        if (path === "/warm") return new Response("warm");
        if (path === "/reset") { reset(); return new Response("reset"); }
        if (path === "/status") { Response.prototype.status = 201; return new Response("status"); }
        if (path === "/content-type") {
            Response.prototype._ct = "application/json";
            return new Response("type");
        }
        if (path === "/accessor") {
            Object.defineProperty(Response.prototype, "_ct", {
                configurable: true, get() { accessorReads++; return "application/json"; }
            });
            return new Response("accessor");
        }
        if (path === "/accessor-count") {
            reset(); return new Response(String(accessorReads));
        }
        if (path === "/grow") {
            const r = new Response("initial");
            for (let i = 0; i < 80; i++) r["extra" + i] = i;
            r._body = "grown";
            return r;
        }
        if (path === "/own-accessor") {
            const r = new Response("initial");
            Object.defineProperty(r, "_body", { configurable: true, get() { return "own"; } });
            return r;
        }
        if (path === "/prototype") {
            const r = new Response("initial");
            Object.setPrototypeOf(r, Object.create(Response.prototype));
            r._body = "prototype";
            return r;
        }
        if (path === "/used") { const r = new Response("used"); r._used = true; return r; }
        if (path === "/capture") {
            retained = req;
            // A request's own layout must remain independent of future ones.
            req.extra = 1;
            Object.defineProperty(req, "method", { configurable: true, value: "changed" });
            return new Response("captured");
        }
        if (path === "/inspect") {
            return Response.json({
                path: new URL(retained.url).pathname,
                search: new URL(retained.url).search,
                host: new URL(retained.url).host,
                header: retained.headers.get("x-layout"), method: retained.method,
                currentMethod: req.method, currentExtra: req.extra === undefined,
                keys: Object.keys(req).join(",")
            });
        }
        if (path === "/churn") {
            for (let i = 0; i < (args[1] === "stress" ? 300 : 30000); i++) {
                const r = new Response("garbage" + i);
                r["p" + (i % 32)] = i;
            }
            return new Response("churn");
        }
        if (path === "/echo") return req.bytes().then(b => new Response(b));
        return new Response("ok");
    }
});
