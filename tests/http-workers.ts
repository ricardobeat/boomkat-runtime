import { serve } from "http";
import { args } from "process";
const identity: string = globalThis.name || "main";
let count: number = 0;
const server = serve({
	hostname: "127.0.0.1",
	port: Number(args[0]),
	fetch: async (request) => {
		if (new URL(request.url).pathname === "/slow") {
			await new Promise((resolve) => setTimeout(resolve, 450));
			return new Response(new Uint8Array(4 * 1024 * 1024).fill(7));
		}
		return new Response(
			JSON.stringify({
				identity,
				count: ++count,
				body: await request.text(),
			}),
		);
	},
});
await server.ready;
if (identity === "main") {
	console.log("POOL_READY " + server.workers);
	setTimeout(async () => {
		await server.stop(args[1] !== "graceful");
		console.log("POOL_STOPPED " + server.workers);
	}, 1500);
}
