// Editor declarations for Boomkat's native modules. No Node types/dependencies.
declare module "http" {
	export interface RouteRequest extends Request {
		params: Record<string, string>;
	}
	export interface Server {
		port: number;
		url: URL;
		finished: Promise<void>;
		readonly workers: number;
		ready: Promise<Server>;
		stop(force?: boolean): Promise<void>;
	}
	export type RouteHandler = (
		request: RouteRequest,
		server: Server,
	) => Response | Promise<Response>;
	export type MethodHandlers = Partial<
		Record<
			| "GET"
			| "HEAD"
			| "POST"
			| "PUT"
			| "PATCH"
			| "DELETE"
			| "OPTIONS"
			| "TRACE"
			| "CONNECT",
			RouteHandler | Response
		>
	>;
	export type Routes = Record<
		string,
		RouteHandler | Response | MethodHandlers | false
	>;
	export function serve(options: {
		hostname?: string;
		port?: number;
		static?: Record<string, Response>;
		routes?: Routes;
		fetch?: (request: Request) => Response | Promise<Response>;
		error?: (error: unknown) => Response | Promise<Response>;
		onListen?: (server: Server) => void;
	}): Server;
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
		readonly inTransaction: boolean;
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
