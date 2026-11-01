import { createServices } from "./services.ts";
import { createRoutes } from "./http/router.ts";
import { json, errorResponse } from "../lib/http.ts";
import { createAssets } from "./http/assets.ts";
import type { Platform } from "./platform.ts";

export async function startTaskboard(platform: Platform) {
	const root = platform.dirname(platform.main);
	const port = Number(platform.args[0] || 8080);
	if (!Number.isInteger(port) || port < 1 || port > 65535)
		throw new Error("port must be between 1 and 65535");
	const dataDir = platform.resolve(platform.args[1] || root + "/data");
	const origin = new URL(platform.args[2] || `http://127.0.0.1:${port}`).origin;
	let hostname = "127.0.0.1";
	let snapshotCache = false;
	for (const option of platform.args.slice(3)) {
		if (option === "--snapshot-cache") snapshotCache = true;
		else if (option.startsWith("--hostname=") && option.length > 11)
			hostname = option.slice(11);
		else throw new Error("unknown Taskboard option: " + option);
	}
	await platform.mkdir(dataDir, { recursive: true });
	const db = new platform.Database(dataDir + "/taskboard.sqlite");
	try {
		// Independent server workers share one WAL writer; wait for short commits.
		db.exec("PRAGMA busy_timeout=5000");
		db.exec(await platform.readText(root + "/schema.sql"));
		// Let SQLite read database pages directly; WAL writes keep FULL durability.
		db.exec("PRAGMA mmap_size=268435456");
		const services = await createServices(
			db,
			platform,
			snapshotCache,
		);
		const assets = await createAssets(platform, root);
		const routes = createRoutes(services, platform, origin);
		for (const [path, response] of Object.entries(assets)) {
			routes[path] = {
				GET: response,
				HEAD: new Response(null, {
					status: response.status,
					headers: response.headers,
				}),
			};
		}
		return platform.serve({
			hostname,
			port,
			routes,
			fetch: () => json({ error: "Not found" }, 404),
			error: errorResponse,
			onListen() {
				console.log(
					`Taskboard: ${origin}\nDatabase: ${dataDir}/taskboard.sqlite`,
				);
			},
		});
	} catch (error) {
		db.close();
		throw error;
	}
}
