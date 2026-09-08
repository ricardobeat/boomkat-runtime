// bun equivalent with N processes sharing the port via reusePort.
//
// Bun has no in-process equivalent of node's cluster round-robin, so this is
// the documented approach: spawn N copies and let the kernel distribute. On
// macOS SO_REUSEPORT does not actually balance, which is what this measures.
function handler(method, url) {
    return method + " " + url;
}

const port = Number(process.argv[2] || 8080);
const workers = Number(process.argv[3] || 2);

if (!process.env.BUN_WORKER) {
    const procs = [];
    for (let i = 0; i < workers; i++) {
        procs.push(Bun.spawn({
            cmd: [process.execPath, import.meta.path, String(port), String(workers)],
            env: { ...process.env, BUN_WORKER: String(i) },
            stdout: "inherit",
            stderr: "inherit",
        }));
    }
    console.log(`bun cluster listening on http://127.0.0.1:${port} (${workers} procs)`);
    const stop = () => { for (const p of procs) p.kill(); process.exit(0); };
    process.on("SIGTERM", stop);
    process.on("SIGINT", stop);
    await Promise.all(procs.map((p) => p.exited));
} else {
    Bun.serve({
        port,
        hostname: "127.0.0.1",
        reusePort: true,
        fetch(req) {
            const url = new URL(req.url);
            const body = handler(req.method, url.pathname);
            return new Response(body, { headers: { "content-type": "text/plain" } });
        },
    });
}
