import { body, json, fail } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteContext } from "./context.ts";

export function listRoutes(ctx: RouteContext): Response | Promise<Response> {
	const { parts, method, services, userId } = ctx;
	if (parts.length === 2 && method === "POST") return create(ctx);
	if (parts.length === 3) {
		const listId = id(parts[2]);
		if (method === "DELETE") {
			services.lists.remove(listId, userId);
			return json({ ok: true });
		}
		if (method === "PATCH") return update(ctx, listId);
	}
	fail(404, "Not found");
}
async function create(ctx: RouteContext) {
	return json(
		{ id: ctx.services.lists.create(ctx.userId, await body(ctx.req)) },
		201,
	);
}
async function update(ctx: RouteContext, listId: number) {
	ctx.services.lists.update(listId, ctx.userId, await body(ctx.req));
	return json({ ok: true });
}
