const worker = new Worker("./sum.ts", { type: "module", name: "sum" });
worker.onerror = (event) => {
	throw new Error(event.message);
};
worker.onmessage = ({ data }) => {
	console.log("Sum:", data);
	worker.terminate();
};
const numbers = new Uint32Array([10, 20, 30, 40]);
worker.postMessage(numbers, [numbers.buffer]);
// Transferring detaches the sender's ArrayBuffer synchronously.
console.log("Sender bytes after transfer:", numbers.byteLength);
