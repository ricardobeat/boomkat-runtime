import { baseHeaders, json } from "../../lib/http.ts";
import { id } from "../../lib/validation.ts";
import type { RouteRequest } from "http";
import type { Services } from "../services.ts";
import type { Session } from "../domain/accounts.ts";

export function imageHandlers(images: Services["images"]) {
	function response(
		req: RouteRequest,
		session: Session,
		metadataOnly: boolean,
	) {
		const row = images.get(
			id(req.params.imageId),
			session.user_id,
			metadataOnly,
		);
		return new Response(metadataOnly ? null : row.data, {
			headers: {
				...baseHeaders,
				"content-type": row.mime,
				"content-length": String(row.size),
				"content-security-policy": "default-src 'none'; sandbox",
			},
		});
	}
	return {
		async upload(req: RouteRequest, session: Session) {
			const cardId = id(req.params.cardId);
			images.prepareUpload(
				cardId,
				session.user_id,
				Number(req.headers.get("content-length") || 0),
			);
			const bytes = new Uint8Array(await req.arrayBuffer());
			return json(
				{
					id: images.add(
						cardId,
						session.user_id,
						bytes,
						req.headers.get("content-type") || "",
						req.headers.get("x-file-name") || "image",
					),
				},
				201,
			);
		},
		get(req: RouteRequest, session: Session) {
			return response(req, session, false);
		},
		head(req: RouteRequest, session: Session) {
			return response(req, session, true);
		},
		remove(req: RouteRequest, session: Session) {
			images.remove(id(req.params.imageId), session.user_id);
			return json({ ok: true });
		},
	};
}
