// A synchronous handler makes server CPU parallelism visible without requiring
// the loopback load generator to produce hundreds of thousands of requests/s.
import { serve } from "http";
import { args } from "process";
serve({
    port: Number(args[0]), hostname: "127.0.0.1", onListen() {},
    fetch(request) {
        if (new URL(request.url).pathname !== "/cpu") return new Response("hello world");
        let value = 1;
        for (let i = 0; i < 10000; i++) value = (Math.imul(value ^ i, 1664525) + 1013904223) | 0;
        return Response.json({ value });
    },
});
