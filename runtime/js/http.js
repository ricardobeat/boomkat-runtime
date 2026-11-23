import { body as fileBody, exists, readText, stat } from "file";
import { transpile, transpileWithMap } from "typescript";

const bk = __bk;
const methods = new Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT"]);
const notFound = () => new Response("Not Found", { status: 404 });

const MIME = {
    html: "text/html; charset=utf-8", htm: "text/html; charset=utf-8",
    js: "text/javascript; charset=utf-8", mjs: "text/javascript; charset=utf-8",
    css: "text/css; charset=utf-8", json: "application/json; charset=utf-8",
    map: "application/json; charset=utf-8", xml: "application/xml",
    svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg",
    gif: "image/gif", webp: "image/webp", avif: "image/avif", ico: "image/x-icon",
    wasm: "application/wasm", woff: "font/woff", woff2: "font/woff2",
    ttf: "font/ttf", otf: "font/otf", txt: "text/plain; charset=utf-8",
    ts: "text/plain; charset=utf-8", tsx: "text/plain; charset=utf-8",
    jsx: "text/plain; charset=utf-8", mts: "text/plain; charset=utf-8",
    cts: "text/plain; charset=utf-8",
    pdf: "application/pdf", mp4: "video/mp4", webm: "video/webm",
    mp3: "audio/mpeg", wav: "audio/wav",
};

const TRANSPILED = /\.(?:ts|tsx|jsx|mts|cts)$/i;
const JS_EXT = /^(.*)\.(?:mjs|js)$/i;

function mimeType(path) {
    const dot = path.lastIndexOf(".");
    return dot > path.lastIndexOf("/")
        ? MIME[path.slice(dot + 1).toLowerCase()] || "application/octet-stream"
        : "application/octet-stream";
}

// The request path relative to the route prefix, decoded and checked so that a
// percent-encoded ".." or a NUL byte cannot leave the served directory.
function relativePath(pathname, prefix) {
    const base = prefix + "/";
    if (!pathname.startsWith(base)) return null;
    let rel;
    try { rel = decodeURIComponent(pathname.slice(base.length)); } catch { return null; }
    if (rel.startsWith("/") || rel.includes("\\") || rel.includes("\0")) return null;
    for (const segment of rel.split("/")) if (segment === "." || segment === "..") return null;
    return rel === "" || rel.endsWith("/") ? rel + "index.html" : rel;
}

// A request for /app/main.js also tries main.tsx, main.ts, main.jsx, main.mts
// and main.cts, so the URL a browser asks for does not have to exist on disk.
function sourceCandidates(rel) {
    if (TRANSPILED.test(rel)) return [rel];
    const match = JS_EXT.exec(rel);
    if (!match) return [rel];
    return [rel, match[1] + ".tsx", match[1] + ".ts", match[1] + ".jsx", match[1] + ".mts", match[1] + ".cts"];
}

async function findFile(dir, rel) {
    for (const candidate of sourceCandidates(rel)) {
        const path = dir.endsWith("/") ? dir + candidate : dir + "/" + candidate;
        if (!(await exists(path))) continue;
        const info = await stat(path);
        if (info.kind === "file") return { path, rel: candidate, info };
    }
    return null;
}

function etagOf(info) {
    return `W/"${info.size}-${info.mtime.getTime()}"`;
}

function isNotModified(req, etag) {
    const match = req.headers.get("if-none-match");
    return match !== null && match.split(",").some((tag) => tag.trim() === etag);
}

const notModified = (etag) => new Response(null, { status: 304, headers: { etag } });

// Transpiled sources are kept per path and re-used until the file's mtime or
// size changes, so a request costs one stat instead of a read and a parse.
function sourceLoader(mode) {
    const cache = new Map();
    return async function load(found) {
        const stamp = `${found.info.size}-${found.info.mtime.getTime()}`;
        const cached = cache.get(found.path);
        if (cached !== undefined && cached.stamp === stamp) return cached;
        const source = await readText(found.path);
        let code, map = null;
        if (mode === false) {
            code = transpile(source, { filename: found.rel });
        } else if (mode === "inline") {
            code = transpile(source, { filename: found.rel, sourceMap: "inline" });
        } else {
            const out = transpileWithMap(source, { filename: found.rel });
            code = out.code;
            map = out.map;
        }
        const entry = { stamp, code, map, etag: `W/"${stamp}"` };
        cache.set(found.path, entry);
        return entry;
    };
}

function directoryHandler(dir, prefix, transpileOn, sourceMaps) {
    const mode = transpileOn ? sourceMaps : false;
    const load = sourceLoader(mode);
    return async function directory(req) {
        let pathname;
        try { pathname = new URL(req.url).pathname; } catch { return new Response("Bad Request", { status: 400 }); }
        const rel = relativePath(pathname, prefix);
        if (rel === null) return new Response("Bad Request", { status: 400 });
        try {
            if (transpileOn && mode !== false && rel.endsWith(".map")) {
                const found = await findFile(dir, rel.slice(0, -4));
                if (found !== null && TRANSPILED.test(found.rel)) {
                    const entry = await load(found);
                    if (entry.map !== null) {
                        if (isNotModified(req, entry.etag)) return notModified(entry.etag);
                        return new Response(entry.map, {
                            headers: { "content-type": "application/json; charset=utf-8", etag: entry.etag },
                        });
                    }
                }
            }
            const found = await findFile(dir, rel);
            if (found === null) return notFound();
            if (transpileOn && TRANSPILED.test(found.rel)) {
                const entry = await load(found);
                if (isNotModified(req, entry.etag)) return notModified(entry.etag);
                const body = entry.map === null
                    ? entry.code
                    : entry.code + "\n//# sourceMappingURL=" + pathname + ".map";
                return new Response(body, {
                    headers: { "content-type": "text/javascript; charset=utf-8", etag: entry.etag },
                });
            }
            if (isNotModified(req, etagOf(found.info))) return notModified(etagOf(found.info));
            return new Response(fileBody(found.path), {
                headers: { "content-type": mimeType(found.rel), etag: etagOf(found.info) },
            });
        } catch (error) {
            if (error && error.code === "PERMISSION_DENIED") return new Response("Forbidden", { status: 403 });
            const message = error && error.message !== undefined ? error.message : String(error);
            return new Response("Internal Server Error: " + message, { status: 500 });
        }
    };
}

// A route value { dir, transpile, sourceMaps } serves a directory. The path
// must end in /*; GET and HEAD are registered, and the bare prefix redirects
// to the trailing-slash form.
function compileDirectory(compiled, path, value) {
    if (!path.endsWith("/*")) throw new TypeError(`directory route ${path} must end in /*`);
    const prefix = path.slice(0, -2);
    if (prefix.includes(":") || prefix.includes("*"))
        throw new TypeError(`directory route ${path} cannot have parameters or wildcards in its prefix`);
    for (const key of Object.keys(value))
        if (key !== "dir" && key !== "transpile" && key !== "sourceMaps")
            throw new TypeError(`unsupported directory route option ${key}`);
    if (typeof value.dir !== "string" || value.dir === "")
        throw new TypeError(`directory route ${path} needs a dir`);
    if (value.transpile !== undefined && typeof value.transpile !== "boolean")
        throw new TypeError(`directory route ${path}: transpile must be a boolean`);
    if (value.sourceMaps !== undefined && !value.transpile)
        throw new TypeError(`directory route ${path}: sourceMaps needs transpile`);
    const sourceMaps = value.sourceMaps === undefined ? "linked" : value.sourceMaps;
    if (sourceMaps !== "linked" && sourceMaps !== "inline" && sourceMaps !== false)
        throw new TypeError(`directory route ${path}: sourceMaps must be "linked", "inline" or false`);
    const handler = directoryHandler(value.dir, prefix, value.transpile === true, sourceMaps);
    for (const method of ["GET", "HEAD"]) compiled.push({ path, method, handler, params: [] });
    if (prefix !== "") {
        const redirect = () => new Response(null, { status: 308, headers: { location: prefix + "/" } });
        for (const method of ["GET", "HEAD"]) compiled.push({ path: prefix, method, handler: redirect, params: [] });
    }
}

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
        } else if (value && typeof value === "object" && !Array.isArray(value) && value.dir !== undefined) {
            compileDirectory(compiled, path, value);
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

// Accepts a WebSocket upgrade request: returns the server end of the socket
// and the Response the handler returns to complete the upgrade.
export function upgradeWebSocket(req, options) {
    return bk.wsServer(req, options);
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
    const tls = opts.tls === undefined || opts.tls === null ? null : opts.tls;
    if (tls && (typeof tls.cert !== "string" || typeof tls.key !== "string")) {
        throw new TypeError("tls needs cert and key file paths");
    }
    const h = { fetch, error: opts.error, server: null };
    const index = bk.addHandler(h);
    const bound = bk.serve(index, hostname, port, tls ? tls.cert : "", tls ? tls.key : "");
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
        url: new URL(`${tls ? "https" : "http"}://${hostname === "0.0.0.0" ? "localhost" : hostname}:${bound}/`),
        finished,
        async [Symbol.asyncDispose]() { await server.stop(); },
        get workers() { return bk.httpPoolCount(index); },
        stop(force = false) {
            bk.stop(index, force);
            if (!bk.httpPoolPending(index)) { closed(); return finished; }
            const check = () => {
                if (bk.httpPoolPending(index)) setTimeout(check, 1);
                else closed();
            };
            check();
            return finished;
        },
    };
    h.server = server;
    bk.fetchFor(index, fetch, server);
    try { bk.httpPoolStart(index); }
    catch (error) { server.stop(true); throw error; }
    server.ready = new Promise(resolve => {
        const check = () => {
            if (server.workers >= bk.httpPoolTarget() || bk.httpPoolCount(index) === 0) resolve(server);
            else setTimeout(check, 1);
        };
        check();
    });
    if (bk.httpPoolTarget() > 1) server.ready.then(() => console.log(`HTTP workers ready: ${server.workers}`));
    if (opts.onListen) opts.onListen(server);
    return server;
}
