import { body, json, fail } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteContext } from "./context.ts";

export function boardRoutes(ctx: RouteContext): Response | Promise<Response> {
	const { parts, method, services, userId } = ctx;
	if (parts.length === 2 && method === "POST") return create(ctx);
	if (parts.length === 3) {
		const boardId = id(parts[2]);
		if (method === "GET") return json(services.boards.get(boardId, userId));
		if (method === "DELETE") {
			services.boards.remove(boardId, userId);
			return json({ ok: true });
		}
	}
	fail(404, "Not found");
}
async function create(ctx: RouteContext) {
	return json(
		{ id: ctx.services.boards.create(ctx.userId, await body(ctx.req)) },
		201,
	);
}
