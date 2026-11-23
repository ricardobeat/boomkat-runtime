import { serve } from "http";
import { args } from "process";

const dir = args[0];

serve({
    hostname: "127.0.0.1",
    port: Number(args[1]),
    routes: {
        "/app/*": { dir, transpile: true },
        "/inline/*": { dir, transpile: true, sourceMaps: "inline" },
        "/raw/*": { dir },
    },
});
