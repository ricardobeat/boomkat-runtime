export function imageType(bytes: Uint8Array) {
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
