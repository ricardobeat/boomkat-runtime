// A fetch response whose body is never read, or read only in part, must not
// keep the process alive. Each client runs in a child bkr that has to exit on
// its own; this process serves the bodies it fetches.
// Run: bkr --no-sandbox --allow-net --allow-run fetch-unread.js
import { serve } from "http";
import { execPath, exit, spawn } from "process";
import { remove, writeText } from "file";

const endless = () => new ReadableStream({
    pull(c) { c.enqueue(new Uint8Array(16 * 1024)); return new Promise(r => setTimeout(r, 5)); },
});
const server = serve({
    port: 0,
    hostname: "127.0.0.1",
    routes: {
        "/endless": () => new Response(endless()),
        "/large": () => new Response("x".repeat(1 << 20)),
        "/gzip": () => new Response(endless().pipeThrough(new CompressionStream("gzip")), { headers: { "content-encoding": "gzip" } }),
    },
});
await server.ready;
const base = `http://127.0.0.1:${server.port}`;

const cases = {
    "unread endless body": `
        const r = await fetch("${base}/endless");
        console.log(r.status);`,
    "unread body larger than the socket buffers": `
        const r = await fetch("${base}/large");
        console.log(r.status);`,
    "one chunk of an endless body": `
        const r = await fetch("${base}/endless");
        const reader = r.body.getReader();
        console.log((await reader.read()).value.length > 0);`,
    "awaited body with nothing else running": `
        const r = await fetch("${base}/large");
        console.log((await r.text()).length);`,
    "one chunk of an endless gzip body": `
        const r = await fetch("${base}/gzip");
        const reader = r.body.getReader();
        console.log((await reader.read()).value.length > 0);`,
    "timer still runs after an unread body": `
        await fetch("${base}/endless");
        setTimeout(() => console.log("timer"), 50);`,
};
const expected = {
    "unread endless body": "200",
    "unread body larger than the socket buffers": "200",
    "one chunk of an endless body": "true",
    "awaited body with nothing else running": String(1 << 20),
    "one chunk of an endless gzip body": "true",
    "timer still runs after an unread body": "timer",
};

const failures = [];
for (const [name, source] of Object.entries(cases)) {
    const path = `/tmp/bkr-fetch-unread-${Date.now()}.js`;
    await writeText(path, source);
    const child = spawn(execPath, { args: ["--no-sandbox", "-A", path], stdout: "piped", stderr: "piped" });
    let timer;
    const timedOut = new Promise(r => { timer = setTimeout(() => { child.kill(9); r("timeout"); }, 3000); });
    const drain = async (h) => {
        const parts = [];
        for (let c; (c = await h.read()) !== null;) parts.push(c);
        return new TextDecoder().decode(await new Blob(parts).bytes()).trim();
    };
    const [out, status] = await Promise.all([drain(child.stdout), Promise.race([child.status, timedOut])]);
    clearTimeout(timer);
    await remove(path);
    if (status === "timeout") failures.push(`${name}: did not exit`);
    else if (out !== expected[name]) failures.push(`${name}: printed ${JSON.stringify(out)}`);
}

await server.stop(true);
if (failures.length) {
    console.error("fetch-unread failed:\n  " + failures.join("\n  "));
    exit(1);
}
console.log(`fetch-unread: ${Object.keys(cases).length} cases passed`);
