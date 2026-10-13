import { body, json } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteRequest } from "http";
import type { Services } from "../services.ts";
import type { Session } from "../domain/accounts.ts";

export function teamHandlers(teams: Services["teams"]) {
	return {
		workspace(_req: RouteRequest, session: Session) {
			return json(teams.workspace(session.user_id));
		},
		async create(req: RouteRequest, session: Session) {
			const input = await body(req);
			return json({ id: teams.create(session.user_id, input.name) }, 201);
		},
		members(req: RouteRequest, session: Session) {
			return json(teams.members(id(req.params.teamId), session.user_id));
		},
		async addMember(req: RouteRequest, session: Session) {
			const input = await body(req);
			teams.addMember(id(req.params.teamId), session.user_id, input.email);
			return json({ ok: true });
		},
		removeMember(req: RouteRequest, session: Session) {
			teams.removeMember(
				id(req.params.teamId),
				session.user_id,
				id(req.params.memberId),
			);
			return json({ ok: true });
		},
	};
}
