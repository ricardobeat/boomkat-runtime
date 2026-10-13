import { serve } from "http";
const server = serve({
	hostname: "127.0.0.1",
	port: 0,
	fetch: (request) => new Response("worker HTTP"),
});
postMessage({ port: server.port });
