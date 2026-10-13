import { serve } from "http";
import { Database } from "sqlite";
import { readText, mkdir } from "file";
import { dirname, resolve } from "path";
import { args, main } from "process";
import {
	hashPassword,
	verifyPassword,
	randomBytes,
	sha256,
	hex,
	timingSafeEqual,
} from "crypto";
import { transpile } from "typescript";

const root = dirname(main);
const port = Number(args[0] || 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535)
	throw new Error("port must be between 1 and 65535");
const dataDir = resolve(args[1] || root + "/data");
const origin = new URL(args[2] || `http://127.0.0.1:${port}`).origin;
await mkdir(dataDir, { recursive: true });
const db = new Database(dataDir + "/taskboard.sqlite");
db.exec(await readText(root + "/schema.sql"));
const statements = new Map();
function q(sql: string) {
	let stmt = statements.get(sql);
	if (!stmt) {
		stmt = db.prepare(sql);
		statements.set(sql, stmt);
	}
	return stmt;
}
class HttpError extends Error {
	status: number;
	constructor(status: number, message: string) {
		super(message);
		this.status = status;
	}
}
function fail(status: number, message: string): never {
	throw new HttpError(status, message);
}
const enc = new TextEncoder();
const week = 7 * 86400 * 1000;
const secure = origin.startsWith("https:") ? "; Secure" : "";
function cookie(token: string, age = 604800) {
	return `taskboard_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${age}${secure}`;
}
const baseHeaders = {
	"cache-control": "no-store",
	"x-content-type-options": "nosniff",
	"referrer-policy": "same-origin",
};
function json(value: unknown, status = 200, extra = {}) {
	return new Response(JSON.stringify(value), {
		status,
		headers: {
			...baseHeaders,
			"content-type": "application/json; charset=utf-8",
			...extra,
		},
	});
}
function field(value: unknown, label: string, max = 120): string {
	if (typeof value !== "string" || !value.trim() || value.trim().length > max)
		fail(400, `${label} must contain 1–${max} characters`);
	return value.trim();
}
function email(value: unknown) {
	const v = field(value, "Email", 254).toLowerCase();
	if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v))
		fail(400, "Enter a valid email address");
	return v;
}
function password(value: unknown) {
	if (
		typeof value !== "string" ||
		Array.from(value).length < 15 ||
		enc.encode(value).length > 1024
	)
		fail(
			400,
			"Use a password of at least 15 characters, up to 1024 UTF-8 bytes",
		);
	return value;
}
async function body(req: Request) {
	if (
		!(req.headers.get("content-type") || "")
			.toLowerCase()
			.startsWith("application/json")
	)
		fail(415, "Send application/json");
	const text = await req.text();
	if (enc.encode(text).length > 16384) fail(413, "Request is too large");
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		fail(400, "Invalid JSON");
	}
	if (!value || typeof value !== "object" || Array.isArray(value))
		fail(400, "Expected a JSON object");
	return value;
}
function id(value: string) {
	if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(Number(value)))
		fail(400, "Invalid identifier");
	return Number(value);
}
function session(req: Request) {
	const cookies = req.headers.get("cookie") || "";
	const match = /(?:^|;\s*)taskboard_session=([a-f0-9]{64})(?:;|$)/.exec(
		cookies,
	);
	if (!match) fail(401, "Please sign in");
	const tokenHash = hex(sha256(match[1]));
	const s = q(
		"SELECT s.user_id,s.csrf,s.token_hash,u.name,u.email FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires>?",
	).get(tokenHash, Date.now());
	if (!s) fail(401, "Your session expired. Please sign in again");
	if (req.method !== "GET" && req.method !== "HEAD") {
		const csrf = req.headers.get("x-csrf-token") || "";
		if (
			csrf.length !== 64 ||
			!timingSafeEqual(enc.encode(csrf), enc.encode(s.csrf))
		)
			fail(403, "Invalid session token");
	}
	return s;
}
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
function startSession(userId: number) {
	const token = hex(randomBytes(32)),
		csrf = hex(randomBytes(32));
	q("DELETE FROM sessions WHERE expires<=?").run(Date.now());
	q(
		"INSERT INTO sessions(token_hash,user_id,csrf,expires) VALUES(?,?,?,?)",
	).run(hex(sha256(token)), userId, csrf, Date.now() + week);
	return { token, csrf };
}
// Bound both global password work (native) and repeated attempts per account.
const attempts = new Map<string, { count: number; expires: number }>();
let globalAttempts = { count: 0, expires: 0 };
function limitAuth(key: string) {
	const now = Date.now();
	if (globalAttempts.expires <= now)
		globalAttempts = { count: 0, expires: now + 60000 };
	if (++globalAttempts.count > 30)
		fail(429, "Too many sign-in attempts. Try again in a minute");
	if (attempts.size > 1000)
		for (const [k, v] of attempts) if (v.expires <= now) attempts.delete(k);
	if (!attempts.has(key) && attempts.size >= 1000)
		fail(429, "Too many sign-in attempts. Try again later");
	let a = attempts.get(key);
	if (!a || a.expires <= now) {
		a = { count: 0, expires: now + 600000 };
		attempts.set(key, a);
	}
	if (++a.count > 10)
		fail(429, "Too many attempts for this account. Try again in ten minutes");
}
const dummyHash = await hashPassword(hex(randomBytes(32)));
function imageType(bytes: Uint8Array) {
	const starts = (v: number[]) => v.every((b, i) => bytes[i] === b);
	if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return "image/png";
	if (starts([255, 216, 255])) return "image/jpeg";
	if (starts([71, 73, 70, 56, 55, 97]) || starts([71, 73, 70, 56, 57, 97]))
		return "image/gif";
	if (
		starts([82, 73, 70, 70]) &&
		bytes[8] === 87 &&
		bytes[9] === 69 &&
		bytes[10] === 66 &&
		bytes[11] === 80
	)
		return "image/webp";
	return "";
}
async function api(req: Request, url: URL) {
	const parts = url.pathname.split("/").filter(Boolean),
		method = req.method;
	if (method !== "GET" && method !== "HEAD") {
		const suppliedOrigin = req.headers.get("origin");
		if (suppliedOrigin && suppliedOrigin !== origin)
			fail(403, "Cross-origin requests are not allowed");
	}
	if (parts[1] === "register" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			address = email(input.email),
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
			const boardId = makeBoard(teamId, "Getting started");
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
		const s = startSession(userId);
		return json(
			{ user: { id: userId, name, email: address }, csrf: s.csrf },
			201,
			{ "set-cookie": cookie(s.token) },
		);
	}
	if (parts[1] === "login" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			address = email(input.email);
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
		const s = startSession(user.id);
		return json(
			{
				user: { id: user.id, name: user.name, email: user.email },
				csrf: s.csrf,
			},
			200,
			{ "set-cookie": cookie(s.token) },
		);
	}
	const s = session(req),
		userId = s.user_id;
	if (parts[1] === "me" && parts.length === 2 && method === "GET")
		return json({
			user: { id: userId, name: s.name, email: s.email },
			csrf: s.csrf,
		});
	if (parts[1] === "logout" && parts.length === 2 && method === "POST") {
		q("DELETE FROM sessions WHERE token_hash=?").run(s.token_hash);
		return json({ ok: true }, 200, { "set-cookie": cookie("", 0) });
	}
	if (parts[1] === "workspace" && parts.length === 2 && method === "GET")
		return json({
			teams: q(
				"SELECT t.* FROM teams t JOIN team_members m ON m.team_id=t.id WHERE m.user_id=? ORDER BY t.id",
			).all(userId),
			boards: q(
				"SELECT b.* FROM boards b JOIN team_members m ON m.team_id=b.team_id WHERE m.user_id=? ORDER BY b.id",
			).all(userId),
		});
	if (parts[1] === "teams" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			name = field(input.name, "Team name", 80);
		const teamId = db.transaction(() => {
			const teamId = Number(
				q("INSERT INTO teams(name,owner_id,created) VALUES(?,?,?)").run(
					name,
					userId,
					Date.now(),
				).lastInsertRowid,
			);
			q("INSERT INTO team_members(team_id,user_id) VALUES(?,?)").run(
				teamId,
				userId,
			);
			makeBoard(teamId, "Project board");
			return teamId;
		})();
		return json({ id: teamId }, 201);
	}
	if (parts[1] === "teams" && parts.length === 4 && parts[3] === "members") {
		const teamId = id(parts[2]);
		teamAccess(teamId, userId, method !== "GET");
		if (method === "GET")
			return json(
				q(
					"SELECT u.id,u.name,u.email FROM users u JOIN team_members m ON m.user_id=u.id WHERE m.team_id=? ORDER BY u.name",
				).all(teamId),
			);
		if (method === "POST") {
			const input = await body(req),
				address = email(input.email),
				user = q("SELECT id FROM users WHERE email=?").get(address);
			if (!user) fail(404, "Ask this person to create an account first");
			q("INSERT OR IGNORE INTO team_members(team_id,user_id) VALUES(?,?)").run(
				teamId,
				user.id,
			);
			return json({ ok: true });
		}
	}
	if (
		parts[1] === "teams" &&
		parts.length === 5 &&
		parts[3] === "members" &&
		method === "DELETE"
	) {
		const teamId = id(parts[2]),
			memberId = id(parts[4]),
			team = teamAccess(teamId, userId, true);
		if (memberId === team.owner_id)
			fail(400, "The team owner cannot be removed");
		q("DELETE FROM team_members WHERE team_id=? AND user_id=?").run(
			teamId,
			memberId,
		);
		return json({ ok: true });
	}
	if (parts[1] === "boards" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			teamId = id(String(input.team_id));
		teamAccess(teamId, userId);
		const boardId = db.transaction(() =>
			makeBoard(teamId, field(input.name, "Board name", 80)),
		)();
		return json({ id: boardId }, 201);
	}
	if (parts[1] === "boards" && parts.length === 3) {
		const boardId = id(parts[2]),
			board = boardAccess(boardId, userId);
		if (method === "GET")
			return json({
				board,
				lists: q(
					"SELECT * FROM lists WHERE board_id=? ORDER BY position,id",
				).all(boardId),
				cards: q(
					"SELECT c.* FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=? ORDER BY c.id",
				).all(boardId),
				images: q(
					"SELECT i.id,i.card_id,i.name,i.mime,i.size FROM images i JOIN cards c ON c.id=i.card_id JOIN lists l ON l.id=c.list_id WHERE l.board_id=? ORDER BY i.id",
				).all(boardId),
			});
		if (method === "DELETE") {
			q("DELETE FROM boards WHERE id=?").run(boardId);
			return json({ ok: true });
		}
	}
	if (parts[1] === "lists" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			boardId = id(String(input.board_id));
		boardAccess(boardId, userId);
		if (
			q("SELECT count(*) AS n FROM lists WHERE board_id=?").get(boardId).n >= 50
		)
			fail(400, "A board can have up to 50 lists");
		const position = q(
			"SELECT coalesce(max(position),-1)+1 AS n FROM lists WHERE board_id=?",
		).get(boardId).n;
		const result = q(
			"INSERT INTO lists(board_id,name,position) VALUES(?,?,?)",
		).run(boardId, field(input.name, "List name", 80), position);
		return json({ id: Number(result.lastInsertRowid) }, 201);
	}
	if (parts[1] === "lists" && parts.length === 3) {
		const listId = id(parts[2]);
		listAccess(listId, userId);
		if (method === "DELETE") {
			q("DELETE FROM lists WHERE id=?").run(listId);
			return json({ ok: true });
		}
		if (method === "PATCH") {
			const input = await body(req);
			q("UPDATE lists SET name=? WHERE id=?").run(
				field(input.name, "List name", 80),
				listId,
			);
			return json({ ok: true });
		}
	}
	if (parts[1] === "cards" && parts.length === 2 && method === "POST") {
		const input = await body(req),
			listId = id(String(input.list_id)),
			list = listAccess(listId, userId);
		if (
			q(
				"SELECT count(*) AS n FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=?",
			).get(list.board_id).n >= 1000
		)
			fail(400, "A board can have up to 1000 cards");
		const r = q(
			"INSERT INTO cards(list_id,title,created_by,created,updated) VALUES(?,?,?,?,?)",
		).run(
			listId,
			field(input.title, "Card title", 200),
			userId,
			Date.now(),
			Date.now(),
		);
		return json({ id: Number(r.lastInsertRowid) }, 201);
	}
	if (parts[1] === "cards" && parts.length === 3) {
		const cardId = id(parts[2]),
			card = cardAccess(cardId, userId);
		if (method === "DELETE") {
			q("DELETE FROM cards WHERE id=?").run(cardId);
			return json({ ok: true });
		}
		if (method === "PATCH") {
			const input = await body(req),
				listId =
					input.list_id === undefined
						? card.list_id
						: id(String(input.list_id));
			if (listAccess(listId, userId).board_id !== card.board_id)
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
			return json({ ok: true });
		}
	}
	if (
		parts[1] === "cards" &&
		parts.length === 4 &&
		parts[3] === "images" &&
		method === "POST"
	) {
		const cardId = id(parts[2]);
		cardAccess(cardId, userId);
		if (Number(req.headers.get("content-length") || 0) > 5 * 1024 * 1024)
			fail(413, "Images must be under 5 MiB");
		if (
			q("SELECT count(*) AS n FROM images WHERE card_id=?").get(cardId).n >= 10
		)
			fail(400, "A card can have up to 10 images");
		const bytes = new Uint8Array(await req.arrayBuffer());
		// Recheck access after the await: another request may have removed membership/card.
		cardAccess(cardId, userId);
		if (bytes.length > 5 * 1024 * 1024) fail(413, "Images must be under 5 MiB");
		const mime = imageType(bytes);
		if (!mime || mime !== (req.headers.get("content-type") || "").toLowerCase())
			fail(415, "Upload a PNG, JPEG, GIF or WebP image");
		let name;
		try {
			name = decodeURIComponent(req.headers.get("x-file-name") || "image");
		} catch {
			fail(400, "Invalid image name");
		}
		name = field(name, "Image name", 200);
		if (
			q("SELECT count(*) AS n FROM images WHERE card_id=?").get(cardId).n >= 10
		)
			fail(400, "A card can have up to 10 images");
		const r = q(
			"INSERT INTO images(card_id,name,mime,data,size,created_by,created) VALUES(?,?,?,?,?,?,?)",
		).run(cardId, name, mime, bytes, bytes.length, userId, Date.now());
		return json({ id: Number(r.lastInsertRowid) }, 201);
	}
	if (parts[1] === "images" && parts.length === 3) {
		const imageId = id(parts[2]);
		const image = q(
			"SELECT i.id,i.card_id FROM images i JOIN cards c ON c.id=i.card_id JOIN lists l ON l.id=c.list_id JOIN boards b ON b.id=l.board_id JOIN team_members m ON m.team_id=b.team_id WHERE i.id=? AND m.user_id=?",
		).get(imageId, userId);
		if (!image) fail(404, "Image not found");
		if (method === "GET" || method === "HEAD") {
			const row =
				method === "HEAD"
					? q("SELECT mime,size FROM images WHERE id=?").get(imageId)
					: q("SELECT data,mime,size FROM images WHERE id=?").get(imageId);
			return new Response(method === "HEAD" ? null : row.data, {
				headers: {
					...baseHeaders,
					"content-type": row.mime,
					"content-length": String(row.size),
					"content-security-policy": "default-src 'none'; sandbox",
				},
			});
		}
		if (method === "DELETE") {
			q("DELETE FROM images WHERE id=?").run(imageId);
			return json({ ok: true });
		}
	}
	fail(404, "Not found");
}
// Transpile once at startup; browsers receive JS, never TypeScript or TSX.
const html = await readText(root + "/index.html");
const importmap = /<script type="importmap">([\s\S]*?)<\/script>/.exec(
	html,
)![1];
const mapHash = btoa(String.fromCharCode(...sha256(importmap)));
const csp = `default-src 'self'; script-src 'self' 'sha256-${mapHash}'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`;
const staticHeaders = {
	"x-content-type-options": "nosniff",
	"content-security-policy": csp,
	"referrer-policy": "same-origin",
	"cache-control": "no-cache",
};
const assets: Record<string, Response> = {
	"/": new Response(html, {
		headers: { ...staticHeaders, "content-type": "text/html; charset=utf-8" },
	}),
	"/app.js": new Response(
		transpile(await readText(root + "/app.tsx"), {
			filename: "app.tsx",
			jsxImportSource: "preact",
		}),
		{
			headers: {
				...staticHeaders,
				"content-type": "text/javascript; charset=utf-8",
			},
		},
	),
	"/style.css": new Response(await readText(root + "/style.css"), {
		headers: { ...staticHeaders, "content-type": "text/css; charset=utf-8" },
	}),
};
for (const [route, path] of [
	["/vendor/preact.mjs", "preact/dist/preact.mjs"],
	["/vendor/hooks.mjs", "preact/hooks/dist/hooks.mjs"],
	["/vendor/jsx-runtime.mjs", "preact/jsx-runtime/dist/jsxRuntime.mjs"],
]) {
	assets[route] = new Response(await readText(root + "/vendor/" + path), {
		headers: {
			...staticHeaders,
			"content-type": "text/javascript; charset=utf-8",
		},
	});
}
serve({
	hostname: "127.0.0.1",
	port,
	static: assets,
	async fetch(req: Request) {
		try {
			const url = new URL(req.url);
			if (!url.pathname.startsWith("/api/"))
				return json({ error: "Not found" }, 404);
			return await api(req, url);
		} catch (error) {
			if (error instanceof HttpError)
				return json({ error: error.message }, error.status);
			if (
				error &&
				typeof error === "object" &&
				"code" in error &&
				error.code === "BUSY"
			)
				return json(
					{ error: "Sign-in workers are busy. Try again shortly" },
					429,
					{ "retry-after": "1" },
				);
			console.error(error);
			return json({ error: "Something went wrong" }, 500);
		}
	},
	onListen() {
		console.log(`Taskboard: ${origin}\nDatabase: ${dataDir}/taskboard.sqlite`);
	},
});
