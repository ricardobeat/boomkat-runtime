// Exercises the fetch-style API: run with
//   ./out/test-server-uws 8080 1 examples/api.js
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

({
    async fetch(req) {
        const url = new URL(req.url);
        switch (url.pathname) {
            case "/":
                return new Response("hello");
            case "/json":
                return Response.json({ method: req.method, q: url.searchParams.get("q"), ua: req.headers.get("user-agent") });
            case "/echo":
                return new Response(await req.text(), { headers: { "content-type": req.headers.get("content-type") || "text/plain" } });
            case "/post-json": {
                const body = await req.json();
                return Response.json({ got: body, n: Object.keys(body).length }, { status: 201 });
            }
            case "/slow":
                await sleep(50);
                return new Response("slept");
            case "/redirect":
                return Response.redirect("/", 301);
            case "/headers": {
                const h = new Headers({ "X-One": "1" });
                h.append("set-cookie", "a=1");
                h.append("set-cookie", "b=2");
                return new Response(null, { status: 204, headers: h });
            }
            case "/throw":
                throw new Error("boom");
            case "/teapot":
                return new Response("short and stout", { status: 418, statusText: "I'm a teapot" });
            case "/bytes":
                return new Response(new TextEncoder().encode("héllo"));
            default:
                return new Response("not found: " + url.pathname, { status: 404 });
        }
    },
})
