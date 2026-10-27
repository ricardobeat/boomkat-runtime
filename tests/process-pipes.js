// process.run drains a child's pipes and closes each at end of file. The
// close runs inside the read's settlement, which once freed the pipe while
// the native read completion still held it. A `bkr test` child that fails to
// load its file exits at the right moment to reproduce it reliably.
// Run: bkr --no-sandbox -A process-pipes.js
import { execPath, exit, run } from "process";
import { dirname } from "path";

const broken = dirname(import.meta.url) + "/.test-runner-fixtures/broken.test.js";
let bad = 0;
for (let i = 0; i < 30; i++) {
    const r = await run(execPath, { args: ["test", broken] });
    if (r.code !== 1 || !new TextDecoder().decode(r.stdout).includes("could not load")) bad++;
}
if (bad) {
    console.error(`process-pipes failed: ${bad} of 30 runs returned the wrong result`);
    exit(1);
}
console.log("process-pipes: 30 runs passed");
