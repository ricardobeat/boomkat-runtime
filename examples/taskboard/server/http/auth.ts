import { fail } from "../../lib/http.ts";
import type { Accounts } from "../domain/accounts.ts";
import type { Crypto } from "../platform.ts";

const enc = new TextEncoder();
export function authenticateRequest(
	req: Request,
	accounts: Accounts,
	crypto: Crypto,
) {
	const match = /(?:^|;\s*)taskboard_session=([a-f0-9]{64})(?:;|$)/.exec(
		req.headers.get("cookie") || "",
	);
	if (!match) fail(401, "Please sign in");
	const session = accounts.authenticate(match[1]);
	if (req.method !== "GET" && req.method !== "HEAD") {
		const csrf = req.headers.get("x-csrf-token") || "";
		if (
			csrf.length !== 64 ||
			!crypto.timingSafeEqual(enc.encode(csrf), enc.encode(session.csrf))
		)
			fail(403, "Invalid session token");
	}
	return session;
}
export function sessionCookie(token: string, origin: string, age = 604800) {
	const secure = origin.startsWith("https:") ? "; Secure" : "";
	return `taskboard_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${age}${secure}`;
}
