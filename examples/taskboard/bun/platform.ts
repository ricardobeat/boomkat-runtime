import { Database as BunDatabase } from "bun:sqlite";
import { readFile, mkdir } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import {
	createHash,
	randomBytes as nativeRandom,
	timingSafeEqual as nativeEqual,
} from "node:crypto";

export { mkdir, dirname, resolve };
export const args = process.argv.slice(2);
export const main = Bun.main;
export const readText = (path: string) => readFile(path, "utf8");
export class Database extends BunDatabase {
	constructor(path: string) {
		super(path, { create: true, strict: true });
		this.exec("PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL;");
	}
}
export function randomBytes(size: number) {
	if (!Number.isInteger(size) || size < 0 || size > 65536)
		throw new RangeError("invalid random byte count");
	return new Uint8Array(nativeRandom(size));
}
export const sha256 = (value: string | Uint8Array) =>
	new Uint8Array(createHash("sha256").update(value).digest());
export function hex(value: Uint8Array) {
	let result = "";
	for (let i = 0; i < value.length; i++)
		result += value[i].toString(16).padStart(2, "0");
	return result;
}
export const timingSafeEqual = (a: Uint8Array, b: Uint8Array) =>
	a.length === b.length && nativeEqual(a, b);

const format =
	/^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$/;
const workers: { worker: Worker; busy: boolean }[] = [];
async function passwordJob(
	password: string,
	encoded?: string,
): Promise<string | boolean> {
	if (typeof password !== "string")
		throw new TypeError("password must be a string");
	if (Buffer.byteLength(password) > 4096)
		throw new RangeError("password exceeds 4096 UTF-8 bytes");
	if (encoded !== undefined && !format.test(encoded)) return false;
	let slot = workers.find((slot) => !slot.busy);
	if (!slot && workers.length < 2) {
		slot = {
			worker: new Worker(new URL("./password-worker.ts", import.meta.url).href),
			busy: false,
		};
		workers.push(slot);
	}
	if (!slot)
		throw Object.assign(new Error("password hashing workers are busy"), {
			code: "BUSY",
		});
	slot.busy = true;
	const current = slot;
	try {
		return await new Promise((resolve, reject) => {
			current.worker.onmessage = ({ data }) =>
				data.error ? reject(new Error(data.error)) : resolve(data.result);
			current.worker.onerror = (event) => {
				current.worker.terminate();
				workers.splice(workers.indexOf(current), 1);
				reject(new Error(event.message));
			};
			current.worker.postMessage({ password, encoded });
		});
	} finally {
		current.busy = false;
	}
}
export const hashPassword = (password: string) =>
	passwordJob(password) as Promise<string>;
export const verifyPassword = (password: string, encoded: string) =>
	passwordJob(password, encoded) as Promise<boolean>;

export function transpile(
	source: string,
	options: { filename: string; jsxImportSource: string },
) {
	// The benchmark can serve BKR's emitted artifact, making /app.js byte-identical.
	// Normal Bun operation uses its own transpiler and needs no BKR binary.
	if (options.filename === "app.tsx" && process.env.TASKBOARD_BENCH_ASSET)
		return readFileSync(process.env.TASKBOARD_BENCH_ASSET, "utf8");
	return new Bun.Transpiler({
		loader: "tsx",
		target: "browser",
		autoImportJSX: true,
		tsconfig: {
			compilerOptions: {
				jsx: "react-jsx",
				jsxImportSource: options.jsxImportSource,
			},
		},
	})
		.transformSync(source, "tsx")
		.replaceAll(
			`${options.jsxImportSource}/jsx-dev-runtime`,
			`${options.jsxImportSource}/jsx-runtime`,
		);
}

export function serve(options: {
	hostname: string;
	port: number;
	static: Record<string, Response>;
	fetch: (req: Request) => Promise<Response>;
	onListen: () => void;
}) {
	const routes = Object.fromEntries(
		Object.entries(options.static).map(([path, response]) => [
			path,
			{
				GET: response,
				HEAD: new Response(null, {
					status: response.status,
					headers: response.headers,
				}),
			},
		]),
	);
	const server = Bun.serve({
		hostname: options.hostname,
		port: options.port,
		routes,
		fetch: options.fetch,
		development: false,
		idleTimeout: 10,
		maxRequestBodySize: 16 * 1024 * 1024,
	});
	options.onListen();
	return server;
}
