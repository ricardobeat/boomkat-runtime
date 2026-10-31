import { serve, upgradeWebSocket } from "http";
import { args, pid } from "process";
if (args[1] === "fail") throw new Error("startup failure " + pid);
if (args[1] === "idle") { setInterval(() => {}, 1000); }
else {
    let count = 0, active = 0;
    const server = serve({
        port: Number(args[0]), hostname: "127.0.0.1", onListen() {},
        routes: { "/static": new Response("static", { status: 201, headers: { "x-pid": String(pid) } }) },
        async fetch(request) {
            const path = new URL(request.url).pathname;
            if (path === "/ws") {
                const { socket, response } = upgradeWebSocket(request);
                socket.onmessage = event => socket.send(pid + ":" + event.data);
                return response;
            }
            if (path === "/spin") {
                console.log("PROCESS_SPIN " + pid);
                while (true) {}
            }
            if (path === "/busy") {
                const end = performance.now() + 200;
                while (performance.now() < end) {}
            }
            if (path === "/active") return Response.json({ pid, active });
            if (path === "/slow") {
                active++;
                await new Promise(resolve => setTimeout(resolve, 250));
                active--;
                return new Response(new Uint8Array(1024 * 1024).fill(7));
            }
            if (path === "/stream") {
                let sent = 0;
                return new Response(new ReadableStream({ async pull(controller) {
                    if (sent++ === 3) { controller.close(); return; }
                    await new Promise(resolve => setTimeout(resolve, 1));
                    controller.enqueue(new TextEncoder().encode("chunk"));
                } }));
            }
            if (path === "/stop") setTimeout(() => server.stop(false), 10);
            return Response.json({ pid, count: ++count, port: server.port, body: await request.text() });
        },
    });
    console.log("PROCESS_LISTEN " + pid + " " + server.port);
}
