import { serve } from "http";
import { args } from "process";
const chunks = [new Uint8Array(8192), new Uint8Array(1024), new Uint8Array(128)];
serve({ port: Number(args[0]), hostname: "127.0.0.1", onListen() {}, fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/hello") return new Response("hello world");
    if (path === "/bytes") return new Response(chunks[0]);
    const count = path === "/one" ? 1 : path === "/many" ? 64 : 8;
    const chunk = chunks[count === 1 ? 0 : count === 8 ? 1 : 2];
    let n = 0;
    return new Response(new ReadableStream({ pull(c) {
        if (path === "/batch") { for (let i = 0; i < count; i++) c.enqueue(chunk); c.close(); }
        else if (n++ === count) c.close();
        else c.enqueue(chunk);
    } }));
} });
