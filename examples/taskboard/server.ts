import * as platform from "./platform.ts";
import { startTaskboard } from "./server/application.ts";

await startTaskboard(platform);
