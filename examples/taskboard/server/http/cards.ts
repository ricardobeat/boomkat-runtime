import { body, json } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteRequest } from "http";
import type { Services } from "../services.ts";
import type { Session } from "../domain/accounts.ts";

export function cardHandlers(cards: Services["cards"]) {
	return {
		async create(req: RouteRequest, session: Session) {
			return json({ id: cards.create(session.user_id, await body(req)) }, 201);
		},
		async update(req: RouteRequest, session: Session) {
			cards.update(id(req.params.cardId), session.user_id, await body(req));
			return json({ ok: true });
		},
		remove(req: RouteRequest, session: Session) {
			cards.remove(id(req.params.cardId), session.user_id);
			return json({ ok: true });
		},
	};
}
