// Uncaught exceptions print their stack, with positions in the original
// TypeScript source, and values that are not Errors print as themselves.
// Run: bkr --no-sandbox -A uncaught.js
import { execPath, exit, run } from "process";
import { remove, writeText } from "file";

const cases = [
    {
        name: "top-level TypeScript throw",
        file: "ts",
        source: `interface Shape { size: number }
function area(s: Shape): number {
    throw new Error("boom");
}
area({ size: 1 } as Shape);`,
        expect: [/^error: Error: boom$/m, /\n    at area \(.*\.ts:3:11\)/, /\n    at <anonymous> \(.*\.ts:5:1\)/],
    },
    {
        name: "throw in a timer callback",
        file: "js",
        source: `setTimeout(() => { null.x; }, 1);`,
        expect: [/^error: TypeError: Cannot read properties of null/m, /\.js:1:25\)/],
    },
    {
        name: "a thrown string",
        file: "js",
        source: `throw "plain";`,
        expect: [/^error: plain\n?$/],
    },
    // The main module's eval has returned by the time these throw.
    {
        name: "throw after a top-level await",
        file: "js",
        source: `await null;\nthrow new Error("after await");`,
        expect: [/^error: Uncaught \(in promise\) Error: after await$/m, /\.js:2:7\)/],
    },
    {
        name: "throw after awaiting a timer",
        file: "js",
        source: `await new Promise((r) => setTimeout(r, 1));\nthrow new RangeError("after timer");`,
        expect: [/^error: Uncaught \(in promise\) RangeError: after timer$/m],
    },
];

const failures = [];
for (const c of cases) {
    const path = `/tmp/bkr-uncaught-${Date.now()}.${c.file}`;
    await writeText(path, c.source);
    const { code, stderr } = await run(execPath, { args: ["--no-sandbox", path] });
    await remove(path);
    const text = new TextDecoder().decode(stderr);
    if (code !== 1) failures.push(`${c.name}: exit code ${code}`);
    for (const re of c.expect) if (!re.test(text)) failures.push(`${c.name}: missing ${re}\n${text}`);
}

if (failures.length) {
    console.error("uncaught failed:\n  " + failures.join("\n  "));
    exit(1);
}
console.log(`uncaught: ${cases.length} cases passed`);
