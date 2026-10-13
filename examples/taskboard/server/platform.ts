import type { Database } from "sqlite";

export interface Crypto {
	hashPassword(password: string): Promise<string>;
	verifyPassword(password: string, encoded: string): Promise<boolean>;
	randomBytes(size: number): Uint8Array;
	sha256(value: string | Uint8Array): Uint8Array;
	hex(value: Uint8Array): string;
	timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean;
}
export interface Platform extends Crypto {
	Database: new (path: string) => Database;
	args: string[];
	main: string;
	dirname(path: string): string;
	resolve(...paths: string[]): string;
	mkdir(path: string, options: { recursive: boolean }): Promise<unknown>;
	readText(path: string): Promise<string>;
	transpile(
		source: string,
		options: { filename: string; jsxImportSource: string },
	): string;
	serve(options: {
		hostname: string;
		port: number;
		static: Record<string, Response>;
		fetch(request: Request): Response | Promise<Response>;
		onListen(): void;
	}): unknown;
}
