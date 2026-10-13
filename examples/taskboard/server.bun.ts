import * as platform from "./bun/platform.ts";
import { startTaskboard } from "./server/application.ts";

await startTaskboard(platform);
