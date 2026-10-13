import { fail } from "../../lib/errors.ts";
import { field, email } from "../../lib/validation.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Access } from "./access.ts";
import type { Boards } from "./boards.ts";

export function createTeams({ db, q }: Store, access: Access, boards: Boards) {
	function workspace(userId: number) {
		return {
			teams: q(
				"SELECT t.* FROM teams t JOIN team_members m ON m.team_id=t.id WHERE m.user_id=? ORDER BY t.id",
			).all(userId),
			boards: q(
				"SELECT b.* FROM boards b JOIN team_members m ON m.team_id=b.team_id WHERE m.user_id=? ORDER BY b.id",
			).all(userId),
		};
	}
	function create(userId: number, name: unknown) {
		const title = field(name, "Team name", 80);
		return db.transaction(() => {
			const teamId = Number(
				q("INSERT INTO teams(name,owner_id,created) VALUES(?,?,?)").run(
					title,
					userId,
					Date.now(),
				).lastInsertRowid,
			);
			q("INSERT INTO team_members(team_id,user_id) VALUES(?,?)").run(
				teamId,
				userId,
			);
			boards.makeBoard(teamId, "Project board");
			return teamId;
		})();
	}
	function members(teamId: number, userId: number) {
		access.teamAccess(teamId, userId);
		return q(
			"SELECT u.id,u.name,u.email FROM users u JOIN team_members m ON m.user_id=u.id WHERE m.team_id=? ORDER BY u.name",
		).all(teamId);
	}
	function addMember(teamId: number, userId: number, address: unknown) {
		access.teamAccess(teamId, userId, true);
		const user = q("SELECT id FROM users WHERE email=?").get(email(address));
		if (!user) fail(404, "Ask this person to create an account first");
		q("INSERT OR IGNORE INTO team_members(team_id,user_id) VALUES(?,?)").run(
			teamId,
			user.id,
		);
	}
	function removeMember(teamId: number, userId: number, memberId: number) {
		const team = access.teamAccess(teamId, userId, true);
		if (memberId === team.owner_id)
			fail(400, "The team owner cannot be removed");
		q("DELETE FROM team_members WHERE team_id=? AND user_id=?").run(
			teamId,
			memberId,
		);
	}
	return { workspace, create, members, addMember, removeMember };
}
