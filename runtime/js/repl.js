// The interactive prompt for `bkr` and `bkr repl`. Each entry runs as a
// script in the global scope, so declarations persist between entries.
import { stdin } from "process";

const bk = __bk;
const interactive = bk.isatty(0);
const color = interactive && bk.isatty(1);
const paint = (code, s) => color ? `\x1b[${code}m${s}\x1b[0m` : s;
const write = (s) => bk.print(1, s);
const prompt = (more) => { if (interactive) write(more ? "... " : "> "); };

const HELP = `.help     show this help
.clear    discard a partly typed entry
.exit     leave (or press Ctrl-D)
_         the last result; _error, the last error
Entries may use await. Declarations made in an entry that awaits persist
only for simple \`const x = ...\` forms.
`;

// Whether `source` stops inside a bracket, string, template or comment, so
// the entry continues on the next line.
function incomplete(source) {
    const stack = [];
    for (let i = 0; i < source.length; i++) {
        const c = source[i], top = stack[stack.length - 1];
        if (top === "`") {
            if (c === "\\") i++;
            else if (c === "`") stack.pop();
            else if (c === "$" && source[i + 1] === "{") { stack.push("${"); i++; }
            continue;
        }
        if (c === "/" && source[i + 1] === "/") { const n = source.indexOf("\n", i); if (n < 0) break; i = n; continue; }
        if (c === "/" && source[i + 1] === "*") { const n = source.indexOf("*/", i + 2); if (n < 0) return true; i = n + 1; continue; }
        if (c === "'" || c === '"') {
            let j = i + 1;
            for (; j < source.length && source[j] !== c && source[j] !== "\n"; j++) if (source[j] === "\\") j++;
            i = j;
            continue;
        }
        if (c === "`" || c === "(" || c === "[" || c === "{") stack.push(c);
        else if (c === ")" || c === "]") stack.pop();
        else if (c === "}") { if (stack.pop() === "${") continue; }
    }
    return stack.length > 0;
}

// An entry with top-level await runs in an async function. Simple
// declarations become globals so later entries still see them.
function asyncEntry(source) {
    const body = source.replace(/^(\s*)(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/gm, "$1globalThis.$2 =");
    const lines = body.trimEnd().split("\n");
    const last = lines.pop();
    const isExpression = last && !/^\s*(?:globalThis\.\w+\s*=|if\b|for\b|while\b|return\b|throw\b|try\b|function\b|class\b|}|\/\/)/.test(last);
    lines.push(isExpression ? `return (${last.replace(/;\s*$/, "")});` : last);
    return `(async () => {\n${lines.join("\n")}\n})()`;
}

// Values print as console.log formats them.
function show(value) {
    if (value === undefined) write(paint(90, "undefined") + "\n");
    else if (typeof value === "string") write(paint(32, JSON.stringify(value)) + "\n");
    else console.log(value);
}

// Boxed, so a promise an entry evaluates to is shown rather than adopted.
async function evaluate(source) {
    try {
        return { value: bk.replEval(source) };
    } catch (e) {
        if (!(e instanceof SyntaxError) || !/\bawait\b/.test(source)) throw e;
        return { value: await bk.replEval(asyncEntry(source)) };
    }
}

function report(e) {
    const text = e instanceof Error ? (e.stack && /\n\s+at /.test(e.stack) ? e.stack : `${e.name}: ${e.message}`) : `Uncaught ${bk.describe(e)}`;
    bk.print(2, paint(31, text) + "\n");
}

addEventListener("unhandledrejection", (e) => {
    e.preventDefault();
    report(e.reason);
});

if (interactive) write(`bkr ${paint(90, "— .help for help, Ctrl-D to exit")}\n`);
const dec = new TextDecoder();
let pending = "";
let entry = "";
prompt(false);
for (;;) {
    const chunk = await stdin.read();
    if (chunk === null) break;
    pending += dec.decode(chunk, { stream: true });
    let nl;
    while ((nl = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, nl);
        pending = pending.slice(nl + 1);
        if (!entry) {
            const command = line.trim();
            if (command === ".exit") bk.exit(0);
            if (command === ".help") { write(HELP); prompt(false); continue; }
            if (command === ".clear" || command === "") { prompt(false); continue; }
        } else if (line.trim() === ".clear") {
            entry = "";
            prompt(false);
            continue;
        }
        entry += (entry ? "\n" : "") + line;
        if (incomplete(entry)) { prompt(true); continue; }
        const source = entry;
        entry = "";
        try {
            const { value } = await evaluate(source);
            globalThis._ = value;
            show(value);
        } catch (e) {
            globalThis._error = e;
            report(e);
        }
        prompt(false);
    }
}
if (interactive) write("\n");
bk.exit(0);
