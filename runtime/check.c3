// `bkr check script.js`: which built-ins a module graph imports, and so which
// permissions to expect. A textual scan, not a guarantee: dynamic specifiers
// are only caught when they are string literals.
module bkr;

import std::io;
import std::collections::list;

struct Needs {
    String name;
    String perms;
}

const String[] MARKERS = { "from ", "import ", "import(", "require(" };

const Needs[] NEEDS = {
    { "http", "net" },
    { "net", "net" },
    { "file", "read write" },
    { "process", "env run" },
    { "permissions", "" },
    { "path", "" },
};

fn void scan(String file, List{String}* seen, List{String}* found) {
    foreach (s : *seen) if (s == file) return;
    seen.push(file.copy(mem));
    char[]? src = file::load(mem, file);
    if (catch src) {
        io::eprintfn("warning: cannot read %s", file);
        return;
    }
    String text = (String)src;
    foreach (String marker : MARKERS) {
        usz at = 0;
        while (at < text.len) {
            sz? hit = text[at..].index_of(marker);
            if (catch hit) break;
            usz p = at + (usz)hit + marker.len;
            at = p;
            while (p < text.len && text[p] == ' ') p++;
            if (p >= text.len || (text[p] != '"' && text[p] != '\'')) continue;
            usz end = p + 1;
            while (end < text.len && text[end] != text[p]) end++;
            String spec = text[p + 1:end - p - 1];
            if (spec.starts_with(".") || spec.starts_with("/")) {
                String dir = file[:file.rindex_of_char('/') ?? 0];
                scan(absolute(spec, dir).copy(mem), seen, found);
            } else {
                bool dup;
                foreach (f : *found) dup |= f == spec;
                if (!dup) found.push(spec.copy(mem));
            }
        }
    }
    if (text.contains("fetch(") && !found.contains("fetch")) found.push("fetch");
}

fn int check_main(String script) {
    List{String} seen;
    List{String} found;
    seen.init(mem);
    found.init(mem);
    String abs = absolute(script).copy(mem);
    scan(abs, &seen, &found);
    io::printfn("%d modules scanned", seen.len());
    String[] perms;
    List{String} wanted;
    wanted.tinit();
    foreach (f : found) {
        String need  = f == "fetch" ? "net" : "";
        bool builtin = f == "fetch";
        foreach (n : NEEDS) {
            if (n.name == f) {
                need = n.perms;
                builtin = true;
            }
        }
        if (!builtin) {
            io::printfn("  %s: not a built-in (remote imports are unsupported)", f);
            continue;
        }
        io::printfn("  %s%s%s", f, need.len ? " -> " : "", need);
        foreach (p : need.tsplit(" ")) if (p.len && !wanted.contains(p)) wanted.push(p);
    }
    if (wanted.len()) {
        DString flags = dstring::temp();
        foreach (p : wanted) flags.appendf(" --allow-%s", p);
        io::printfn("try:%s", flags.str_view());
    }
    return 0;
}