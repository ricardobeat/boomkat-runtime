import { serve } from "http";
import * as file from "file";
import { args } from "process";

const [port, payload] = args;
const chunk = new TextEncoder().encode("x".repeat(1024));
const data = { id: 1, name: "boomkat", tags: ["a", "b", "c"], nested: { ok: true, n: 42.5 } };

const later = () => new Promise((r) => setTimeout(r, 0));

serve({
    port: Number(port),
    hostname: "127.0.0.1",
    onListen() {},
    fetch(req) {
        switch (new URL(req.url).pathname) {
            case "/hello": return new Response("hello world");
            case "/json": return Response.json(data);
            case "/async": return later().then(() => Response.json({ ok: true }));
            case "/echo": return req.bytes().then((b) => new Response(b));
            case "/stream": {
                let n = 0;
                return new Response(new ReadableStream({
                    pull(c) {
                        if (n++ === 8) c.close();
                        else c.enqueue(chunk);
                    },
                }));
            }
            case "/file": return file.read(payload).then((b) => new Response(b));
        }
        return new Response("not found", { status: 404 });
    },
});
