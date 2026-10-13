postMessage("ready");
onmessage = ({ data }: MessageEvent<{ jobs: number; iterations: number }>) => {
	let result: number = 0;
	for (let job = 0; job < data.jobs; job++) {
		let checksum: number = 0;
		for (let i = 0; i < data.iterations; i++) checksum += i & 1023;
		result += checksum;
	}
	postMessage(result);
};
