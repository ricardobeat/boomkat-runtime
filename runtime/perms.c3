// Permissions. Everything is denied until a flag, the config file or a
// prompt grants it. The state lives here, out of JS's reach, and every op
// that touches the outside world asks one of the check functions first.
module bkr;

import std::io;
import std::collections::list;
import libc;

enum Perm : char (String name)
{
    NET { "net" },
    READ { "read" },
    WRITE { "write" },
    ENV { "env" },
    RUN { "run" },
    FFI { "ffi" },
    SYS { "sys" },
    IMPORT { "import" },
}

struct Grant
{
    bool all;
    List{String} allow;
    List{String} deny;
}

struct Permissions
{
    Grant[Perm::len] grants;
    bool prompt;
    bool locked;   // an OS sandbox is applied; nothing can be widened
}

Permissions g_perms;

fn Grant* grant(Perm p) => &g_perms.grants[p.ordinal];

fn void init_perms()
{
    foreach (&g : g_perms.grants)
    {
        g.allow.init(mem);
        g.deny.init(mem);
    }
}

// ---- matching ----

// "host", "host:port", "*.suffix", "[v6]:port", ":port".
fn bool net_match(String entry, String host, int port)
{
    String eh = entry;
    String ep = "";
    if (entry.starts_with("["))
    {
        sz close = entry.index_of_char(']') ?? entry.len - 1;
        eh = entry[1:close - 1];
        if (close + 1 < entry.len) ep = entry[close + 2..];
    }
    else if (entry.count(":") == 1)
    {
        sz colon = entry.index_of_char(':')!!;
        eh = entry[:colon];
        ep = entry[colon + 1..];
    }
    if (ep.len && (ep.to_int() ?? -2) != port) return false;
    if (!eh.len) return true;
    if (eh.starts_with("*.")) return host.ends_with(eh[1..]) || host == eh[2..];
    return eh == host;
}

fn bool path_match(String entry, String path)
{
    if (!path.starts_with(entry)) return false;
    return path.len == entry.len || entry.ends_with("/") || path[entry.len] == '/';
}

fn bool name_match(String entry, String name)
{
    if (entry.ends_with("*")) return name.starts_with(entry[:entry.len - 1]);
    return entry == name;
}

fn bool Perm.matches(self, String entry, String item, int port)
{
    switch (self)
    {
        case NET: return net_match(entry, item, port);
        case READ:
        case WRITE: return path_match(entry, item);
        case RUN: return entry == item || (!entry.contains("/") && basename(item) == entry);
        default: return name_match(entry, item);
    }
}

fn bool Grant.denies(&self, Perm p, String item, int port)
{
    foreach (e : self.deny) if (p.matches(e, item, port)) return true;
    return false;
}

fn bool Grant.allows(&self, Perm p, String item, int port)
{
    if (self.all) return true;
    foreach (e : self.allow) if (p.matches(e, item, port)) return true;
    return false;
}

enum PermState
{
    GRANTED,
    PROMPT,
    DENIED,
}

fn PermState query(Perm p, String item = "", int port = -1)
{
    Grant* g = grant(p);
    if (item.len)
    {
        if (g.denies(p, item, port)) return DENIED;
        if (g.allows(p, item, port)) return GRANTED;
    }
    else if (g.all && !g.deny.len())
    {
        return GRANTED;
    }
    return g_perms.prompt && !g_perms.locked ? PROMPT : DENIED;
}

// ---- checking ----

fn bool check(Perm p, String item, int port = -1)
{
    switch (query(p, item, port))
    {
        case GRANTED: return true;
        case DENIED: return false;
        case PROMPT: return ask(p, item, port);
    }
}

fn String describe(String item, int port) => port >= 0 ? string::tformat("%s:%d", item, port) : item;

// y grants this item, A the whole category, n denies it for the session.
fn bool ask(Perm p, String item, int port)
{
    File? tty = file::open("/dev/tty", "r+");
    if (catch tty) return false;
    defer (void)tty.close();
    String what = describe(item, port);
    while (true)
    {
        io::fprintf(&tty, "\e[1m⚠ allow %s access to \"%s\"?\e[0m [y/n/A] ", p.name, what)!!;
        (void)tty.flush();
        String? line = io::treadline(&tty);
        if (catch line) return false;
        switch (line.trim())
        {
            case "y":
                grant(p).allow.push(p == NET && port >= 0 ? what.copy(mem) : item.copy(mem));
                return true;
            case "A":
                grant(p).all = true;
                return true;
            case "n":
                grant(p).deny.push(what.copy(mem));
                return false;
        }
    }
}

// The name as given, then every address it resolved to. A grant by name
// covers public addresses only: reaching loopback or a private range needs
// that address granted, so a hostile DNS answer cannot turn a grant for
// example.com into one for the local network.
fn bool check_net(String host, int port) => check(NET, host, port);

fn bool check_net_addr(String host, String ip, int port)
{
    if (grant(NET).all && !grant(NET).deny.len()) return true;
    if (host == ip || !is_internal(ip)) return !grant(NET).denies(NET, ip, port);
    if (host == "localhost" && is_loopback(ip)) return true;
    return check(NET, ip, port);
}

fn bool is_loopback(String ip) => ip.starts_with("127.") || ip == "::1";

fn bool is_internal(String ip)
{
    if (is_loopback(ip) || ip.starts_with("10.") || ip.starts_with("192.168.") || ip.starts_with("169.254.")
        || ip == "0.0.0.0" || ip == "::" || ip.starts_with("fe80:") || ip.starts_with("fc") || ip.starts_with("fd"))
    {
        return true;
    }
    if (ip.starts_with("172."))
    {
        int second = ip[4..].tsplit(".")[0].to_int() ?? 0;
        return second >= 16 && second < 32;
    }
    return false;
}

// `path` must already be canonical (see canonical()).
fn bool check_path(Perm p, String path) => check(p, path);

fn bool check_env(String name) => check(ENV, name);

// ---- revoking ----

fn void revoke(Perm p, String item)
{
    Grant* g = grant(p);
    if (!item.len)
    {
        g.all = false;
        g.allow.clear();
        return;
    }
    g.deny.push(item.copy(mem));
}

// ---- paths ----

extern fn ZString realpath(ZString path, char* resolved);

fn String basename(String path)
{
    sz? slash = path.rindex_of_char('/');
    if (catch slash) return path;
    return path[slash + 1..];
}

// Absolute and lexically normalised, in tmem.
fn String absolute(String path, String base = "")
{
    String p = path;
    if (!p.starts_with("/"))
    {
        String b = base.len ? base : (String)(path::tcwd() ?? (Path)"/");
        p = string::tformat("%s/%s", b, p);
    }
    List{String} parts;
    parts.tinit();
    foreach (seg : p.tsplit("/"))
    {
        if (seg == "" || seg == ".") continue;
        if (seg == "..")
        {
            if (parts.len()) (void)parts.pop();
            continue;
        }
        parts.push(seg);
    }
    if (!parts.len()) return "/";
    DString out = dstring::temp();
    foreach (s : parts)
    {
        out.append('/');
        out.append(s);
    }
    return out.str_view();
}

// The real path: symlinks resolved for the part that exists, the rest
// appended lexically. In tmem.
fn String canonical(String path, String base = "")
{
    String abs = absolute(path, base);
    String head = abs;
    String tail = "";
    while (true)
    {
        char[4096] buf;
        if (realpath(head.zstr_tcopy(), &buf))
        {
            String real = ((ZString)&buf).str_view();
            if (!tail.len) return real.tcopy();
            return string::tformat("%s/%s", real == "/" ? "" : real, tail);
        }
        if (head == "/") return abs;
        sz slash = head.rindex_of_char('/') ?? 0;
        String seg = head[slash + 1..];
        tail = tail.len ? string::tformat("%s/%s", seg, tail) : seg;
        head = slash ? head[:slash] : "/";
    }
}

// ---- configuration ----

// --allow-<perm>[=a,b], --deny-<perm>=a,b, -A / --allow-all, --no-prompt.
// Returns false for an argument that is not a permission flag.
fn bool? parse_perm_flag(String arg)
{
    if (arg == "-A" || arg == "--allow-all")
    {
        foreach (&g : g_perms.grants) g.all = true;
        return true;
    }
    if (arg == "--no-prompt") { g_perms.prompt = false; return true; }
    if (arg == "--prompt") { g_perms.prompt = true; return true; }
    bool deny = arg.starts_with("--deny-");
    if (!deny && !arg.starts_with("--allow-")) return false;
    String rest = arg[deny ? 7 : 8..];
    String name = rest;
    String list = "";
    bool has_list = false;
    if (try eq = rest.index_of_char('='))
    {
        name = rest[:eq];
        list = rest[eq + 1..];
        has_list = true;
    }
    Perm p = perm_named(name) ?? BAD_FLAG~!;
    Grant* g = grant(p);
    if (!has_list)
    {
        if (deny) return BAD_FLAG~;
        g.all = true;
        return true;
    }
    foreach (item : list.tsplit(","))
    {
        if (!item.len) continue;
        add_entry(p, deny ? &g.deny : &g.allow, item, "");
    }
    return true;
}

faultdef BAD_FLAG, BAD_CONFIG;

fn Perm? perm_named(String name)
{
    foreach (p : Perm::values) if (p.name == name) return p;
    return BAD_FLAG~;
}

fn void add_entry(Perm p, List{String}* list, String item, String base)
{
    String e = item;
    if (p == READ || p == WRITE) e = canonical(item, base);
    list.push(e.copy(mem));
}

// [permissions] from boomkat.toml: `prompt = bool`, and for each category
// `true`, `false` or a list of entries. Relative paths are taken from the
// file's directory.
fn void? load_config(String file_path)
{
    char[] src = file::load_temp(file_path)!;
    String base = absolute(file_path);
    base = base[:base.rindex_of_char('/') ?? 0];
    if (!base.len) base = "/";
    Toml t = toml_parse((String)src)!;
    foreach (kv : t.entries)
    {
        if (kv.table != "permissions") continue;
        if (kv.key == "prompt")
        {
            g_perms.prompt = kv.value.flag;
            continue;
        }
        Perm? p = perm_named(kv.key);
        if (catch p) return BAD_CONFIG~;
        Grant* g = grant(p);
        switch (kv.value.kind)
        {
            case BOOL: g.all = kv.value.flag;
            case LIST: foreach (item : kv.value.list) add_entry(p, &g.allow, item, base);
            default: return BAD_CONFIG~;
        }
    }
}
