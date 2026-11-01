// Source maps from typescript.transpileWithMap: decode the mappings and check
// that generated identifiers land on the same word in the original, including
// after non-ASCII text (columns are UTF-16 units) and in CRLF sources.
import { test, assertEquals, assert } from "test";
import { transpile, transpileWithMap } from "typescript";

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LINES = new RegExp("\\r\\n|\\n|\\r|\\u2028|\\u2029");

function segments(mappings) {
    const out = [];
    let line = 0, srcLine = 0, srcCol = 0;
    for (const text of mappings.split(";")) {
        let col = 0;
        if (text) {
            for (const seg of text.split(",")) {
                const v = [];
                let shift = 0, val = 0;
                for (const ch of seg) {
                    const d = B64.indexOf(ch);
                    val += (d & 31) << shift;
                    if (d & 32) { shift += 5; continue; }
                    v.push(val & 1 ? -(val >> 1) : val >> 1);
                    shift = 0;
                    val = 0;
                }
                col += v[0];
                srcLine += v[2];
                srcCol += v[3];
                out.push({ line, col, srcLine, srcCol });
            }
        }
        line++;
    }
    return out;
}

const word = /^[\p{ID_Start}$_][\p{ID_Continue}$]*/u;

// Every segment that starts a word in the output, minus the ones the printer
// invents (JSX calls, the injected import), must start the same word in the source.
function wordsAgree(source, filename, allowed = 0) {
    const { code, map } = transpileWithMap(source, { filename });
    const parsed = JSON.parse(map);
    const gen = code.split(LINES), src = source.split(LINES);
    let words = 0, differing = [];
    for (const s of segments(parsed.mappings)) {
        const g = gen[s.line].slice(s.col).match(word)?.[0];
        if (!g) continue;
        words++;
        if (g !== (src[s.srcLine] ?? "").slice(s.srcCol).match(word)?.[0]) differing.push(`${s.line}:${s.col} ${g}`);
    }
    assert(words > 5, "map has word segments");
    assert(differing.length <= allowed, `segments off their source word: ${differing.join(", ")}`);
    return parsed;
}

const TS = `// café ☕
interface P { x: number }
export function dist(a: P, b: P): number {
  const dx = a.x - b.x;
  return Math.sqrt(dx * dx);
}
const naïve = "ünï😀cödé"; const after = naïve.length + dist({ x: 1 }, { x: 4 });
export class C<T> { private items: T[] = []; add(i: T) { this.items.push(i); return this; } }
async function load(url: string) { const r = await fetch(url); return r.json(); }
`;

test("maps identifiers back to their source position", () => {
    const map = wordsAgree(TS, "a.ts");
    assertEquals(map.version, 3);
    assertEquals(map.sources[0], "a.ts");
    assertEquals(map.sourcesContent[0], TS);
});

test("source columns are UTF-16 units after non-ASCII text", () => {
    const { code, map } = transpileWithMap("const s = \"é😀\"; const z = s + s;\n", { filename: "u.ts" });
    const out = code.split(LINES)[0];
    // `s + s` follows the emoji (2 UTF-16 units) in the source.
    const want = "const s = \"é😀\"; const z = ".length;
    const hit = segments(JSON.parse(map).mappings).filter((s) => s.srcCol === want);
    assert(hit.length > 0, "a segment points at the expression after the emoji");
    assert(out.includes("\\ud83d\\ude00"), "the output escapes the emoji");
});

test("CRLF, Unicode line separators and template literals", () => {
    wordsAgree("const a: number = 1;\r\nfunction f(x: string) {\r\n  const t = `l1\r\nl2 ${x}`;\r\n  return t + a;\r\n}\r\nconsole.log(f(\"h\"));\r\n", "c.ts");
    wordsAgree("const s = \"a b\"; const z: number = 2; export const q = z + 1;\n", "l.ts");
});

test("JSX maps the element call to its tag", () => {
    // The `_jsx` call and the injected import are the only invented words.
    wordsAgree("const v = <div class=\"a\">{1 + 1}</div>;\nconst w = v;\n", "j.tsx", 2);
});

test("transpile can append the map inline", () => {
    const plain = transpile("let x: number = 1;", { filename: "p.ts" });
    assert(!plain.includes("sourceMappingURL"));
    const inline = transpile("let x: number = 1;", { filename: "p.ts", sourceMap: "inline" });
    const marker = "\n//# sourceMappingURL=data:application/json;base64,";
    assert(inline.startsWith(plain) && inline.slice(plain.length).startsWith(marker));
    const { code, map } = transpileWithMap("let x: number = 1;", { filename: "p.ts" });
    assertEquals(code, plain);
    assertEquals(JSON.parse(atob(inline.slice(plain.length + marker.length))).mappings, JSON.parse(map).mappings);
});

test("sourceMap is validated, and an empty source still maps", () => {
    let error;
    try { transpile("1", { sourceMap: "external" }); } catch (e) { error = e; }
    assert(error instanceof TypeError);
    const { code, map } = transpileWithMap("", { filename: "e.ts" });
    assertEquals(code, "");
    assertEquals(JSON.parse(map).version, 3);
});
