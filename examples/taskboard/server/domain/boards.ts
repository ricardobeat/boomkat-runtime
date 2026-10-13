import { createBoardSnapshots } from "./board-snapshots.ts";
import { field, id } from "../../lib/validation.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Access } from "./access.ts";

export function createBoards(
	{ db, q }: Store,
	access: Access,
	snapshotCache = false,
) {
	const store = { db, q };
	let readSnapshot: ((boardId: number) => string) | undefined;
	if (snapshotCache) {
		try {
			readSnapshot = createBoardSnapshots(store);
		} catch (error) {
			// SQLite builds without JSON functions retain the ordinary row path.
			if (!String(error).includes("no such function: json")) throw error;
		}
	}

	function makeBoard(teamId: number, name: string) {
		const boardId = Number(
			q("INSERT INTO boards(team_id,name,created) VALUES(?,?,?)").run(
				teamId,
				name,
				Date.now(),
			).lastInsertRowid,
		);
		for (const [i, title] of ["To do", "In progress", "Done"].entries())
			q("INSERT INTO lists(board_id,name,position) VALUES(?,?,?)").run(
				boardId,
				title,
				i,
			);
		return boardId;
	}
	function create(userId: number, input: Record<string, unknown>) {
		const teamId = id(String(input.team_id));
		access.teamAccess(teamId, userId);
		return db.transaction(() =>
			makeBoard(teamId, field(input.name, "Board name", 80)),
		)();
	}
	function get(boardId: number, userId: number) {
		const board = access.boardAccess(boardId, userId);
		return {
			board,
			lists: q("SELECT * FROM lists WHERE board_id=? ORDER BY position,id").all(
				boardId,
			),
			cards: q(
				"SELECT c.* FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=? ORDER BY c.id",
			).all(boardId),
			images: q(
				"SELECT i.id,i.card_id,i.name,i.mime,i.size FROM images i JOIN cards c ON c.id=i.card_id JOIN lists l ON l.id=c.list_id WHERE l.board_id=? ORDER BY i.id",
			).all(boardId),
		};
	}
	function getJSON(boardId: number, userId: number): string {
		if (!readSnapshot) return JSON.stringify(get(boardId, userId));
		// A cached response never bypasses membership checks.
		access.boardAccess(boardId, userId);
		return readSnapshot(boardId);
	}

	function remove(boardId: number, userId: number) {
		access.boardAccess(boardId, userId);
		q("DELETE FROM boards WHERE id=?").run(boardId);
	}
	return {
		makeBoard,
		create,
		get,
		getJSON: readSnapshot ? getJSON : undefined,
		remove,
	};
}
export type Boards = ReturnType<typeof createBoards>;
