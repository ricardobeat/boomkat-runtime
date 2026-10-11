export const sep = "/";
export const delimiter = ":";

export function normalize(p) {
    if (p === "") return ".";
    const abs = p.startsWith("/");
    const out = [];
    for (const s of p.split("/")) {
        if (s === "" || s === ".") continue;
        if (s === "..") {
            if (out.length && out[out.length - 1] !== "..") out.pop();
            else if (!abs) out.push("..");
        } else out.push(s);
    }
    const r = (abs ? "/" : "") + out.join("/");
    return r === "" ? "." : p.endsWith("/") && r !== "/" ? r + "/" : r;
}

export function join(...parts) {
    const p = parts.filter((x) => x !== "").join("/");
    return p === "" ? "." : normalize(p);
}

export function isAbsolute(p) { return p.startsWith("/"); }

export function resolve(...parts) {
    let r = "";
    for (let i = parts.length - 1; i >= 0 && !r.startsWith("/"); i--) if (parts[i]) r = parts[i] + (r ? "/" + r : "");
    if (!r.startsWith("/")) r = __bk.cwd() + (r ? "/" + r : "");
    const n = normalize(r);
    return n.length > 1 && n.endsWith("/") ? n.slice(0, -1) : n;
}

export function relative(from, to) {
    const a = resolve(from).split("/").filter(Boolean);
    const b = resolve(to).split("/").filter(Boolean);
    let i = 0;
    while (i < a.length && i < b.length && a[i] === b[i]) i++;
    return [...a.slice(i).map(() => ".."), ...b.slice(i)].join("/");
}

export function dirname(p) {
    if (p === "") return ".";
    const t = p.length > 1 ? p.replace(/\/+$/, "") : p;
    const i = t.lastIndexOf("/");
    if (i < 0) return ".";
    return i === 0 ? "/" : t.slice(0, i);
}

export function basename(p, ext) {
    const t = p.length > 1 ? p.replace(/\/+$/, "") : p;
    let b = t.slice(t.lastIndexOf("/") + 1);
    if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length);
    return b;
}

export function extname(p) {
    const b = basename(p);
    const i = b.lastIndexOf(".");
    return i <= 0 ? "" : b.slice(i);
}

export function parse(p) {
    const base = basename(p), ext = extname(p);
    return { root: p.startsWith("/") ? "/" : "", dir: dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base };
}

export function format(o) {
    const dir = o.dir || o.root || "";
    const base = o.base || (o.name || "") + (o.ext || "");
    return dir ? (dir.endsWith("/") ? dir + base : dir + "/" + base) : base;
}

export function toFileUrl(p) { return new URL("file://" + encodeURI(resolve(p))); }
export function fromFileUrl(u) {
    u = u instanceof URL ? u : new URL(u);
    if (u.protocol !== "file:") throw new TypeError("not a file URL");
    return decodeURIComponent(u.pathname);
}
