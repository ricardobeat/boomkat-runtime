const bk = __bk;

// Parse with Boomkat's TypeScript/JSX frontend and print the resulting JS AST.
// This performs syntax validation, not type checking or downlevel compilation.
function run(source, options, map) {
    if (typeof source !== "string") throw new TypeError("source must be a string");
    const filename = options.filename === undefined ? "module.ts" : String(options.filename);
    const jsx = options.jsx === undefined ? "automatic" : String(options.jsx);
    if (jsx !== "automatic" && jsx !== "classic") throw new TypeError("jsx must be automatic or classic");
    return bk.transpile(source, /\.[jt]sx$/.test(filename), options.module !== false,
        String(options.jsxFactory === undefined ? "h" : options.jsxFactory),
        String(options.jsxFragmentFactory === undefined ? "Fragment" : options.jsxFragmentFactory),
        String(options.jsxImportSource === undefined ? "preact" : options.jsxImportSource), jsx === "automatic",
        filename, map ? 1 : 0);
}

// Returns the JavaScript source. With `sourceMap: "inline"` it ends in a
// `//# sourceMappingURL=data:...` comment mapping back to the original.
export function transpile(source, options = {}) {
    if (options.sourceMap !== undefined && options.sourceMap !== false && options.sourceMap !== "inline")
        throw new TypeError('sourceMap must be "inline" or false; use transpileWithMap for a separate map');
    return run(source, options, options.sourceMap === "inline");
}

const MARKER = "\n//# sourceMappingURL=data:application/json;base64,";

// Returns `{ code, map }`: the JavaScript and a version 3 source map as JSON text.
// `code` has no sourceMappingURL comment; add one that points where you serve the map.
export function transpileWithMap(source, options = {}) {
    const out = run(source, options, true);
    const at = out.lastIndexOf(MARKER);
    return { code: out.slice(0, at), map: new TextDecoder().decode(Uint8Array.from(atob(out.slice(at + MARKER.length)), (c) => c.charCodeAt(0))) };
}
