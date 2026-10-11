import { read, readText, write } from "file";
import { args } from "process";

const path = args[0];
if (!path) throw new Error("usage: read-text.js temporary-file-path");
const assert = (ok, message) => { if (!ok) throw new Error(message); };
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const cases = [
    new Uint8Array(0),
    encoder.encode("hello"),
    encoder.encode("0"),
    encoder.encode("a\0b"),
    encoder.encode("café Ελληνικά"),
    encoder.encode("before 😀 after"),
    new Uint8Array([0xef, 0xbb, 0xbf, 0x61]),
    new Uint8Array([0xef, 0xbb, 0xbf]),
    new Uint8Array([0x61, 0xff, 0xc0, 0x80, 0xf0, 0x9f]),
    encoder.encode("x".repeat(65536)),
];
const retained = [];
for (const bytes of cases) {
    await write(path, bytes);
    const text = await readText(path);
    const expected = decoder.decode(await read(path));
    assert(text === expected, "decode mismatch");
    assert(text.length === expected.length, "length mismatch");
    assert(text.slice(1) === expected.slice(1), "slice mismatch");
    assert(text + "tail" === expected + "tail", "concat mismatch");
    assert(JSON.stringify(text) === JSON.stringify(expected), "JSON mismatch");
    const object = { [text]: 42 };
    assert(object[expected] === 42, "property key mismatch");
    const map = new Map([[text, 17]]);
    assert(map.get(expected) === 17, "Map key mismatch");
    retained.push([text, expected]);
}
for (let i = 0; i < 1000; i++) {
    await write(path, "retained text " + i + "x".repeat(1024));
    const text = await readText(path);
    assert(text.startsWith("retained text " + i), "reused buffer");
    if (i % 100 === 0) retained.push([text, "retained text " + i + "x".repeat(1024)]);
}
for (const [text, expected] of retained) assert(text === expected, "retained string changed");
let denied = false;
try { await readText(path + ".missing"); } catch (e) { denied = e.code === "ENOENT"; }
assert(denied, "missing-file rejection");
console.log("readText: passed");
