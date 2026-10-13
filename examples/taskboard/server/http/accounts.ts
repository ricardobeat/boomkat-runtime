import { body, json } from "../../lib/http.ts";
import { sessionCookie } from "./auth.ts";
import type { RouteRequest } from "http";
import type { Accounts, Session } from "../domain/accounts.ts";

export function accountHandlers(accounts: Accounts, origin: string) {
	function signedIn(
		result: { user: unknown; csrf: string; token: string },
		status: number,
	) {
		return json({ user: result.user, csrf: result.csrf }, status, {
			"set-cookie": sessionCookie(result.token, origin),
		});
	}
	return {
		async register(req: RouteRequest) {
			return signedIn(await accounts.register(await body(req)), 201);
		},
		async login(req: RouteRequest) {
			return signedIn(await accounts.login(await body(req)), 200);
		},
		me(_req: RouteRequest, session: Session) {
			return json({
				user: { id: session.user_id, name: session.name, email: session.email },
				csrf: session.csrf,
			});
		},
		logout(_req: RouteRequest, session: Session) {
			accounts.logout(session.token_hash);
			return json({ ok: true }, 200, {
				"set-cookie": sessionCookie("", origin, 0),
			});
		},
	};
}
