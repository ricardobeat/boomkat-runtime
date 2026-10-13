import { readText } from "file";
import { hashPassword } from "crypto";
onmessage = async ({ data }) => {
	const hashing = hashPassword("worker stress password");
	if (data.stop) {
		postMessage("hashing");
		await hashing;
		throw new Error("terminated worker resumed JavaScript");
	}
	const text = await readText(data.path);
	for (let round = 0; round < 5; round++) {
		const objects = [];
		for (let i = 0; i < 6000; i++)
			objects.push({ i, values: [i, i + 1], map: new Map([[i, "value"]]) });
		if (objects[5999].map.get(5999) !== "value")
			throw new Error("worker GC corrupted data");
	}
	await hashing;
	postMessage({ text, bytes: data.bytes });
	close();
};
