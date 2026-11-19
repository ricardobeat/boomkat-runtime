// File upload server: stores uploaded files in uploads/.
// Run with --allow-net=127.0.0.1:8080 --allow-read=examples/upload --allow-write=examples/upload/uploads
import { serve } from "http";
import { body, exists, list, mkdir, readText, remove, stat, write } from "file";
import { basename } from "path";

const UPLOADS = "examples/upload/uploads";
const MAX_BYTES = 200 * 1024 * 1024;

const page = await readText("examples/upload/index.html");
await mkdir(UPLOADS, { recursive: true });

const json = (data, status = 200) => Response.json(data, { status });

function cleanName(raw) {
    const name = basename(String(raw || "")).trim();
    if (!name || name.startsWith(".") || name.length > 200) return null;
    if (/[\\/\x00-\x1f\x7f]/.test(name)) return null;
    return name;
}

async function listFiles() {
    const files = [];
    for (const entry of await list(UPLOADS)) {
        if (entry.kind !== "file") continue;
        const info = await stat(`${UPLOADS}/${entry.name}`);
        files.push({ name: entry.name, size: info.size, mtime: info.mtime.getTime() });
    }
    files.sort((a, b) => b.mtime - a.mtime);
    return files;
}

async function upload(req, url) {
    const name = cleanName(url.searchParams.get("name"));
    if (!name) return json({ error: "invalid file name" }, 400);

    const declared = Number(req.headers.get("content-length"));
    if (!Number.isFinite(declared)) return json({ error: "content-length required" }, 411);
    if (declared > MAX_BYTES) return json({ error: "file too large" }, 413);

    const target = `${UPLOADS}/${name}`;
    if (await exists(target)) return json({ error: "a file with that name already exists" }, 409);

    await write(target, new Uint8Array(0));
    let received = 0;
    try {
        const reader = req.body ? req.body.getReader() : null;
        while (reader) {
            const { value, done } = await reader.read();
            if (done) break;
            received += value.byteLength;
            if (received > declared) throw new RangeError("body longer than content-length");
            await write(target, value, { append: true });
        }
        if (received !== declared) throw new RangeError("body shorter than content-length");
    } catch (err) {
        await remove(target).catch(() => {});
        return json({ error: err.message }, 400);
    }
    return json({ name, size: received }, 201);
}

async function download(url) {
    const name = cleanName(decodeURIComponent(url.pathname.slice("/files/".length)));
    // file.body() is lazy and fails while sending, so check existence here.
    if (!name || !(await exists(`${UPLOADS}/${name}`))) return json({ error: "not found" }, 404);
    return new Response(body(`${UPLOADS}/${name}`), {
        headers: { "content-disposition": `attachment; filename="${name.replace(/"/g, "")}"` },
    });
}

serve({
    port: 8080,
    hostname: "127.0.0.1",
    async fetch(req) {
        const url = new URL(req.url);
        try {
            if (req.method === "GET" && url.pathname === "/") {
                return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
            }
            if (req.method === "GET" && url.pathname === "/api/files") {
                return json(await listFiles());
            }
            if (req.method === "POST" && url.pathname === "/api/upload") {
                return await upload(req, url);
            }
            if (req.method === "GET" && url.pathname.startsWith("/files/")) {
                return await download(url);
            }
            return json({ error: "not found" }, 404);
        } catch (err) {
            return json({ error: String(err && err.message || err) }, 500);
        }
    },
});

console.log("upload server on http://127.0.0.1:8080");
