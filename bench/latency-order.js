import { serve } from "http";
import { args } from "process";
const events = [];
const byte = new Uint8Array([120]);
serve({ port: Number(args[0]), hostname: "127.0.0.1", onListen() {}, fetch(req) {
    if (new URL(req.url).pathname === "/trace") return Response.json(events);
    events.push("fetch");
    let n = 0;
    const stream = new ReadableStream({ pull(controller) {
        events.push(controller.constructor.name);
        if (n++ === 1) controller.close(); else controller.enqueue(byte);
    } });
    events.push("return");
    return new Response(stream);
} });
