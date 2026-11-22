const [port, payload] = Bun.argv.slice(2);
const chunk = new TextEncoder().encode("x".repeat(1024));
const data = { id: 1, name: "boomkat", tags: ["a", "b", "c"], nested: { ok: true, n: 42.5 } };

Bun.serve({
    port: Number(port),
    hostname: "127.0.0.1",
    async fetch(req) {
        switch (new URL(req.url).pathname) {
            case "/hello": return new Response("hello world");
            case "/json": return Response.json(data);
            case "/async":
                await new Promise((r) => setImmediate(r));
                return Response.json({ ok: true });
            case "/timer":
                await new Promise((r) => setTimeout(r, 0));
                return Response.json({ ok: true });
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
            case "/file": return new Response(Bun.file(payload));
        }
        return new Response("not found", { status: 404 });
    },
});
