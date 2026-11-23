// With prompting off the grants are fixed for the whole run, so the OS can
// back them up: Seatbelt denies the network, exec and file writes the grants
// do not cover. Reads stay open, since the runtime itself needs the system.
module bkr;

import std::io;

extern fn CInt sandbox_init(ZString profile, ulong flags, char** error) @feat(DARWIN);
extern fn void sandbox_free_error(char* error) @feat(DARWIN);

bool g_sandbox = true;

fn bool any_grant(Perm p) => grant(p).all || grant(p).allow.len() > 0;

fn String sandbox_profile() @feat(DARWIN) {
    DString s = dstring::temp();
    s.append("(version 1)(allow default)");
    if (!any_grant(NET)) s.append("(deny network*)");
    if (!any_grant(RUN)) s.append("(deny process-exec* process-fork)");
    if (!grant(WRITE).all) {
        s.append("(deny file-write*)(allow file-write* (regex #\"^/dev/\")");
        foreach (path : grant(WRITE).allow) s.appendf(" (subpath \"%s\")", canonical(path));
        s.append(")");
    }
    return s.str_view();
}

fn void apply_sandbox() {
    if (!g_sandbox || g_runtime.perms.prompt) return;
    $if env::DARWIN:
        char* err;
        if (sandbox_init(sandbox_profile().zstr_tcopy(), 0, &err) != 0) {
            io::eprintfn("warning: sandbox unavailable: %s", ((ZString)err).str_view());
            sandbox_free_error(err);
        }
    $else
        io::eprintfn("warning: no OS sandbox on this platform; permissions are enforced by the runtime only");
    $endif
}
