import { body, json, fail } from "../../lib/http.ts";
import { sessionCookie } from "./auth.ts";
import type { Accounts } from "../domain/accounts.ts";
import type { RouteContext } from "./context.ts";

export async function signIn(
	req: Request,
	action: string,
	accounts: Accounts,
	origin: string,
) {
	const input = await body(req);
	const result =
		action === "register"
			? await accounts.register(input)
			: await accounts.login(input);
	return json(
		{ user: result.user, csrf: result.csrf },
		action === "register" ? 201 : 200,
		{ "set-cookie": sessionCookie(result.token, origin) },
	);
}
export function accountRoutes(ctx: RouteContext, origin: string) {
	const { parts, method, session, services, userId } = ctx;
	if (parts.length === 2 && parts[1] === "me" && method === "GET")
		return json({
			user: { id: userId, name: session.name, email: session.email },
			csrf: session.csrf,
		});
	if (parts.length === 2 && parts[1] === "logout" && method === "POST") {
		services.accounts.logout(session.token_hash);
		return json({ ok: true }, 200, {
			"set-cookie": sessionCookie("", origin, 0),
		});
	}
	fail(404, "Not found");
}
