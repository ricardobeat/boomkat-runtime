// `bkr test` against the fixtures in tests/.test-runner-fixtures, which fail
// on purpose and so live in a hidden directory discovery skips.
// Run: bkr --no-sandbox -A test-runner.js
import { execPath, exit, run } from "process";
import { dirname } from "path";

const fixtures = dirname(import.meta.url) + "/.test-runner-fixtures";
const failures = [];

async function bkrTest(...args) {
    const { code, stdout, stderr } = await run(execPath, { args: ["test", ...args] });
    const dec = new TextDecoder();
    return { code, out: dec.decode(stdout) + dec.decode(stderr) };
}

function expect(name, result, code, lines, absent = []) {
    if (result.code !== code) failures.push(`${name}: exit code ${result.code}, wanted ${code}\n${result.out}`);
    for (const line of lines) if (!result.out.includes(line)) failures.push(`${name}: missing ${JSON.stringify(line)}\n${result.out}`);
    for (const line of absent) if (result.out.includes(line)) failures.push(`${name}: unexpected ${JSON.stringify(line)}`);
}

expect("passing file", await bkrTest(`${fixtures}/pass.test.ts`), 0, [
    "✓ deep equality",
    "✓ hooks ran",
    "✓ async > awaits",
    "✓ async > rejects",
    "- async > skipped",
    "- async > todo (todo)",
    "✓ match",
    "5 passed, 2 skipped",
]);

expect("failing file", await bkrTest(`${fixtures}/fail.test.js`), 1, [
    "✗ wrong sum",
    "AssertionError: values are not equal",
    "expected 3",
    "✗ floating rejection",
    "Error: floating",
    "✓ passes after failures",
    "1 passed, 2 failed",
], ["(test:"]);

expect("load error", await bkrTest(`${fixtures}/broken.test.js`), 1, ["✗ could not load", "SyntaxError"]);

expect("only", await bkrTest(`${fixtures}/only`), 0, ["✓ selected", "✓ selected group > inside", "2 passed"], ["not selected"]);

expect("filter", await bkrTest("--filter=deep", `${fixtures}/pass.test.ts`), 0, ["✓ deep equality", "1 passed"], ["hooks ran"]);

const all = await bkrTest(fixtures);
expect("directory discovery", all, 1, ["pass.test.ts", "fail.test.js", "broken.test.js", "only/only.test.js"]);

expect("missing path", await bkrTest(`${fixtures}/nope`), 2, ["does not exist"]);

if (failures.length) {
    console.error("test-runner failed:\n  " + failures.join("\n  "));
    exit(1);
}
console.log("test-runner: all checks passed");
