import { fail } from "../../lib/errors.ts";
import { field, email, password } from "../../lib/validation.ts";
import { createAuthLimiter } from "../../lib/rate-limit.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Crypto } from "../platform.ts";
import type { Boards } from "./boards.ts";

export interface Session {
	user_id: number;
	csrf: string;
	token_hash: string;
	name: string;
	email: string;
}
export async function createAccounts(
	{ db, q }: Store,
	crypto: Crypto,
	boards: Boards,
) {
	const { hashPassword, verifyPassword, randomBytes, sha256, hex } = crypto;
	const enc = new TextEncoder();
	const week = 7 * 86400 * 1000;
	const limitAuth = createAuthLimiter();
	const dummyHash = await hashPassword(hex(randomBytes(32)));
	function startSession(userId: number) {
		const token = hex(randomBytes(32)),
			csrf = hex(randomBytes(32));
		q("DELETE FROM sessions WHERE expires<=?").run(Date.now());
		q(
			"INSERT INTO sessions(token_hash,user_id,csrf,expires) VALUES(?,?,?,?)",
		).run(hex(sha256(token)), userId, csrf, Date.now() + week);
		return { token, csrf };
	}
	async function register(input: Record<string, unknown>) {
		const address = email(input.email),
			name = field(input.name, "Name", 80),
			pass = password(input.password);
		limitAuth(address);
		const hash = await hashPassword(pass);
		if (q("SELECT id FROM users WHERE email=?").get(address))
			fail(409, "This email is already registered");
		const userId = db.transaction(() => {
			const userId = Number(
				q(
					"INSERT INTO users(name,email,password_hash,created) VALUES(?,?,?,?)",
				).run(name, address, hash, Date.now()).lastInsertRowid,
			);
			const teamId = Number(
				q("INSERT INTO teams(name,owner_id,created) VALUES(?,?,?)").run(
					name + "’s workspace",
					userId,
					Date.now(),
				).lastInsertRowid,
			);
			q("INSERT INTO team_members(team_id,user_id) VALUES(?,?)").run(
				teamId,
				userId,
			);
			const boardId = boards.makeBoard(teamId, "Getting started");
			const list = q(
				"SELECT id FROM lists WHERE board_id=? ORDER BY position LIMIT 1",
			).get(boardId);
			q(
				"INSERT INTO cards(list_id,title,description,color,created_by,created,updated) VALUES(?,?,?,?,?,?,?)",
			).run(
				list.id,
				"Welcome to Taskboard",
				"Add cards, move them between lists, and attach images. Create a team to share your next project.",
				"mint",
				userId,
				Date.now(),
				Date.now(),
			);
			return userId;
		})();
		const session = startSession(userId);
		return { user: { id: userId, name, email: address }, ...session };
	}
	async function login(input: Record<string, unknown>) {
		const address = email(input.email);
		if (
			typeof input.password !== "string" ||
			enc.encode(input.password).length > 1024
		)
			fail(400, "Invalid password");
		limitAuth(address);
		const user = q("SELECT * FROM users WHERE email=?").get(address);
		const ok = await verifyPassword(
			input.password,
			user ? user.password_hash : dummyHash,
		);
		if (!ok || !user) fail(401, "Email or password is incorrect");
		const session = startSession(user.id);
		return {
			user: { id: user.id, name: user.name, email: user.email },
			...session,
		};
	}
	function authenticate(token: string): Session {
		const row = q(
			"SELECT s.user_id,s.csrf,s.token_hash,u.name,u.email FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires>?",
		).get(hex(sha256(token)), Date.now());
		if (!row) fail(401, "Your session expired. Please sign in again");
		return row;
	}
	function logout(tokenHash: string) {
		q("DELETE FROM sessions WHERE token_hash=?").run(tokenHash);
	}
	return { register, login, authenticate, logout };
}
export type Accounts = Awaited<ReturnType<typeof createAccounts>>;
