// Independent worker VMs and their native-resource ownership. Each check runs
// a script in its own bkr, as the Python wrapper did.
import { test, assertEquals, assert } from "test";
import { execPath, run } from "process";
import { mkdir, remove, readText, writeText } from "file";
import { dirname } from "path";

const here = dirname(import.meta.url);
const dec = new TextDecoder();

async function bkr(script, flags = ["-A"], args = []) {
    const { code, stdout, stderr } = await run(execPath, {
        args: ["--no-sandbox", "--no-prompt", ...flags, script, ...args],
    });
    const out = dec.decode(stdout), err = dec.decode(stderr);
    assertEquals(code, 0, out + err);
    assert(!err.includes("ERROR: AddressSanitizer"), err);
    return out.trim();
}

test("workers: main, stress, permissions and dependency denial", async () => {
    const dir = `${here}/.workers-fixture-${Date.now()}`;
    await mkdir(dir, { recursive: true });
    try {
        const fixture = `${dir}/data.txt`;
        await writeText(fixture, "worker fixture");
        assertEquals(await bkr(`${here}/workers/main.js`, ["-A"], [fixture]), "Workers: cloning, TS/TLA, isolation, async resources, nested workers, lifecycle and interruption passed");
        assertEquals(await bkr(`${here}/workers/stress.js`, ["-A"], [fixture]), "Workers: concurrent GC, native jobs, transfers and termination stress passed");

        const worker = `${here}/workers/permissions.ts`;
        const inherited = `${dir}/permissions.js`;
        await writeText(inherited,
            "const w = new Worker(" + JSON.stringify(worker) + ");" +
            "w.onerror = e => { throw new Error(e.message); };" +
            "w.onmessage = e => {" +
            "if (e.data.read !== 'PERMISSION_DENIED' || e.data.write !== 'PERMISSION_DENIED')" +
            "throw new Error(JSON.stringify(e.data));" +
            "console.log('Worker permissions inherited'); };" +
            "w.postMessage({path:" + JSON.stringify(fixture) + "});");
        assertEquals(await bkr(inherited, [`--allow-read=${worker}`]), "Worker permissions inherited");
        assertEquals(await readText(fixture), "worker fixture");

        const denied = `${dir}/denied.js`;
        await writeText(denied,
            "let denied = false; try { new Worker(" + JSON.stringify(worker) + "); }" +
            "catch (e) { denied = e.code === 'PERMISSION_DENIED'; }" +
            "if (!denied) throw new Error('worker escaped read permission');" +
            "console.log('Worker entry read denied');");
        assertEquals(await bkr(denied, []), "Worker entry read denied");

        const importer = `${here}/workers/import-permissions.ts`;
        const importDenied = `${dir}/import-denied.js`;
        await writeText(importDenied,
            "const w = new Worker(" + JSON.stringify(importer) + "); let denied = false;" +
            "w.onerror = e => { e.preventDefault(); denied = true; };" +
            "w.onmessage = () => { throw new Error('worker import escaped read permission'); };" +
            "w.addEventListener('close', () => {" +
            "if (!denied) throw new Error('missing worker import error');" +
            "console.log('Worker dependency read denied'); });");
        assertEquals(await bkr(importDenied, [`--allow-read=${importer}`]), "Worker dependency read denied");
    } finally {
        await remove(dir, { recursive: true });
    }
});
