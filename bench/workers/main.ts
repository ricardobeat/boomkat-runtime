import { args } from "process";
const jobs: number = 4,
	iterations: number = 50_000_000;
const expected: number =
	Math.floor(iterations / 1024) * ((1023 * 1024) / 2) +
	((iterations % 1024) * ((iterations % 1024) - 1)) / 2;
const timeout = setTimeout(() => {
	throw new Error("worker benchmark timed out");
}, 30000);
const counts: number[] = args.length ? [Number(args[0])] : [1, 2, 4];
if (counts.some((count) => ![1, 2, 4].includes(count)))
	throw new Error("Use 1, 2 or 4 workers");
for (const count of counts) {
	const start = performance.now();
	const workers = Array.from({ length: count }, () => new Worker("./job.ts"));
	await Promise.all(
		workers.map(
			(worker) =>
				new Promise<void>((resolve, reject) => {
					worker.onerror = (event) => {
						event.preventDefault();
						reject(new Error(event.message));
					};
					worker.onmessage = () => resolve();
				}),
		),
	);
	const ready = performance.now();
	const results = await Promise.all(
		workers.map(
			(worker) =>
				new Promise<number>((resolve) => {
					worker.onmessage = ({ data }) => resolve(data);
					worker.postMessage({ jobs: jobs / count, iterations });
				}),
		),
	);
	const done = performance.now();
	if (results.reduce((sum, result) => sum + result, 0) !== expected * jobs)
		throw new Error("Incorrect worker checksum");
	await Promise.all(
		workers.map(
			(worker) =>
				new Promise<void>((resolve) => {
					worker.addEventListener("close", () => resolve(), { once: true });
					worker.terminate();
				}),
		),
	);
	console.log(
		JSON.stringify({
			workers: count,
			iterations: iterations * jobs,
			startup_ms: ready - start,
			work_ms: done - ready,
			total_ms: done - start,
		}),
	);
}
clearTimeout(timeout);
