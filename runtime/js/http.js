const bk = __bk;

export function serve(opts, fetch) {
    if (typeof opts === "function") [opts, fetch] = [{}, opts];
    opts = opts || {};
    fetch = fetch || opts.fetch;
    if (typeof fetch !== "function") throw new TypeError("serve() needs a fetch handler");
    const hostname = opts.hostname === undefined ? "0.0.0.0" : String(opts.hostname);
    const port = opts.port === undefined ? 8080 : opts.port | 0;
    const h = { fetch, error: opts.error, server: null };
    const index = bk.addHandler(h);
    const bound = bk.serve(index, hostname, port);
    if (opts.static) {
        for (const [path, res] of Object.entries(opts.static)) {
            if (!(res instanceof Response)) throw new TypeError(`static route ${path} must be a Response`);
            const b = res._body;
            if (b instanceof ReadableStream) throw new TypeError(`static route ${path} cannot stream`);
            bk.staticRoute(index, path, res.status, res.status === 200 ? "" : res.statusText, res._blob(), b === null ? "" : b);
        }
    }
    let closed;
    const finished = new Promise((r) => { closed = r; });
    const server = {
        hostname,
        port: bound,
        url: new URL(`http://${hostname === "0.0.0.0" ? "localhost" : hostname}:${bound}/`),
        finished,
        stop(force = false) {
            bk.stop(index, force);
            closed();
            return Promise.resolve();
        },
    };
    h.server = server;
    bk.fetchFor(index, fetch, server);
    if (opts.onListen) opts.onListen(server);
    return server;
}
