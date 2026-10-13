onmessage = ({ data }: MessageEvent<Uint32Array>) => {
	let sum: number = 0;
	for (const value of data) sum += value;
	postMessage(sum);
};
