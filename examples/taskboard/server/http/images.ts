import { baseHeaders, json, fail } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteContext } from "./context.ts";

export async function uploadImage(ctx: RouteContext, cardId: number) {
	const { req, userId, services } = ctx;
	services.images.prepareUpload(
		cardId,
		userId,
		Number(req.headers.get("content-length") || 0),
	);
	const bytes = new Uint8Array(await req.arrayBuffer());
	const imageId = services.images.add(
		cardId,
		userId,
		bytes,
		req.headers.get("content-type") || "",
		req.headers.get("x-file-name") || "image",
	);
	return json({ id: imageId }, 201);
}
export function imageRoutes(ctx: RouteContext) {
	const { parts, method, services, userId } = ctx;
	if (parts.length === 3) {
		const imageId = id(parts[2]);
		if (method === "GET" || method === "HEAD") {
			const row = services.images.get(imageId, userId, method === "HEAD");
			return new Response(method === "HEAD" ? null : row.data, {
				headers: {
					...baseHeaders,
					"content-type": row.mime,
					"content-length": String(row.size),
					"content-security-policy": "default-src 'none'; sandbox",
				},
			});
		}
		if (method === "DELETE") {
			services.images.remove(imageId, userId);
			return json({ ok: true });
		}
	}
	fail(404, "Not found");
}
