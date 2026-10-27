// CompressionStream and DecompressionStream in every format, their errors,
// and fetch decoding gzip and deflate bodies from a server that compresses
// with CompressionStream.
// Run: bkr --no-sandbox -A compression.js
import { serve } from "http";
import { exit } from "process";

const enc = new TextEncoder();
const text = "boomkat compression ".repeat(4000);
const failures = [];
function check(name, actual, expected) {
    const a = JSON.stringify(actual), b = JSON.stringify(expected);
    if (a !== b) failures.push(`${name}\n    expected ${b}\n    actual   ${a}`);
}

const streamOf = (chunks) => new ReadableStream({ start(c) { for (const x of chunks) c.enqueue(x); c.close(); } });
const collect = async (stream) => new Uint8Array(await new Response(stream).arrayBuffer());

for (const format of ["gzip", "deflate", "deflate-raw"]) {
    const bytes = enc.encode(text);
    const packed = await collect(streamOf([bytes.subarray(0, 1000), bytes.subarray(1000)]).pipeThrough(new CompressionStream(format)));
    // Feed the decompressor one byte at a time to cross every header boundary.
    const pieces = Array.from(packed.subarray(0, 64), (b) => new Uint8Array([b])).concat([packed.subarray(64)]);
    const back = new TextDecoder().decode(await collect(streamOf(pieces).pipeThrough(new DecompressionStream(format))));
    check(`${format} round trip`, [packed.length < bytes.length / 10, back === text], [true, true]);
}

const gzip = await collect(streamOf([enc.encode(text)]).pipeThrough(new CompressionStream("gzip")));
check("gzip header", [gzip[0], gzip[1]], [0x1f, 0x8b]);

async function failure(stream) {
    try { await collect(stream); return "no error"; } catch (e) { return `${e.name}: ${e.message}`; }
}
check("truncated gzip", await failure(streamOf([gzip.subarray(0, 40)]).pipeThrough(new DecompressionStream("gzip"))),
    "TypeError: the compressed stream ended early");
check("corrupt gzip", await failure(streamOf([enc.encode("not gzip at all")]).pipeThrough(new DecompressionStream("gzip"))),
    "TypeError: invalid compressed data");
check("trailing data", await failure(streamOf([gzip, enc.encode("x")]).pipeThrough(new DecompressionStream("gzip"))),
    "TypeError: data after the end of the compressed stream");
let threw = "";
try { new CompressionStream("br"); } catch (e) { threw = e.name; }
check("unsupported format", threw, "TypeError");

const server = serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(req) {
        const coding = new URL(req.url).pathname.slice(1);
        const headers = { "x-accept-encoding": req.headers.get("accept-encoding") ?? "" };
        if (coding === "plain") return new Response(text, { headers });
        headers["content-encoding"] = coding;
        return new Response(streamOf([enc.encode(text)]).pipeThrough(new CompressionStream(coding)), { headers });
    },
});
const base = `http://127.0.0.1:${server.port}`;
for (const coding of ["gzip", "deflate", "plain"]) {
    const r = await fetch(`${base}/${coding}`);
    check(`fetch ${coding}`, [r.headers.get("x-accept-encoding"), (await r.text()) === text], ["gzip, deflate", true]);
}
const kept = await fetch(`${base}/plain`, { headers: { "accept-encoding": "identity" } });
check("explicit accept-encoding", kept.headers.get("x-accept-encoding"), "identity");
await kept.body.cancel();

await server.stop(true);
if (failures.length) {
    console.error("compression failed:\n  " + failures.join("\n  "));
    exit(1);
}
console.log("compression: all checks passed");
