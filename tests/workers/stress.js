import { args } from "process";
const timeout = setTimeout(() => {
	throw new Error("worker stress timeout");
}, 30000);
for (let round = 0; round < 2; round++) {
	await Promise.all(
		Array.from(
			{ length: 8 },
			(_, i) =>
				new Promise((resolve, reject) => {
					const worker = new Worker("./stress.ts");
					let received = false;
					worker.onerror = (event) => {
						event.preventDefault();
						reject(new Error(event.message));
					};
					worker.onmessage = ({ data }) => {
						if (data.text !== "worker fixture" || data.bytes[8191] !== i)
							return reject(new Error("stress reply corrupted"));
						received = true;
					};
					worker.addEventListener("close", () =>
						received ? resolve() : reject(new Error("missing stress reply")),
					);
					const bytes = new Uint8Array(8192);
					bytes[8191] = i;
					worker.postMessage({ path: args[0], bytes }, [bytes.buffer]);
				}),
		),
	);
}
for (let i = 0; i < 8; i++) {
	const worker = new Worker("./stress.ts");
	worker.onerror = (event) => {
		throw new Error(event.message);
	};
	const closed = new Promise((resolve) =>
		worker.addEventListener("close", resolve),
	);
	await new Promise((resolve) => {
		worker.onmessage = () => {
			worker.terminate();
			resolve();
		};
		worker.postMessage({ stop: true });
	});
	await closed;
}
clearTimeout(timeout);
console.log(
	"Workers: concurrent GC, native jobs, transfers and termination stress passed",
);
