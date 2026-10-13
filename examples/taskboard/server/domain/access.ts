import { fail } from "../../lib/errors.ts";
import type { Store } from "../../lib/sqlite.ts";

export function createAccess({ q }: Store) {
	function teamAccess(teamId: number, userId: number, owner = false) {
		const team = q(
			"SELECT t.* FROM teams t JOIN team_members m ON m.team_id=t.id WHERE t.id=? AND m.user_id=?",
		).get(teamId, userId);
		if (!team) fail(404, "Team not found");
		if (owner && team.owner_id !== userId)
			fail(403, "Only the team owner can manage members");
		return team;
	}
	function boardAccess(boardId: number, userId: number) {
		const board = q(
			"SELECT b.* FROM boards b JOIN team_members m ON m.team_id=b.team_id WHERE b.id=? AND m.user_id=?",
		).get(boardId, userId);
		if (!board) fail(404, "Board not found");
		return board;
	}
	function listAccess(listId: number, userId: number) {
		const list = q(
			"SELECT l.* FROM lists l JOIN boards b ON b.id=l.board_id JOIN team_members m ON m.team_id=b.team_id WHERE l.id=? AND m.user_id=?",
		).get(listId, userId);
		if (!list) fail(404, "List not found");
		return list;
	}
	function cardAccess(cardId: number, userId: number) {
		const card = q(
			"SELECT c.*,l.board_id FROM cards c JOIN lists l ON l.id=c.list_id JOIN boards b ON b.id=l.board_id JOIN team_members m ON m.team_id=b.team_id WHERE c.id=? AND m.user_id=?",
		).get(cardId, userId);
		if (!card) fail(404, "Card not found");
		return card;
	}
	return { teamAccess, boardAccess, listAccess, cardAccess };
}
export type Access = ReturnType<typeof createAccess>;
