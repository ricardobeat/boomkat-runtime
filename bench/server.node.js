// node equivalent of src/main.c3: same handler, same response shape.
const http = require("http");

function handler(method, url) {
    return method + " " + url;
}

const port = Number(process.argv[2] || 8080);
http.createServer((req, res) => {
    const body = handler(req.method, req.url);
    res.writeHead(200, {
        "content-type": "text/plain",
        "content-length": Buffer.byteLength(body),
    });
    res.end(body);
}).listen(port, "127.0.0.1", () => {
    console.log(`node listening on http://127.0.0.1:${port}`);
});
