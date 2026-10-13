import { fail } from "../../lib/errors.ts";
import { field, id } from "../../lib/validation.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Access } from "./access.ts";

export function createCards({ q }: Store, access: Access) {
	function create(userId: number, input: Record<string, unknown>) {
		const listId = id(String(input.list_id)),
			list = access.listAccess(listId, userId);
		if (
			q(
				"SELECT count(*) AS n FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=?",
			).get(list.board_id).n >= 1000
		)
			fail(400, "A board can have up to 1000 cards");
		return Number(
			q(
				"INSERT INTO cards(list_id,title,created_by,created,updated) VALUES(?,?,?,?,?)",
			).run(
				listId,
				field(input.title, "Card title", 200),
				userId,
				Date.now(),
				Date.now(),
			).lastInsertRowid,
		);
	}
	function update(
		cardId: number,
		userId: number,
		input: Record<string, unknown>,
	) {
		const card = access.cardAccess(cardId, userId);
		const listId =
			input.list_id === undefined ? card.list_id : id(String(input.list_id));
		if (access.listAccess(listId, userId).board_id !== card.board_id)
			fail(400, "Cards must stay on the same board");
		const title =
			input.title === undefined
				? card.title
				: field(input.title, "Card title", 200);
		const description =
			input.description === undefined ? card.description : input.description;
		if (typeof description !== "string" || description.length > 8000)
			fail(400, "Description can contain up to 8000 characters");
		const color = input.color === undefined ? card.color : input.color;
		if (!["none", "mint", "peach", "lavender", "sky"].includes(color))
			fail(400, "Invalid card color");
		q(
			"UPDATE cards SET title=?,description=?,color=?,list_id=?,updated=? WHERE id=?",
		).run(title, description, color, listId, Date.now(), cardId);
	}
	function remove(cardId: number, userId: number) {
		access.cardAccess(cardId, userId);
		q("DELETE FROM cards WHERE id=?").run(cardId);
	}
	return { create, update, remove };
}
