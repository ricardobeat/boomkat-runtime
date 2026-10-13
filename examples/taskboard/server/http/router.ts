import { checkOrigin, fail } from "../../lib/http.ts";
import { authenticateRequest } from "./auth.ts";
import { accountHandlers } from "./accounts.ts";
import { teamHandlers } from "./teams.ts";
import { boardHandlers } from "./boards.ts";
import { listHandlers } from "./lists.ts";
import { cardHandlers } from "./cards.ts";
import { imageHandlers } from "./images.ts";
import type { RouteHandler, RouteRequest, Routes } from "http";
import type { Services } from "../services.ts";
import type { Crypto } from "../platform.ts";
import type { Session } from "../domain/accounts.ts";

type AuthenticatedHandler = (
	req: RouteRequest,
	session: Session,
) => Response | Promise<Response>;
export function createRoutes(
	services: Services,
	crypto: Crypto,
	origin: string,
): Routes {
	// Wrappers run synchronously unless the controller itself returns a promise.
	function authenticated(handler: AuthenticatedHandler): RouteHandler {
		return (req) => {
			checkOrigin(req, origin);
			return handler(req, authenticateRequest(req, services.accounts, crypto));
		};
	}
	function publicWrite(handler: RouteHandler): RouteHandler {
		return (req, server) => {
			checkOrigin(req, origin);
			return handler(req, server);
		};
	}
	const accounts = accountHandlers(services.accounts, origin);
	const teams = teamHandlers(services.teams);
	const boards = boardHandlers(services.boards);
	const lists = listHandlers(services.lists);
	const cards = cardHandlers(services.cards);
	const images = imageHandlers(services.images);
	return {
		"/api/register": { POST: publicWrite(accounts.register) },
		"/api/login": { POST: publicWrite(accounts.login) },
		"/api/me": { GET: authenticated(accounts.me) },
		"/api/logout": { POST: authenticated(accounts.logout) },
		"/api/workspace": { GET: authenticated(teams.workspace) },
		"/api/teams": { POST: authenticated(teams.create) },
		"/api/teams/:teamId/members": {
			GET: authenticated(teams.members),
			POST: authenticated(teams.addMember),
		},
		"/api/teams/:teamId/members/:memberId": {
			DELETE: authenticated(teams.removeMember),
		},
		"/api/boards": { POST: authenticated(boards.create) },
		"/api/boards/:boardId": {
			GET: authenticated(boards.get),
			DELETE: authenticated(boards.remove),
		},
		"/api/lists": { POST: authenticated(lists.create) },
		"/api/lists/:listId": {
			PATCH: authenticated(lists.update),
			DELETE: authenticated(lists.remove),
		},
		"/api/cards": { POST: authenticated(cards.create) },
		"/api/cards/:cardId": {
			PATCH: authenticated(cards.update),
			DELETE: authenticated(cards.remove),
		},
		"/api/cards/:cardId/images": { POST: authenticated(images.upload) },
		"/api/images/:imageId": {
			GET: authenticated(images.get),
			HEAD: authenticated(images.head),
			DELETE: authenticated(images.remove),
		},
		"/api/*": authenticated(() => fail(404, "Not found")),
	};
}
