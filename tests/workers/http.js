const timeout = setTimeout(() => {
	throw new Error("worker HTTP timeout");
}, 10000);
const worker = new Worker("./server.ts");
const closed = new Promise((resolve) =>
	worker.addEventListener("close", resolve, { once: true }),
);
worker.onerror = (e) => {
	throw new Error(e.message);
};
const port = await new Promise(
	(resolve) => (worker.onmessage = (e) => resolve(e.data.port)),
);
for (let i = 0; i < 5; i++) {
	const response = await fetch("http://127.0.0.1:" + port + "/");
	if ((await response.text()) !== "worker HTTP")
		throw new Error("worker server response");
}
worker.terminate();
await closed;
clearTimeout(timeout);
console.log("Worker HTTP: own loop, requests and shutdown passed");
