// Editor declarations for Boomkat's native modules. No Node types/dependencies.
declare module "http" {
	export function serve(options: {
		hostname?: string;
		port?: number;
		static?: Record<string, Response>;
		fetch(request: Request): Response | Promise<Response>;
		onListen?: (server: { port: number; url: URL }) => void;
	}): { port: number; url: URL; stop(force?: boolean): Promise<void> };
}
declare module "sqlite" {
	export class Statement {
		get(...values: unknown[]): any;
		all(...values: unknown[]): any[];
		run(...values: unknown[]): {
			changes: number;
			lastInsertRowid: number | bigint;
		};
		finalize(): void;
	}
	export class Database {
		constructor(path?: string, options?: { readonly?: boolean });
		exec(sql: string): void;
		prepare(sql: string): Statement;
		query(sql: string): Statement;
		transaction<T extends (...args: any[]) => any>(fn: T): T;
		close(): void;
	}
}
declare module "file" {
	export function readText(path: string): Promise<string>;
	export function mkdir(
		path: string,
		options?: { recursive?: boolean },
	): Promise<void>;
}
declare module "path" {
	export function dirname(path: string): string;
	export function resolve(...paths: string[]): string;
}
declare module "process" {
	export const args: string[];
	export const main: string;
}
declare module "crypto" {
	export function randomBytes(size: number): Uint8Array<ArrayBuffer>;
	export function sha256(
		input: string | ArrayBuffer | ArrayBufferView,
	): Uint8Array<ArrayBuffer>;
	export function hex(input: Uint8Array): string;
	export function timingSafeEqual(
		a: ArrayBuffer | ArrayBufferView,
		b: ArrayBuffer | ArrayBufferView,
	): boolean;
	export function hashPassword(password: string): Promise<string>;
	export function verifyPassword(
		password: string,
		encoded: string,
	): Promise<boolean>;
}
declare module "typescript" {
	export function transpile(
		source: string,
		options?: {
			filename?: string;
			module?: boolean;
			jsx?: "automatic" | "classic";
			jsxImportSource?: string;
			jsxFactory?: string;
			jsxFragmentFactory?: string;
		},
	): string;
}
