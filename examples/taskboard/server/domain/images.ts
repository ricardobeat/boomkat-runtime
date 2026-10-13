import { fail } from "../../lib/errors.ts";
import { field } from "../../lib/validation.ts";
import { imageType } from "../../lib/images.ts";
import type { Store } from "../../lib/sqlite.ts";
import type { Access } from "./access.ts";

export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export function createImages({ q }: Store, access: Access) {
	function checkCount(cardId: number) {
		if (
			q("SELECT count(*) AS n FROM images WHERE card_id=?").get(cardId).n >= 10
		)
			fail(400, "A card can have up to 10 images");
	}
	function prepareUpload(cardId: number, userId: number, length: number) {
		access.cardAccess(cardId, userId);
		if (length > MAX_IMAGE_BYTES) fail(413, "Images must be under 5 MiB");
		checkCount(cardId);
	}
	function add(
		cardId: number,
		userId: number,
		bytes: Uint8Array,
		contentType: string,
		encodedName: string,
	) {
		// The upload awaited its body: membership/card may have changed meanwhile.
		access.cardAccess(cardId, userId);
		if (bytes.length > MAX_IMAGE_BYTES) fail(413, "Images must be under 5 MiB");
		const mime = imageType(bytes);
		if (!mime || mime !== contentType.toLowerCase())
			fail(415, "Upload a PNG, JPEG, GIF or WebP image");
		let name;
		try {
			name = decodeURIComponent(encodedName);
		} catch {
			fail(400, "Invalid image name");
		}
		name = field(name, "Image name", 200);
		checkCount(cardId);
		return Number(
			q(
				"INSERT INTO images(card_id,name,mime,data,size,created_by,created) VALUES(?,?,?,?,?,?,?)",
			).run(cardId, name, mime, bytes, bytes.length, userId, Date.now())
				.lastInsertRowid,
		);
	}
	function authorize(imageId: number, userId: number) {
		const image = q(
			"SELECT i.id,i.card_id FROM images i JOIN cards c ON c.id=i.card_id JOIN lists l ON l.id=c.list_id JOIN boards b ON b.id=l.board_id JOIN team_members m ON m.team_id=b.team_id WHERE i.id=? AND m.user_id=?",
		).get(imageId, userId);
		if (!image) fail(404, "Image not found");
	}
	function get(imageId: number, userId: number, metadataOnly: boolean) {
		authorize(imageId, userId);
		return metadataOnly
			? q("SELECT mime,size FROM images WHERE id=?").get(imageId)
			: q("SELECT data,mime,size FROM images WHERE id=?").get(imageId);
	}
	function remove(imageId: number, userId: number) {
		authorize(imageId, userId);
		q("DELETE FROM images WHERE id=?").run(imageId);
	}
	return { prepareUpload, add, get, remove };
}
