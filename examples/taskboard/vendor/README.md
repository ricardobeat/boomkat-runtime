Preact **11.0.1** is the complete published upstream package: source files,
hooks, JSX runtime, browser ES modules, TypeScript declarations, metadata,
and MIT license. Downloaded directly from
[the pinned archive](https://registry.npmjs.org/preact/-/preact-11.0.1.tgz),
without invoking npm. The published SHA-512 integrity value is pinned in
`../fetch_vendor.py`, which can reproduce the download.

The application only serves these upstream browser modules:

- `preact/dist/preact.mjs`
- `preact/hooks/dist/hooks.mjs`
- `preact/jsx-runtime/dist/jsxRuntime.mjs`

An HTML import map resolves their bare imports to local routes. No CDN is
needed at runtime. Upstream sources are unmodified.
