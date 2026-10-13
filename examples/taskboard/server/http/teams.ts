import { body, json, fail } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteContext } from "./context.ts";

export function teamRoutes(ctx: RouteContext): Response | Promise<Response> {
	const { parts, method, services, userId } = ctx;
	if (parts.length === 2 && method === "POST") return create(ctx);
	if (parts.length === 4 && parts[3] === "members") {
		const teamId = id(parts[2]);
		if (method === "GET") return json(services.teams.members(teamId, userId));
		if (method === "POST") return addMember(ctx, teamId);
	}
	if (parts.length === 5 && parts[3] === "members" && method === "DELETE") {
		services.teams.removeMember(id(parts[2]), userId, id(parts[4]));
		return json({ ok: true });
	}
	fail(404, "Not found");
}
async function create(ctx: RouteContext) {
	const input = await body(ctx.req);
	return json({ id: ctx.services.teams.create(ctx.userId, input.name) }, 201);
}
async function addMember(ctx: RouteContext, teamId: number) {
	const input = await body(ctx.req);
	ctx.services.teams.addMember(teamId, ctx.userId, input.email);
	return json({ ok: true });
}
