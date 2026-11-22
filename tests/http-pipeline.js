import { serve } from "http";
import { args } from "process";

// Spins ~50 us per request so a burst of pipelined requests exhausts the
// per-iteration budget; replies with the request path so order is checkable.
serve({
  hostname: "127.0.0.1", port: Number(args[0]),
  fetch(req) {
    const until = performance.now() + 0.05;
    while (performance.now() < until) {}
    return new Response(new URL(req.url).pathname);
  },
});
