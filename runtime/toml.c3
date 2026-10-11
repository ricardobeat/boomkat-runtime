// The TOML subset boomkat.toml uses: [tables], and keys set to strings,
// integers, booleans or arrays of strings. Everything lives in tmem.
module bkr;

import std::collections::list;

enum TomlKind
{
    STRING,
    INT,
    BOOL,
    LIST,
}

struct TomlValue
{
    TomlKind kind;
    String str;
    long num;
    bool flag;
    List{String} list;
}

struct TomlEntry
{
    String table;
    String key;
    TomlValue value;
}

struct Toml
{
    List{TomlEntry} entries;
}

struct TomlParser
{
    String src;
    usz at;
}

fn Toml? toml_parse(String src)
{
    TomlParser p = { src, 0 };
    Toml t;
    t.entries.tinit();
    String table = "";
    while (true)
    {
        p.skip_space(true);
        if (p.at >= src.len) return t;
        if (src[p.at] == '[')
        {
            p.at++;
            table = p.bare();
            if (!p.eat(']')) return BAD_CONFIG~;
            continue;
        }
        String key = p.peek() == '"' ? p.quoted()! : p.bare();
        if (!key.len) return BAD_CONFIG~;
        p.skip_space(false);
        if (!p.eat('=')) return BAD_CONFIG~;
        t.entries.push({ table, key, p.value()! });
    }
}

fn char TomlParser.peek(&self) => self.at < self.src.len ? self.src[self.at] : 0;

fn bool TomlParser.eat(&self, char c)
{
    self.skip_space(false);
    if (self.peek() != c) return false;
    self.at++;
    return true;
}

fn void TomlParser.skip_space(&self, bool newlines)
{
    while (self.at < self.src.len)
    {
        char c = self.src[self.at];
        if (c == '#')
        {
            while (self.at < self.src.len && self.src[self.at] != '\n') self.at++;
        }
        else if (c == ' ' || c == '\t' || c == '\r' || (newlines && c == '\n'))
        {
            self.at++;
        }
        else
        {
            return;
        }
    }
}

fn String TomlParser.bare(&self)
{
    self.skip_space(false);
    usz start = self.at;
    while (self.at < self.src.len)
    {
        char c = self.src[self.at];
        if (!c.is_alnum() && c != '_' && c != '-' && c != '.') break;
        self.at++;
    }
    return self.src[start:self.at - start];
}

fn String? TomlParser.quoted(&self)
{
    char q = self.src[self.at++];
    DString out = dstring::temp();
    while (self.at < self.src.len)
    {
        char c = self.src[self.at++];
        if (c == q) return out.str_view();
        if (c == '\\' && q == '"' && self.at < self.src.len)
        {
            char e = self.src[self.at++];
            switch (e)
            {
                case 'n': out.append('\n');
                case 't': out.append('\t');
                default: out.append(e);
            }
            continue;
        }
        out.append(c);
    }
    return BAD_CONFIG~;
}

fn TomlValue? TomlParser.value(&self)
{
    self.skip_space(false);
    char c = self.peek();
    if (c == '"' || c == '\'') return { .kind = STRING, .str = self.quoted()! };
    if (c == '[')
    {
        self.at++;
        TomlValue v = { .kind = LIST };
        v.list.tinit();
        while (true)
        {
            self.skip_space(true);
            if (self.peek() == ']') { self.at++; return v; }
            if (self.peek() != '"' && self.peek() != '\'') return BAD_CONFIG~;
            v.list.push(self.quoted()!);
            self.skip_space(true);
            if (self.peek() == ',') self.at++;
        }
    }
    String word = self.bare();
    if (word == "true") return { .kind = BOOL, .flag = true };
    if (word == "false") return { .kind = BOOL, .flag = false };
    return { .kind = INT, .num = word.to_long() ?? BAD_CONFIG~! };
}
