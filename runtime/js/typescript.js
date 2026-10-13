const bk = __bk;

// Parse with Boomkat's TypeScript/JSX frontend and print the resulting JS AST.
// This performs syntax validation, not type checking or downlevel compilation.
export function transpile(source, options = {}) {
    if (typeof source !== "string") throw new TypeError("source must be a string");
    const filename = options.filename === undefined ? "module.ts" : String(options.filename);
    const jsx = options.jsx === undefined ? "automatic" : String(options.jsx);
    if (jsx !== "automatic" && jsx !== "classic") throw new TypeError("jsx must be automatic or classic");
    return bk.transpile(source, /\.[jt]sx$/.test(filename), options.module !== false,
        String(options.jsxFactory === undefined ? "h" : options.jsxFactory),
        String(options.jsxFragmentFactory === undefined ? "Fragment" : options.jsxFragmentFactory),
        String(options.jsxImportSource === undefined ? "preact" : options.jsxImportSource), jsx === "automatic");
}
