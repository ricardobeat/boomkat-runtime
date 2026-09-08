// node equivalent with N workers, for comparison against the 2-thread C3 servers.
//
// cluster's default scheduling on non-Windows is SCHED_RR: the primary accepts
// and hands connections to workers round-robin in userspace. That sidesteps
// macOS's SO_REUSEPORT, which does not balance across sockets.
const cluster = require("cluster");
const http = require("http");

function handler(method, url) {
    return method + " " + url;
}

const port = Number(process.argv[2] || 8080);
const workers = Number(process.argv[3] || 2);

if (cluster.isPrimary) {
    for (let i = 0; i < workers; i++) cluster.fork();
    console.log(`node cluster listening on http://127.0.0.1:${port} (${workers} workers)`);
} else {
    http.createServer((req, res) => {
        const body = handler(req.method, req.url);
        res.writeHead(200, {
            "content-type": "text/plain",
            "content-length": Buffer.byteLength(body),
        });
        res.end(body);
    }).listen(port, "127.0.0.1");
}
