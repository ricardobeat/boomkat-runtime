import { body, json, fail } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import { uploadImage } from "./images.ts";
import type { RouteContext } from "./context.ts";

export function cardRoutes(ctx: RouteContext): Response | Promise<Response> {
	const { parts, method, services, userId } = ctx;
	if (parts.length === 2 && method === "POST") return create(ctx);
	if (parts.length === 4 && parts[3] === "images" && method === "POST")
		return uploadImage(ctx, id(parts[2]));
	if (parts.length === 3) {
		const cardId = id(parts[2]);
		if (method === "DELETE") {
			services.cards.remove(cardId, userId);
			return json({ ok: true });
		}
		if (method === "PATCH") return update(ctx, cardId);
	}
	fail(404, "Not found");
}
async function create(ctx: RouteContext) {
	return json(
		{ id: ctx.services.cards.create(ctx.userId, await body(ctx.req)) },
		201,
	);
}
async function update(ctx: RouteContext, cardId: number) {
	ctx.services.cards.update(cardId, ctx.userId, await body(ctx.req));
	return json({ ok: true });
}
