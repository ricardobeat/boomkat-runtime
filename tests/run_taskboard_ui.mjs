// Optional browser check using Node’s built-in WebSocket and Chrome CDP.
// Start Taskboard and headless Chrome with --remote-debugging-port=9223 first.
import { writeFile } from "node:fs/promises";
const base = process.env.TASKBOARD_URL || "http://127.0.0.1:8080";
const cdp = process.env.CHROME_CDP_URL || "http://127.0.0.1:9223";
const targets = await (await fetch(cdp + "/json")).json();
const ws = new WebSocket(targets[0].webSocketDebuggerUrl);
await new Promise((r, j) => {
	ws.onopen = r;
	ws.onerror = j;
});
let seq = 0;
const pending = new Map(),
	errors = [];
ws.onmessage = (e) => {
	const m = JSON.parse(e.data);
	if (m.id) {
		const p = pending.get(m.id);
		pending.delete(m.id);
		m.error ? p.reject(m.error) : p.resolve(m.result);
	} else if (m.method === "Runtime.exceptionThrown")
		errors.push(m.params.exceptionDetails);
	else if (
		m.method === "Log.entryAdded" &&
		m.params.entry.level === "error" &&
		!(
			m.params.entry.url?.endsWith("/api/me") &&
			m.params.entry.text.includes("401")
		)
	)
		errors.push(m.params.entry);
};
function send(method, params = {}) {
	return new Promise((resolve, reject) => {
		const id = ++seq;
		pending.set(id, { resolve, reject });
		ws.send(JSON.stringify({ id, method, params }));
	});
}
async function evaluate(expression) {
	const r = await send("Runtime.evaluate", {
		expression,
		awaitPromise: true,
		returnByValue: true,
	});
	if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
	return r.result.value;
}
async function wait(expression) {
	for (let i = 0; i < 100; i++) {
		if (await evaluate(expression)) return;
		await new Promise((r) => setTimeout(r, 50));
	}
	throw new Error(
		"Timeout " +
			expression +
			"\n" +
			(await evaluate("document.body.innerText")),
	);
}
async function click(text, selector = "button") {
	await evaluate(
		`(()=>{const e=[...document.querySelectorAll(${JSON.stringify(selector)})].find(e=>e.textContent.trim()===${JSON.stringify(text)});if(!e)throw Error('Missing '+${JSON.stringify(text)});e.click()})()`,
	);
}
async function screenshot(file) {
	const { data } = await send("Page.captureScreenshot", {
		format: "png",
		captureBeyondViewport: false,
	});
	await writeFile(file, Buffer.from(data, "base64"));
}
await send("Network.clearBrowserCookies");
await send("Runtime.enable");
await send("Log.enable");
await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", {
	width: 1440,
	height: 1000,
	deviceScaleFactor: 1,
	mobile: false,
});
await send("Page.navigate", { url: base + "/" });
await wait('!!document.querySelector(".auth-panel")');
await screenshot("/tmp/taskboard-auth.png");
await click("Create an account");
const email = "ui" + Date.now() + "@example.com";
await evaluate(
	`(()=>{const f=document.querySelector('.auth-panel form');f.elements.name.value='Alex Morgan';f.elements.email.value=${JSON.stringify(email)};f.elements.password.value='a very good test password';f.requestSubmit()})()`,
);
await wait('!!document.querySelector(".card")');
await screenshot("/tmp/taskboard-board.png");
await click("Add a card");
await evaluate(
	`(()=>{const f=document.querySelector('.add-card');f.elements.title.value='A browser-tested card';f.requestSubmit()})()`,
);
await wait(
	`[...document.querySelectorAll('.card')].some(e=>e.textContent.includes('A browser-tested card'))`,
);
await evaluate(
	`[...document.querySelectorAll('.card')].find(e=>e.textContent.includes('A browser-tested card')).click()`,
);
await wait('!!document.querySelector("dialog[open]")');
await evaluate(
	`(()=>{const f=document.querySelector('dialog form');f.elements.description.value='Edited through real Preact controls';f.elements.list_id.value=f.elements.list_id.options[1].value;document.querySelector('[aria-label="peach"]').click();f.requestSubmit()})()`,
);
await wait('!document.querySelector("dialog[open]")');
await wait(
	`[...document.querySelectorAll('.column')][1].textContent.includes('A browser-tested card')`,
);
await evaluate(
	`[...document.querySelectorAll('.card')].find(e=>e.textContent.includes('A browser-tested card')).click()`,
);
await wait('!!document.querySelector("dialog[open]")');
await evaluate(
	`(()=>{const png=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jFMsAAAAASUVORK5CYII='),c=>c.charCodeAt(0));const dt=new DataTransfer();dt.items.add(new File([png],'pixel.png',{type:'image/png'}));const input=document.querySelector('input[type=file]');input.files=dt.files;input.dispatchEvent(new Event('change',{bubbles:true}))})()`,
);
await wait('!!document.querySelector(".image-grid img")');
await wait(
	'document.querySelector(".image-grid img").complete && document.querySelector(".image-grid img").naturalWidth===1',
);
await screenshot("/tmp/taskboard-card.png");
await evaluate(`document.querySelector('[aria-label="Close dialog"]').click()`);
await click("Add a list");
await wait('!!document.querySelector("dialog[open]")');
await evaluate(
	`(()=>{const f=document.querySelector('dialog form');f.elements.name.value='Review';f.requestSubmit()})()`,
);
await wait(
	`[...document.querySelectorAll('.list-name')].some(e=>e.textContent==='Review')`,
);
await click("New workspace");
await wait('!!document.querySelector("dialog[open]")');
await evaluate(
	`(()=>{const f=document.querySelector('dialog form');f.elements.name.value='Browser team';f.requestSubmit()})()`,
);
await wait(
	'document.querySelector(".topbar").textContent.includes("Browser team")',
);
await wait('!!document.querySelector(".column")');
await send("Emulation.setDeviceMetricsOverride", {
	width: 390,
	height: 844,
	deviceScaleFactor: 1,
	mobile: true,
});
await screenshot("/tmp/taskboard-mobile.png");
await evaluate(
	`document.querySelector('[aria-label="Open navigation"]').click()`,
);
await wait('!!document.querySelector(".sidebar.open")');
await evaluate(`document.querySelector('[aria-label="Sign out"]').click()`);
await wait('!!document.querySelector(".auth-panel")');
if (errors.length) throw new Error("Browser errors: " + JSON.stringify(errors));
console.log(
	"Browser UI: signup, board, card editing/moving, image BLOB upload, lists, teams, responsive navigation and logout: passed",
);
ws.close();
