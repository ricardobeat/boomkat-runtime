import type { Platform } from "../platform.ts";

// Explicit routes keep source files, SQLite data, and server modules private.
const browserSources = [
	"app.tsx",
	"client/lib/api.ts",
	"client/lib/errors.ts",
	"client/components/app.tsx",
	"client/components/common.tsx",
	"client/components/auth.tsx",
	"client/components/create-modal.tsx",
	"client/components/members.tsx",
	"client/components/card-editor.tsx",
	"client/components/column.tsx",
];
export async function createAssets(platform: Platform, root: string) {
	const html = await platform.readText(root + "/index.html");
	const importmap = /<script type="importmap">([\s\S]*?)<\/script>/.exec(
		html,
	)![1];
	const mapHash = btoa(String.fromCharCode(...platform.sha256(importmap)));
	const csp = `default-src 'self'; script-src 'self' 'sha256-${mapHash}'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`;
	const headers = {
		"x-content-type-options": "nosniff",
		"content-security-policy": csp,
		"referrer-policy": "same-origin",
		"cache-control": "no-cache",
	};
	function asset(text: string, contentType: string) {
		return new Response(text, {
			headers: { ...headers, "content-type": contentType },
		});
	}
	const assets: Record<string, Response> = {
		"/": asset(html, "text/html; charset=utf-8"),
		"/style.css": asset(
			await platform.readText(root + "/style.css"),
			"text/css; charset=utf-8",
		),
	};
	// Compile each browser module once. Imports use their served .js routes;
	// no bundler, npm packages, or request-time transpilation is required.
	for (const source of browserSources) {
		const route = "/" + source.replace(/\.tsx?$/, ".js");
		assets[route] = asset(
			platform.transpile(await platform.readText(root + "/" + source), {
				filename: source,
				jsxImportSource: "preact",
			}),
			"text/javascript; charset=utf-8",
		);
	}
	for (const [route, path] of [
		["/vendor/preact.mjs", "preact/dist/preact.mjs"],
		["/vendor/hooks.mjs", "preact/hooks/dist/hooks.mjs"],
		["/vendor/jsx-runtime.mjs", "preact/jsx-runtime/dist/jsxRuntime.mjs"],
	])
		assets[route] = asset(
			await platform.readText(root + "/vendor/" + path),
			"text/javascript; charset=utf-8",
		);
	return assets;
}
