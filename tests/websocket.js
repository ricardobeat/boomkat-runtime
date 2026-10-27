// WebSocket server (upgradeWebSocket) and client (global WebSocket) against
// each other: messages, routes, async upgrades, subprotocols, close codes and
// a client that disappears without a close frame.
// Run: bkr --no-sandbox -A websocket.js
import { serve, upgradeWebSocket } from "http";
import { execPath, exit, spawn } from "process";
import { remove, writeText } from "file";

const serverCloses = [];
const echo = (socket) => {
    socket.onmessage = (e) => {
        if (e.data === "close-me") socket.close(4001, "server says bye");
        else socket.send(e.data);
    };
    socket.onclose = (e) => serverCloses.push(e.code);
};
const server = serve({
    port: 0,
    hostname: "127.0.0.1",
    routes: {
        "/route/:name": (req) => {
            const { socket, response } = upgradeWebSocket(req);
            socket.onopen = () => socket.send("hello " + req.params.name);
            return response;
        },
        "/static": new Response("static"),
    },
    async fetch(req) {
        const path = new URL(req.url).pathname;
        if (path === "/declined") return new Response("no", { status: 403 });
        if (path === "/plain") {
            try { upgradeWebSocket(req); } catch (e) { return new Response(e.message); }
        }
        if (path === "/async") await new Promise(r => setTimeout(r, 10));
        const { socket, response } = upgradeWebSocket(req, path === "/proto" ? { protocol: "chat" } : undefined);
        echo(socket);
        return response;
    },
});
const base = `ws://127.0.0.1:${server.port}`;

// Opens a socket, sends `messages` once open, and resolves with what arrived
// before the close.
function session(path, { protocols, messages = [], expect = messages.length, binaryType } = {}) {
    return new Promise((resolve) => {
        const ws = new WebSocket(base + path, protocols);
        if (binaryType) ws.binaryType = binaryType;
        const got = [];
        let errored = false;
        ws.onopen = () => { for (const m of messages) ws.send(m); if (!expect) ws.close(); };
        ws.onmessage = async (e) => {
            const d = e.data;
            got.push(typeof d === "string" ? d : d instanceof Blob ? "blob:" + d.size : "buffer:" + d.byteLength);
            if (got.length === expect) ws.close(1000, "done");
        };
        ws.onerror = () => { errored = true; };
        ws.onclose = (e) => resolve({ got, code: e.code, reason: e.reason, clean: e.wasClean, errored, protocol: ws.protocol });
    });
}

const failures = [];
function check(name, actual, expected) {
    const a = JSON.stringify(actual), b = JSON.stringify(expected);
    if (a !== b) failures.push(`${name}\n    expected ${b}\n    actual   ${a}`);
}

let r = await session("/echo", { messages: ["text", new Uint8Array([1, 2, 3]), "x".repeat(70000)], binaryType: "arraybuffer" });
check("echo text, binary and a 70 KB frame", r, { got: ["text", "buffer:3", "x".repeat(70000)], code: 1000, reason: "done", clean: true, errored: false, protocol: "" });

r = await session("/echo", { messages: [new Uint8Array(300000), new Blob(["abc"]), "after blob"] });
check("blob binaryType, Blob send keeps order", r.got, ["blob:300000", "blob:3", "after blob"]);

r = await session("/route/ada", { expect: 1 });
check("upgrade from a route handler", r.got, ["hello ada"]);

r = await session("/async", { messages: ["late"] });
check("upgrade after an await", r.got, ["late"]);

r = await session("/proto", { protocols: ["x", "chat"], messages: ["p"] });
check("subprotocol selection", [r.protocol, r.got], ["chat", ["p"]]);

r = await session("/echo", { messages: ["close-me"], expect: 1 });
check("server-initiated close", [r.code, r.reason, r.clean], [4001, "server says bye", true]);

r = await session("/declined");
check("declined upgrade", [r.code, r.errored, r.clean], [1006, true, false]);

const plain = await fetch(`http://127.0.0.1:${server.port}/plain`);
check("upgradeWebSocket on a plain request throws", await plain.text(), "request is not a WebSocket upgrade");
check("static route beside WebSocket routes", await (await fetch(`http://127.0.0.1:${server.port}/static`)).text(), "static");

let threw = "";
try { new WebSocket(base + "/echo").send("too early"); } catch (e) { threw = e.name; }
check("send while connecting", threw, "InvalidStateError");

// A client process that exits without a close frame.
const before = serverCloses.length;
const script = `/tmp/bkr-websocket-${Date.now()}.js`;
await writeText(script, `import { exit } from "process";
    const ws = new WebSocket("${base}/echo");
    ws.onopen = () => exit(0);`);
await spawn(execPath, { args: ["--no-sandbox", "-A", script] }).status;
await remove(script);
await new Promise(r => setTimeout(r, 200));
check("abrupt client disconnect", serverCloses.slice(before), [1006]);

await server.stop(true);
if (failures.length) {
    console.error("websocket failed:\n  " + failures.join("\n  "));
    exit(1);
}
console.log("websocket: all checks passed");
