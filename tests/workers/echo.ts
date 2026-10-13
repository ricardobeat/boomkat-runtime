import { moduleMarker } from "./helper.ts";
import { readText } from "file";
import { hashPassword, verifyPassword } from "crypto";
import { Database } from "sqlite";
let count: number = 0;
onmessage = async function (event) {
	count++;
	const value = event.data;
	if (value?.command === "native") {
		const text = await readText(value.path);
		const hash = await hashPassword("worker password");
		const db = new Database(":memory:");
		const row = db.prepare("SELECT ? AS value").get(count);
		db.close();
		postMessage({
			text,
			valid: await verifyPassword("worker password", hash),
			saltChars: hash.split("$")[4].length,
			row: row.value,
		});
		return;
	}
	if (value?.command === "nested") {
		const child = new Worker("./echo.ts", { name: "nested" });
		child.onmessage = (e) => {
			postMessage(e.data);
			child.terminate();
		};
		child.postMessage({ nested: true });
		return;
	}
	if (value?.command === "transfer") {
		const bytes = new Uint8Array([9, 8, 7]);
		postMessage(bytes, [bytes.buffer]);
		postMessage({ detached: bytes.byteLength === 0 });
		return;
	}
	if (value?.command === "self-close") {
		postMessage("closing");
		close();
		return;
	}
	postMessage({
		value,
		count,
		name,
		moduleMarker,
		isolated: globalThis.parentMark === undefined,
		target: event.target === self,
		receiver: this === self,
	});
};
