import { serve } from "http";
import { args } from "process";
const payload = "x".repeat(79040);
serve({
  hostname: "127.0.0.1", port: Number(args[0]),
  async fetch(req) {
    if (req.url.endsWith("/slow")) {
      const until = Date.now() + 1;
      while (Date.now() < until) {}
    }
    return new Response(payload);
  },
});
