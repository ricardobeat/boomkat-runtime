// bun equivalent of src/main.c3: same handler, same response shape.
function handler(method, url) {
    return method + " " + url;
}

const port = Number(process.argv[2] || 8080);
Bun.serve({
    port,
    hostname: "127.0.0.1",
    fetch(req) {
        // Bun hands over an absolute URL; the C3 server sees the request
        // target, so strip the origin to compare like for like.
        const url = new URL(req.url);
        const body = handler(req.method, url.pathname);
        return new Response(body, {
            headers: { "content-type": "text/plain" },
        });
    },
});
console.log(`bun listening on http://127.0.0.1:${port}`);
