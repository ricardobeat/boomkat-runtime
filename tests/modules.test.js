// Equivalent import paths must share module state and class identity.
// Drives the runtime on a fixture tree in a temporary directory.
import { test, assertEquals, assert } from "test";
import { execPath, run } from "process";
import { mkdir, remove, writeText } from "file";
import { dirname } from "path";

const root = `${dirname(import.meta.url)}/.modules-fixture-${Date.now()}`;

test("equivalent paths share module state and class identity", async () => {
    await mkdir(`${root}/nested`, { recursive: true });
    try {
        await writeText(`${root}/shared.ts`, "export class AppError extends Error {}; export const state = { count: 0 };");
        await writeText(`${root}/nested/a.ts`, 'import { AppError, state } from "../shared.ts"; export function visit() { state.count++; return new AppError("shared"); }');
        await writeText(`${root}/nested/b.ts`, 'export { AppError, state } from ".././shared.ts";');
        await writeText(`${root}/main.ts`, `
import { AppError, state } from "./shared.ts";
import { visit } from "./nested/a.ts";
import { AppError as Other, state as otherState } from "./nested/../nested/b.ts";
const error = visit();
if (Other !== AppError || !(error instanceof Other) || state !== otherState || state.count !== 1)
    throw new Error("module identity differs across relative paths");
const dynamic = await import("./nested/../shared.ts");
if (dynamic.AppError !== AppError || dynamic.state !== state) throw new Error("dynamic import duplicated module");
const absolute = await import(${JSON.stringify(`${root}/nested/../shared.ts`)});
if (absolute.state !== state || absolute.AppError !== AppError) throw new Error("absolute alias duplicated module");
console.log("Relative module paths share state and class identity: passed");
`);
        const { code, stdout, stderr } = await run(execPath, {
            args: ["--no-sandbox", "--no-prompt", `--allow-read=${root}`, `${root}/main.ts`],
        });
        const out = new TextDecoder().decode(stdout), err = new TextDecoder().decode(stderr);
        assertEquals(code, 0, out + err);
        assert(out.includes("Relative module paths share state and class identity: passed"), out);
    } finally {
        await remove(root, { recursive: true });
    }
});
