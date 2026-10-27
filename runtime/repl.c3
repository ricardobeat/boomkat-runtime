// `bkr` with no script, or `bkr repl [flags]`: an interactive prompt. The
// embedded REPL module reads lines from stdin and evaluates each entry as a
// script, so declarations persist from one entry to the next.
module bkr;

import boomkat;
import std::collections::list;

const String REPL_MAIN = `import "repl";
`;

// The prompt's module path; like the test runner's, it sits in the working
// directory so relative imports and a boomkat.toml there apply.
const String REPL_ENTRY_NAME = "[bkr repl]";

tlocal bool g_repl;

// `bkr`, `bkr repl [flags]` or `bkr [flags]` alone start the prompt; the
// argv gains the prompt's entry in place of a script.
fn String[]? repl_argv(String[] argv) {
    List{String} out;
    out.init(mem);
    out.push(argv[0]);
    foreach (i, a : argv[1..]) {
        if (a == "repl" && i + 2 == argv.len) break;
        if (!a.starts_with("-")) return argv;
        // --config takes the next word, which may be the last.
        if (a == "--config") return argv;
        out.push(a);
    }
    out.push(absolute(REPL_ENTRY_NAME).copy(mem));
    g_repl = true;
    return out.array_view();
}

// replEval(source) -> the completion value; throws what the entry threw
fn void js_repl_eval(JsCtx ctx, void* udata) {
    String source = ctx.arg(0).as_string() ?? "";
    g_runtime.rt.@scope() {
        JsValue? value = g_runtime.rt.eval(source, "<repl>");
        if (catch value) {
            JsValue? thrown = g_runtime.rt.get_exception();
            if (catch thrown) {
                ctx.throw_error(TYPE, g_runtime.rt.last_error());
                return;
            }
            JsArg error;
            g_runtime.rt.load(thrown, &error.tv);
            ctx.throw_value(error);
            return;
        }
        JsArg result;
        g_runtime.rt.load(value, &result.tv);
        ctx.ret(result);
    };
}

const Native[] REPL_NATIVES = {
    { "replEval", &js_repl_eval, 1 },
};
