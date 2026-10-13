import { HttpError, fail } from "./errors.ts";
export { HttpError, fail } from "./errors.ts";

export const baseHeaders = {
	"cache-control": "no-store",
	"x-content-type-options": "nosniff",
	"referrer-policy": "same-origin",
};
export function jsonText(text: string, status = 200, extra = {}) {
	return new Response(text, {
		status,
		headers: {
			...baseHeaders,
			"content-type": "application/json; charset=utf-8",
			...extra,
		},
	});
}
export function json(value: unknown, status = 200, extra = {}) {
	return jsonText(JSON.stringify(value), status, extra);
}

const enc = new TextEncoder();
export async function body(req: Request) {
	if (
		!(req.headers.get("content-type") || "")
			.toLowerCase()
			.startsWith("application/json")
	)
		fail(415, "Send application/json");
	const text = await req.text();
	if (enc.encode(text).length > 16384) fail(413, "Request is too large");
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		fail(400, "Invalid JSON");
	}
	if (!value || typeof value !== "object" || Array.isArray(value))
		fail(400, "Expected a JSON object");
	return value;
}

export function checkOrigin(req: Request, origin: string) {
	if (req.method !== "GET" && req.method !== "HEAD") {
		const supplied = req.headers.get("origin");
		if (supplied && supplied !== origin)
			fail(403, "Cross-origin requests are not allowed");
	}
}
export function errorResponse(error: unknown) {
	if (error instanceof HttpError)
		return json({ error: error.message }, error.status);
	if (
		error &&
		typeof error === "object" &&
		"code" in error &&
		error.code === "BUSY"
	)
		return json({ error: "Sign-in workers are busy. Try again shortly" }, 429, {
			"retry-after": "1",
		});
	console.error(error);
	return json({ error: "Something went wrong" }, 500);
}
