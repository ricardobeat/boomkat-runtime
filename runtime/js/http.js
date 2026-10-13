const bk = __bk;
const methods = new Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT"]);
const notFound = () => new Response("Not Found", { status: 404 });

// Validation and response snapshots happen before binding the listener.
function compileRoutes(routes, fallback) {
    if (routes === undefined) return [];
    if (!routes || typeof routes !== "object" || Array.isArray(routes))
        throw new TypeError("routes must be an object");
    const compiled = [];
    for (const [path, value] of Object.entries(routes)) {
        if (!path.startsWith("/") || /[\0?#]/.test(path))
            throw new TypeError(`invalid route path ${path}`);
        const segments = path.split("/");
        if (segments.length > 100) throw new RangeError("too many route segments");
        const params = [];
        for (let i = 1; i < segments.length; i++) {
            const segment = segments[i];
            if (segment.startsWith(":")) {
                const name = segment.slice(1);
                if (!/^[A-Za-z_$][\w$]*$/.test(name) || params.includes(name))
                    throw new TypeError(`invalid route parameter ${segment}`);
                params.push(name);
            } else if (segment.includes("*") && (segment !== "*" || i !== segments.length - 1)) {
                throw new TypeError("route wildcard must be the final segment");
            }
        }
        function add(method, handler) {
            if (typeof handler === "function") {
                compiled.push({ path, method, handler, params });
            } else if (handler instanceof Response) {
                if (handler.bodyUsed || handler._body instanceof ReadableStream)
                    throw new TypeError(`static route ${path} needs an unused buffered Response`);
                const body = handler._body;
                if (body !== null && typeof body !== "string" && !(body instanceof ArrayBuffer) && !ArrayBuffer.isView(body))
                    throw new TypeError(`static route ${path} needs a buffered body`);
                compiled.push({ path, method, status: handler.status,
                    text: handler.status === 200 ? "" : handler.statusText,
                    headers: handler._blob(), body: body === null ? "" : body });
            } else {
                throw new TypeError(`route ${path} must be a function or Response`);
            }
        }
        if (value === false) {
            add("*", fallback);
        } else if (typeof value === "function" || value instanceof Response) {
            add("*", value);
        } else {
            if (!value || typeof value !== "object" || Array.isArray(value))
                throw new TypeError(`invalid route ${path}`);
            const entries = Object.entries(value);
            if (!entries.length) throw new TypeError(`route ${path} has no method handlers`);
            for (const [method, handler] of entries) {
                if (!methods.has(method)) throw new TypeError(`unsupported route method ${method}`);
                add(method, handler);
            }
            if (value.GET !== undefined && value.HEAD === undefined) add("HEAD", value.GET);
        }
    }
    return compiled;
}

export function serve(opts, fetch) {
    if (typeof opts === "function") [opts, fetch] = [{}, opts];
    opts = opts || {};
    fetch = fetch || opts.fetch;
    if (fetch === undefined && opts.routes !== undefined) fetch = notFound;
    if (typeof fetch !== "function") throw new TypeError("serve() needs a fetch handler or routes");
    const routes = compileRoutes(opts.routes, fetch);
    const statics = [];
    if (opts.static) {
        for (const [path, res] of Object.entries(opts.static)) {
            if (!(res instanceof Response)) throw new TypeError(`static route ${path} must be a Response`);
            const b = res._body;
            if (b instanceof ReadableStream) throw new TypeError(`static route ${path} cannot stream`);
            statics.push([path, res.status, res.status === 200 ? "" : res.statusText, res._blob(), b === null ? "" : b]);
        }
    }
    const hostname = opts.hostname === undefined ? "0.0.0.0" : String(opts.hostname);
    const port = opts.port === undefined ? 8080 : opts.port | 0;
    const h = { fetch, error: opts.error, server: null };
    const index = bk.addHandler(h);
    const bound = bk.serve(index, hostname, port);
    try {
        for (const args of statics) bk.staticRoute(index, ...args);
        for (const route of routes) {
            if (route.handler) bk.httpRoute(index, route.method, route.path, route.handler, route.params);
            else bk.httpStaticRoute(index, route.method, route.path, route.status, route.text, route.headers, route.body);
        }
    } catch (error) {
        bk.stop(index, true);
        throw error;
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
