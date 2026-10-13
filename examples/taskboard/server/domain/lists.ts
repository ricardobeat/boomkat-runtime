import { fail } from "../../lib/errors.ts";
import { field, id } from "../../lib/validation.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Access } from "./access.ts";

export function createLists({ q }: Store, access: Access) {
	function create(userId: number, input: Record<string, unknown>) {
		const boardId = id(String(input.board_id));
		access.boardAccess(boardId, userId);
		if (
			q("SELECT count(*) AS n FROM lists WHERE board_id=?").get(boardId).n >= 50
		)
			fail(400, "A board can have up to 50 lists");
		const position = q(
			"SELECT coalesce(max(position),-1)+1 AS n FROM lists WHERE board_id=?",
		).get(boardId).n;
		return Number(
			q("INSERT INTO lists(board_id,name,position) VALUES(?,?,?)").run(
				boardId,
				field(input.name, "List name", 80),
				position,
			).lastInsertRowid,
		);
	}
	function update(
		listId: number,
		userId: number,
		input: Record<string, unknown>,
	) {
		access.listAccess(listId, userId);
		q("UPDATE lists SET name=? WHERE id=?").run(
			field(input.name, "List name", 80),
			listId,
		);
	}
	function remove(listId: number, userId: number) {
		access.listAccess(listId, userId);
		q("DELETE FROM lists WHERE id=?").run(listId);
	}
	return { create, update, remove };
}
