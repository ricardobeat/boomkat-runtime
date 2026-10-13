import { readText, writeText } from "file";
onmessage = async (e) => {
	const result = {};
	try {
		await readText(e.data.path);
		result.read = "allowed";
	} catch (error) {
		result.read = error.code;
	}
	try {
		await writeText(e.data.path, "escape");
		result.write = "allowed";
	} catch (error) {
		result.write = error.code;
	}
	postMessage(result);
	close();
};
