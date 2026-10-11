import http from "node:http";
import { readFile } from "node:fs/promises";

const [port, payload] = process.argv.slice(2);
const chunk = Buffer.alloc(1024, "x");
const json = JSON.stringify({ id: 1, name: "boomkat", tags: ["a", "b", "c"], nested: { ok: true, n: 42.5 } });

http.createServer(async (req, res) => {
    switch (req.url) {
        case "/hello":
            res.setHeader("content-type", "text/plain;charset=UTF-8");
            return res.end("hello world");
        case "/json":
            res.setHeader("content-type", "application/json");
            return res.end(json);
        case "/async":
            await Promise.resolve();
            await new Promise((r) => setImmediate(r));
            res.setHeader("content-type", "application/json");
            return res.end('{"ok":true}');
        case "/timer":
            await Promise.resolve();
            await new Promise((r) => setTimeout(r, 0));
            res.setHeader("content-type", "application/json");
            return res.end('{"ok":true}');
        case "/echo": {
            const parts = [];
            for await (const c of req) parts.push(c);
            return res.end(Buffer.concat(parts));
        }
        case "/stream":
            for (let i = 0; i < 8; i++) res.write(chunk);
            return res.end();
        case "/file":
            return res.end(await readFile(payload));
    }
    res.statusCode = 404;
    res.end("not found");
}).listen(Number(port), "127.0.0.1");
