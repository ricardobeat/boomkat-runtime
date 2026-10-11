import { serve } from "http";
import * as file from "file";
import { args } from "process";

const [port, payload] = args;
const chunk = new TextEncoder().encode("x".repeat(1024));
const data = { id: 1, name: "boomkat", tags: ["a", "b", "c"], nested: { ok: true, n: 42.5 } };

serve({
    port: Number(port),
    hostname: "127.0.0.1",
    onListen() {},
    async fetch(req) {
        const path = new URL(req.url).pathname;
        switch (path) {
            case "/hello": return new Response("hello world");
            case "/json": return Response.json(data);
            case "/async": {
                await Promise.resolve();
                await new Promise((r) => setTimeout(r, 0));
                return Response.json({ ok: true });
            }
            case "/echo": return new Response(await req.bytes());
            case "/stream": {
                let n = 0;
                return new Response(new ReadableStream({
                    pull(c) {
                        if (n++ === 8) c.close();
                        else c.enqueue(chunk);
                    },
                }));
            }
            case "/file": return new Response(await file.read(payload));
        }
        return new Response("not found", { status: 404 });
    },
});
