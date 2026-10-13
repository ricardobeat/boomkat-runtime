import { createStore } from "../lib/sqlite.ts";
import { createAccess } from "./domain/access.ts";
import { createBoards } from "./domain/boards.ts";
import { createTeams } from "./domain/teams.ts";
import { createLists } from "./domain/lists.ts";
import { createCards } from "./domain/cards.ts";
import { createImages } from "./domain/images.ts";
import { createAccounts } from "./domain/accounts.ts";
import type { Database } from "sqlite";
import type { Crypto } from "./platform.ts";

export async function createServices(db: Database, crypto: Crypto) {
	const store = createStore(db);
	const access = createAccess(store);
	const boards = createBoards(store, access);
	return {
		accounts: await createAccounts(store, crypto, boards),
		boards,
		teams: createTeams(store, access, boards),
		lists: createLists(store, access),
		cards: createCards(store, access),
		images: createImages(store, access),
	};
}
export type Services = Awaited<ReturnType<typeof createServices>>;
