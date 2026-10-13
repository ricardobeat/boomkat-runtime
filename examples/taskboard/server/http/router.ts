import { checkOrigin, errorResponse, fail, json } from "../../lib/http.ts";
import { authenticateRequest } from "./auth.ts";
import { accountRoutes, signIn } from "./accounts.ts";
import { teamRoutes } from "./teams.ts";
import { boardRoutes } from "./boards.ts";
import { listRoutes } from "./lists.ts";
import { cardRoutes } from "./cards.ts";
import { imageRoutes } from "./images.ts";
import type { Services } from "../services.ts";
import type { Crypto } from "../platform.ts";

export function createHttpHandler(
	services: Services,
	crypto: Crypto,
	origin: string,
) {
	function route(req: Request): Response | Promise<Response> {
		const url = new URL(req.url);
		if (!url.pathname.startsWith("/api/")) fail(404, "Not found");
		const parts = url.pathname.split("/").filter(Boolean),
			method = req.method;
		checkOrigin(req, origin);
		if (
			parts.length === 2 &&
			method === "POST" &&
			(parts[1] === "register" || parts[1] === "login")
		)
			return signIn(req, parts[1], services.accounts, origin);
		const session = authenticateRequest(req, services.accounts, crypto);
		const ctx = {
			req,
			parts,
			method,
			services,
			session,
			userId: session.user_id,
		};
		switch (parts[1]) {
			case "me":
			case "logout":
				return accountRoutes(ctx, origin);
			case "workspace":
				if (parts.length === 2 && method === "GET")
					return json(services.teams.workspace(ctx.userId));
				break;
			case "teams":
				return teamRoutes(ctx);
			case "boards":
				return boardRoutes(ctx);
			case "lists":
				return listRoutes(ctx);
			case "cards":
				return cardRoutes(ctx);
			case "images":
				return imageRoutes(ctx);
		}
		fail(404, "Not found");
	}
	return async function fetch(req: Request) {
		try {
			return await route(req);
		} catch (error) {
			return errorResponse(error);
		}
	};
}
