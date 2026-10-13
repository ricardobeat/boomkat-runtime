import { fail } from "./errors.ts";
const enc = new TextEncoder();
export function field(value: unknown, label: string, max = 120): string {
	if (typeof value !== "string" || !value.trim() || value.trim().length > max)
		fail(400, `${label} must contain 1–${max} characters`);
	return value.trim();
}
export function email(value: unknown) {
	const v = field(value, "Email", 254).toLowerCase();
	if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v))
		fail(400, "Enter a valid email address");
	return v;
}
export function password(value: unknown) {
	if (
		typeof value !== "string" ||
		Array.from(value).length < 15 ||
		enc.encode(value).length > 1024
	)
		fail(
			400,
			"Use a password of at least 15 characters, up to 1024 UTF-8 bytes",
		);
	return value;
}
export function id(value: string) {
	if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(Number(value)))
		fail(400, "Invalid identifier");
	return Number(value);
}
