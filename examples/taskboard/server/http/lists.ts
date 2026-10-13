import { body, json } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteRequest } from "http";
import type { Services } from "../services.ts";
import type { Session } from "../domain/accounts.ts";

export function listHandlers(lists: Services["lists"]) {
	return {
		async create(req: RouteRequest, session: Session) {
			return json({ id: lists.create(session.user_id, await body(req)) }, 201);
		},
		async update(req: RouteRequest, session: Session) {
			lists.update(id(req.params.listId), session.user_id, await body(req));
			return json({ ok: true });
		},
		remove(req: RouteRequest, session: Session) {
			lists.remove(id(req.params.listId), session.user_id);
			return json({ ok: true });
		},
	};
}
