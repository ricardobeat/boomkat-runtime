import type { Database, Statement } from "sqlite";

// One cache per database: callers own the connection and its lifetime.
export function createStore(db: Database) {
	const statements = new Map<string, Statement>();
	function q(sql: string) {
		let stmt = statements.get(sql);
		if (!stmt) {
			stmt = db.prepare(sql);
			statements.set(sql, stmt);
		}
		return stmt;
	}
	return { db, q };
}
export type Store = ReturnType<typeof createStore>;
