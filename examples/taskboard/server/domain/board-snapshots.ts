import { fail } from "../../lib/errors.ts";
import type { Store } from "../../lib/sqlite.ts";

const snapshotSQL = `SELECT json_object(
    'board', json_object('id',b.id,'team_id',b.team_id,'name',b.name,'created',b.created),
    'lists', (SELECT json_group_array(json_object('id',id,'board_id',board_id,'name',name,'position',position))
        FROM (SELECT * FROM lists WHERE board_id=b.id ORDER BY position,id)),
    'cards', (SELECT json_group_array(json_object('id',id,'list_id',list_id,'title',title,
        'description',description,'color',color,'created_by',created_by,'created',created,'updated',updated))
        FROM (SELECT c.* FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=b.id ORDER BY c.id)),
    'images', (SELECT json_group_array(json_object('id',id,'card_id',card_id,'name',name,'mime',mime,'size',size))
        FROM (SELECT i.id,i.card_id,i.name,i.mime,i.size FROM images i JOIN cards c ON c.id=i.card_id
            JOIN lists l ON l.id=c.list_id WHERE l.board_id=b.id ORDER BY i.id))
) AS snapshot FROM boards b WHERE b.id=?`;

// Callers authorize each read. Cache only the board's shared representation.
export function createBoardSnapshots({ db, q }: Store) {
	const snapshot = q(snapshotSQL);
	const version = q(`SELECT total_changes() AS local,
        (SELECT data_version FROM pragma_data_version) AS external`);
	const snapshots = new Map<number, string>();
	const maxBytes = 4 * 1024 * 1024;
	const maxEntries = 64;
	let stamp = "";
	let retainedBytes = 0;

	function clear() {
		snapshots.clear();
		retainedBytes = 0;
		stamp = "";
	}
	function load(boardId: number): string {
		const row = snapshot.get(boardId);
		if (!row) fail(404, "Board not found");
		return row.snapshot as string;
	}
	return (boardId: number): string => {
		// Rollback does not rewind total_changes(). Never retain uncommitted
		// data, or reuse a cache across a transaction-local read.
		if (db.inTransaction) {
			clear();
			return load(boardId);
		}
		const counters = version.get();
		const currentStamp = `${counters.local}:${counters.external}`;
		if (currentStamp !== stamp) {
			clear();
			stamp = currentStamp;
		}
		const cached = snapshots.get(boardId);
		if (cached !== undefined) return cached;
		const text = load(boardId);
		// CESU-8 needs at most three bytes per UTF-16 code unit. The entry
		// cap also bounds Map overhead when snapshots are very small.
		const bytes = text.length * 3;
		if (bytes <= maxBytes) {
			if (retainedBytes + bytes > maxBytes || snapshots.size >= maxEntries) {
				clear();
				stamp = currentStamp;
			}
			snapshots.set(boardId, text);
			retainedBytes += bytes;
		}
		return text;
	};
}
