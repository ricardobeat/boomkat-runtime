const bk = __bk;
const enc = new TextEncoder();

const toPath = (p) => (p instanceof URL ? decodeURIComponent(p.pathname) : String(p));
const toBytes = (d) => (typeof d === "string" ? enc.encode(d) : d);

function info(text) {
    const [kind, size, mtime, mode] = text.split(" ");
    return { kind, size: Number(size), mtime: new Date(Number(mtime)), mode: Number(mode) };
}

export const read = (path) => bk.op(bk.readFile, toPath(path));
export const readText = (path) => bk.op(bk.readText, toPath(path));
export const write = (path, data, { append = false } = {}) => bk.op(bk.writeFile, toPath(path), toBytes(data), append);
export const writeText = write;
export const stat = async (path) => info(await bk.op(bk.stat, toPath(path)));
export const exists = (path) => stat(path).then(() => true, (e) => (e.code === "ENOENT" ? false : Promise.reject(e)));
export const mkdir = (path, { recursive = false } = {}) => bk.op(bk.mkdir, toPath(path), recursive);
export const remove = (path, { recursive = false } = {}) => bk.op(bk.remove, toPath(path), recursive);
export const rename = (from, to) => bk.op(bk.rename, toPath(from), toPath(to));
export const copy = async (from, to) => write(to, await read(from));
export const open = async (path, mode = "r") => new bk.Handle(await bk.op(bk.open, toPath(path), mode));

export async function list(path) {
    const text = await bk.op(bk.list, toPath(path));
    return text.split("\n").filter(Boolean).map((line) => {
        const i = line.indexOf(" ");
        return { kind: line.slice(0, i), name: line.slice(i + 1) };
    });
}
