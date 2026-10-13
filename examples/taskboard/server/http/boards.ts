import { body, json, jsonText } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteRequest } from "http";
import type { Boards } from "../domain/boards.ts";
import type { Session } from "../domain/accounts.ts";

export function boardHandlers(boards: Boards) {
	return {
		async create(req: RouteRequest, session: Session) {
			return json({ id: boards.create(session.user_id, await body(req)) }, 201);
		},
		get(req: RouteRequest, session: Session) {
			const boardId = id(req.params.boardId);
			return boards.getJSON
				? jsonText(boards.getJSON(boardId, session.user_id))
				: json(boards.get(boardId, session.user_id));
		},
		remove(req: RouteRequest, session: Session) {
			boards.remove(id(req.params.boardId), session.user_id);
			return json({ ok: true });
		},
	};
}
