// A JavaScript source emitter for Boomkat's already-erased/lowered AST.
// The engine parser handles TypeScript and JSX; there is no second TS parser.
module bkr;

import boomkat;
import boomkat::ast;
import boomkat::lexer;

struct SourceWriter {
    Ast* ast;
    DString out;
    uint depth;
    bool failed;
}

fn void SourceWriter.text(&self, String s) => self.out.append(s);
fn void SourceWriter.atom(&self, uint id) => self.out.append_bytes(self.ast.atoms.get(id));

fn void SourceWriter.identifier(&self, uint id) {
    char[] name = self.ast.atoms.get(id);
    Lexer lex   = lexer::lexer_init(name, null);
    defer lex.free_arena();
    if (try tok = lex.next_token()) {
        if (tok.end == name.len && (tok.type == TokenType.IDENTIFIER || lexer::keyword_to_string(tok.type).len)) {
            self.out.append_bytes(name);
            return;
        }
    }
    self.failed = true;
}

fn void SourceWriter.number(&self, uint n) {
    // Keep the exact source literal, avoiding floating point printer rounding.
    uint pos  = self.ast.main_tok[n];
    Lexer lex = lexer::lexer_init(self.ast.source[pos..], null);
    defer lex.free_arena();
    if (try tok = lex.next_token()) {
        self.out.append_bytes(self.ast.source[pos:tok.end]);
    } else {
        self.failed = true;
    }
}

// Atoms are UTF-8/CESU-8. Escape non-ASCII code points (including lone
// surrogates) so the browser receives valid UTF-8 and identical JS strings.
fn void SourceWriter.quote(&self, char[] s) {
    self.text("\"");
    for (usz i; i < s.len; i++) {
        uint c = s[i];
        if (c == '"' || c == '\\') {
            self.out.appendf("\\%c", c);
            continue;
        }
        if (c < 32 || c == 127) {
            self.out.appendf("\\u%04x", c);
            continue;
        }
        if (c < 128) {
            self.out.appendf("%c", c);
            continue;
        }
        uint count = c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
        c &= count == 1 ? 31 : count == 2 ? 15 : 7;
        for (uint j; j < count; j++) {
            if (++i >= s.len) {
                self.failed = true;
                return;
            }
            c = (c << 6) | (s[i] & 63);
        }
        if (c > 0xFFFF) {
            c -= 0x10000;
            self.out.appendf("\\u%04x\\u%04x", 0xD800 + (c >> 10), 0xDC00 + (c & 1023));
        } else {
            self.out.appendf("\\u%04x", c);
        }
    }
    self.text("\"");
}

fn void SourceWriter.quoted_atom(&self, uint id) => self.quote(self.ast.atoms.get(id));

fn void SourceWriter.list(&self, uint list, String separator = ",", bool holes = false) {
    uint len = self.ast.list_len(list);
    for (uint i; i < len; i++) {
        if (i) self.text(separator);
        self.node(self.ast.list_item(list, i));
    }
    // A final elision is an array slot, not merely a trailing comma.
    if (holes && len && !self.ast.list_item(list, len - 1)) self.text(",");
}

fn void SourceWriter.key(&self, uint n, char flags) {
    if (flags & ast::PROP_COMPUTED) {
        self.text("[");
        self.node(n);
        self.text("]");
    } else if (self.ast.tags[n] == NodeTag.NUMBER) {
        self.number(n);
    } else {
        self.node(n);
    }
}

fn void SourceWriter.function_body(&self, uint rec, bool method = false) {
    self.text("(");
    self.list(self.ast.field(rec, ast::FN_PARAMS));
    self.text(")");
    uint flags = self.ast.field(rec, ast::FN_FLAGS);
    if (!method && flags & ast::FNF_EXPR_BODY) self.text("=>");
    self.node(self.ast.field(rec, ast::FN_BODY));
}

fn void SourceWriter.method(&self, uint key, uint fn_node, char flags) {
    uint rec      = self.ast.rhs[fn_node];
    uint fn_flags = self.ast.field(rec, ast::FN_FLAGS);
    if (flags & ast::MEMBER_STATIC) self.text("static ");
    if (flags & ast::MEMBER_GET) self.text("get ");
    if (flags & ast::MEMBER_SET) self.text("set ");
    if (fn_flags & ast::FNF_ASYNC) self.text("async ");
    if (fn_flags & ast::FNF_GENERATOR) self.text("*");
    self.key(key, flags);
    self.function_body(rec, true);
}

fn void SourceWriter.class_body(&self, uint name, uint rec) {
    self.text("class ");
    self.node(name);
    uint heritage = self.ast.field(rec, ast::CLS_HERITAGE);
    if (heritage) {
        self.text(" extends ");
        self.node(heritage);
    }
    self.text("{\n");
    self.list(self.ast.field(rec, ast::CLS_MEMBERS), "\n");
    self.text("}\n");
}

fn void SourceWriter.request(&self, uint req) {
    self.quoted_atom(self.ast.field(req, ast::REQ_SOURCE));
    uint attrs = self.ast.field(req, ast::REQ_ATTRS);
    if (!attrs || !self.ast.list_len(attrs)) return;
    self.text(" with {");
    for (uint i; i < self.ast.list_len(attrs); i += 2) {
        if (i) self.text(",");
        self.quoted_atom(self.ast.list_item(attrs, i));
        self.text(":");
        self.quoted_atom(self.ast.list_item(attrs, i + 1));
    }
    self.text("}");
}

fn void SourceWriter.var_decl(&self, uint n) {
    switch (self.ast.flags[n] & ast::VAR_KIND_MASK) {
        case ast::VAR_KIND_VAR: self.text("var ");
        case ast::VAR_KIND_LET: self.text("let ");
        case ast::VAR_KIND_CONST: self.text("const ");
        case ast::VAR_KIND_USING: self.text("using ");
        case ast::VAR_KIND_AWAIT_USING: self.text("await using ");
        default: self.failed = true;
    }
    self.list(self.ast.lhs[n]);
}

fn void SourceWriter.for_init(&self, uint n) {
    if (n && self.ast.tags[n] == NodeTag.VAR_DECL) {
        self.var_decl(n);
    } else {
        self.node(n);
    }
}

fn void SourceWriter.control_body(&self, uint n) {
    if (n && self.ast.tags[n] == NodeTag.BLOCK) {
        self.node(n);
        return;
    }
    self.text("{");
    self.node(n);
    self.text("}\n");
}

fn void SourceWriter.directive(&self, uint n) {
    // Preserve escapes: "use\\x20strict" must not become a strict directive.
    uint pos   = self.ast.main_tok[n];
    char[] src = self.ast.source;
    if (pos >= src.len || (src[pos] != '\'' && src[pos] != '"')) {
        self.failed = true;
        return;
    }
    uint end = pos + 1;
    while (end < src.len) {
        if (src[end] == '\\') {
            end += 2;
            continue;
        }
        if (src[end++] == src[pos]) {
            self.out.append_bytes(src[pos:end - pos]);
            self.text(";\n");
            return;
        }
    }
    self.failed = true;
}

fn void SourceWriter.node(&self, uint n) {
    if (!n || self.failed) return;
    if (++self.depth > 512) {
        self.failed = true;
        self.depth--;
        return;
    }
    defer self.depth--;
    Ast* a      = self.ast;
    NodeTag tag = a.tags[n];
    char flags  = a.flags[n];
    uint l      = a.lhs[n];
    uint r      = a.rhs[n];
    // Operators are conservatively parenthesized. Member/call nodes remain
    // contiguous within optional chains; OPT_CHAIN marks their boundary.
    bool parens = (flags & ast::FLAG_PAREN) != 0;
    switch (tag) {
        case NUMBER:
        case OBJECT:
        case FUNC_EXPR:
        case ARROW:
        case CLASS_EXPR:
        case UNARY:
        case UPDATE_PRE:
        case UPDATE_POST:
        case BINARY:
        case LOGICAL:
        case ASSIGN:
        case COND:
        case SEQUENCE:
        case AWAIT:
        case YIELD:
        case YIELD_STAR:
        case PRIVATE_IN:
        case NEW:
        case OPT_CHAIN:
            parens = true;
        default: break;
    }
    if (parens) self.text("(");
    switch (tag) {
        case NONE: self.failed = true;
        case NUMBER:
            self.number(n);
        case BIGINT: self.atom(l); self.text("n");
        case STRING: self.quoted_atom(l);
        case REGEX: self.atom(l);
        case IDENT: self.identifier(l);
        case PRIVATE_NAME: self.text("#"); self.atom(l);
        case THIS: self.text("this");
        case NULL_LIT: self.text("null");
        case TRUE_LIT: self.text("true");
        case FALSE_LIT: self.text("false");
        case NEW_TARGET: self.text("new.target");
        case IMPORT_META: self.text("import.meta");
        case TEMPLATE:
            self.text("`");
            uint exprs = a.template_exprs(l);
            for (uint i; i <= exprs; i++) {
                self.atom(a.template_raw(l, i));
                if (i < exprs) {
                    self.text("${");
                    self.node(a.template_expr(l, i));
                    self.text("}");
                }
            }
            self.text("`");
        case TAGGED_TEMPLATE: self.node(l); self.node(r);
        case ARRAY:
        case ARRAY_PAT:
            self.text("[");
            self.list(l, holes: true);
            self.text("]");
        case OBJECT:
        case OBJECT_PAT:
            self.text("{");
            self.list(l);
            self.text("}");
        case FUNC_DECL:
        case FUNC_EXPR:
            uint f = a.field(r, ast::FN_FLAGS);
            if (f & ast::FNF_ASYNC) self.text("async ");
            self.text("function");
            if (f & ast::FNF_GENERATOR) self.text("*");
            self.text(" ");
            self.node(l);
            self.function_body(r);
        case ARROW:
            uint f = a.field(r, ast::FN_FLAGS);
            if (f & ast::FNF_ASYNC) self.text("async ");
            self.text("(");
            self.list(a.field(r, ast::FN_PARAMS));
            self.text(")=>");
            self.node(a.field(r, ast::FN_BODY));
        case CLASS_DECL:
        case CLASS_EXPR: self.class_body(l, r);
        case UNARY:
        case UPDATE_PRE:
            self.out.append_bytes(lexer::token_type_name((TokenType)(flags & 0x7F)));
            self.text(" ");
            self.node(l);
        case UPDATE_POST:
            self.node(l);
            self.out.append_bytes(lexer::token_type_name((TokenType)(flags & 0x7F)));
        case BINARY:
        case LOGICAL:
        case ASSIGN:
            self.node(l);
            self.text(" ");
            self.out.append_bytes(lexer::token_type_name((TokenType)(flags & 0x7F)));
            self.text(" ");
            self.node(r);
        case COND:
            self.node(l);
            self.text("?");
            self.node(a.extra[r]);
            self.text(":");
            self.node(a.extra[r + 1]);
        case SEQUENCE: self.list(l);
        case SPREAD:
        case REST:
        case PROP_SPREAD: self.text("..."); self.node(l);
        case AWAIT: self.text("await "); self.node(l);
        case YIELD: self.text("yield "); self.node(l);
        case YIELD_STAR: self.text("yield* "); self.node(l);
        case MEMBER:
        case PRIVATE_MEMBER:
            self.node(l);
            self.text(flags & ast::FLAG_OPTIONAL ? "?." : ".");
            if (tag == NodeTag.PRIVATE_MEMBER) self.text("#");
            self.identifier(r);
        case INDEX:
            self.node(l);
            self.text(flags & ast::FLAG_OPTIONAL ? "?.[" : "[");
            self.node(r);
            self.text("]");
        case PRIVATE_IN: self.text("#"); self.atom(l); self.text(" in "); self.node(r);
        case SUPER_MEMBER: self.text("super."); self.atom(r);
        case SUPER_INDEX: self.text("super["); self.node(r); self.text("]");
        case SUPER_CALL: self.text("super("); self.list(r); self.text(")");
        case CALL:
            self.node(l);
            self.text(flags & ast::FLAG_OPTIONAL ? "?.(" : "(");
            self.list(r);
            self.text(")");
        case NEW:
            self.text("new (");
            self.node(l);
            self.text(")(");
            self.list(r);
            self.text(")");
        case IMPORT_CALL:
            if (flags & ast::IMPORT_CALL_DEFER || flags & ast::IMPORT_CALL_SOURCE) {
                self.failed = true;
                break;
            }
            self.text("import(");
            self.node(l);
            if (r) {
                self.text(",");
                self.node(r);
            }
            self.text(")");
        case OPT_CHAIN: self.node(l);
        case PROP_INIT:
        case PAT_PROP:
            if (tag == NodeTag.PAT_PROP && flags & ast::PROP_SHORTHAND_PAT) {
                self.node(l);
                if (r) {
                    self.text("=");
                    self.node(r);
                }
            } else {
                self.key(l, flags);
                self.text(":");
                self.node(r);
            }
        case PROP_SHORTHAND:
            self.node(l);
            if (r) {
                self.text("=");
                self.node(r);
            }
        case PROP_GET: self.method(l, r, (flags & ast::PROP_COMPUTED) | ast::MEMBER_GET);
        case PROP_SET: self.method(l, r, (flags & ast::PROP_COMPUTED) | ast::MEMBER_SET);
        case PROP_METHOD: self.method(l, r, flags & ast::PROP_COMPUTED);
        case CLASS_METHOD: self.method(l, r, flags);
        case CLASS_FIELD:
            if (flags & ast::MEMBER_STATIC) self.text("static ");
            self.key(l, flags);
            if (r) {
                self.text("=");
                self.node(r);
            }
            self.text(";\n");
        case STATIC_BLOCK: self.text("static {"); self.list(l, ""); self.text("}\n");
        case ASSIGN_PAT:
        case DECLARATOR:
            self.node(l);
            if (r) {
                self.text("=");
                self.node(r);
            }
        case EXPR_STMT: self.text("("); self.node(l); self.text(");\n");
        case DIRECTIVE: self.directive(l);
        case EMPTY_STMT: self.text(";\n");
        case VAR_DECL: self.var_decl(n); self.text(";\n");
        case BLOCK: self.text("{\n"); self.list(l, ""); self.text("}\n");
        case IF:
            self.text("if(");
            self.node(l);
            self.text(")");
            self.control_body(a.extra[r]);
            if (a.extra[r + 1]) {
                self.text("else ");
                self.control_body(a.extra[r + 1]);
            }
        case FOR:
            self.text("for(");
            self.for_init(a.extra[l]);
            self.text(";");
            self.node(a.extra[l + 1]);
            self.text(";");
            self.node(a.extra[l + 2]);
            self.text(")");
            self.control_body(a.extra[l + 3]);
        case FOR_IN:
        case FOR_OF:
            self.text(flags & ast::FOR_AWAIT ? "for await(" : "for(");
            self.for_init(l);
            self.text(tag == NodeTag.FOR_IN ? " in " : " of ");
            self.node(a.extra[r]);
            self.text(")");
            self.control_body(a.extra[r + 1]);
        case WHILE:
            self.text("while(");
            self.node(l);
            self.text(")");
            self.control_body(r);
        case DO_WHILE:
            self.text("do ");
            self.control_body(l);
            self.text("while(");
            self.node(r);
            self.text(");\n");
        case RETURN: self.text("return "); self.node(l); self.text(";\n");
        case BREAK:
        case CONTINUE:
            self.text(tag == NodeTag.BREAK ? "break " : "continue ");
            if (l) self.atom(l);
            self.text(";\n");
        case THROW: self.text("throw "); self.node(l); self.text(";\n");
        case TRY:
            self.text("try ");
            self.node(l);
            if (a.extra[r + 1]) {
                self.text("catch");
                if (a.extra[r]) {
                    self.text("(");
                    self.node(a.extra[r]);
                    self.text(")");
                }
                self.node(a.extra[r + 1]);
            }
            if (a.extra[r + 2]) {
                self.text("finally ");
                self.node(a.extra[r + 2]);
            }
        case SWITCH:
            self.text("switch(");
            self.node(l);
            self.text("){\n");
            self.list(a.extra[r], "");
            self.text("}\n");
        case CASE:
            if (l) {
                self.text("case ");
                self.node(l);
            } else {
                self.text("default");
            }
            self.text(":\n");
            self.list(a.extra[r], "");
        case LABELED: self.atom(l); self.text(":"); self.node(r);
        case WITH: self.text("with("); self.node(l); self.text(")"); self.node(r);
        case DEBUGGER: self.text("debugger;\n");
        case IMPORT_DECL:
            if (flags & ast::IMPORT_PHASE_DEFER || flags & ast::IMPORT_PHASE_SOURCE) {
                self.failed = true;
                break;
            }
            uint len = a.list_len(r);
            if (!len) {
                self.text("import ");
                self.request(l);
                self.text(";\n");
            }
            for (uint i; i < len; i++) {
                uint spec = a.list_item(r, i);
                self.text("import ");
                if (a.flags[spec] & ast::IMPORT_NAMESPACE) {
                    self.text("* as ");
                } else {
                    self.text("{");
                    self.quoted_atom(a.lhs[spec]);
                    self.text(" as ");
                }
                self.node(a.rhs[spec]);
                if (!(a.flags[spec] & ast::IMPORT_NAMESPACE)) self.text("}");
                self.text(" from ");
                self.request(l);
                self.text(";\n");
            }
        case EXPORT_NAMED:
            self.text("export {");
            for (uint i; i < a.list_len(l); i++) {
                if (i) self.text(",");
                uint spec = a.list_item(l, i);
                if (r) {
                    self.quoted_atom(a.lhs[spec]);
                } else {
                    self.atom(a.lhs[spec]);
                }
                self.text(" as ");
                self.quoted_atom(a.rhs[spec]);
            }
            self.text("}");
            if (r) {
                self.text(" from ");
                self.request(r);
            }
            self.text(";\n");
        case EXPORT_SPEC: self.quoted_atom(l); self.text(" as "); self.quoted_atom(r);
        case EXPORT_ALL:
            self.text("export *");
            if (r) {
                self.text(" as ");
                self.quoted_atom(r);
            }
            self.text(" from ");
            self.request(l);
            self.text(";\n");
        case EXPORT_DECL: self.text("export "); self.node(l);
        case EXPORT_DEFAULT:
            self.text("export default ");
            self.node(l);
            self.text(";\n");
        case PROGRAM: self.list(l, "");
        default: self.failed = true;
    }
    if (parens) self.text(")");
}

fn void js_transpile(JsCtx ctx, void* udata) {
    @pool() {
        if (!ctx.arg(0).tv.is_string()) {
            ctx.throw_error(TYPE, "source must be a string");
            return;
        }
        // Own the source/options until parsing and emission finish. No JS is
        // entered while the AST borrows them.
        String source = ctx.arg(0).as_string() ?? "";
        ParseOptions opts = {
            .ts_mode = true,
            .is_module = ctx.arg(2)
            .as_bool() ?? true, .jsx = {
                .enabled = ctx.arg(1)
                .as_bool() ?? false, .runtime = (ctx.arg(6)
                    .as_bool() ?? true) ? JsxRuntime.AUTOMATIC : JsxRuntime.CLASSIC, .factory = ctx.arg(3)
                        .as_string() ?? "h", .fragment = ctx.arg(4)
                            .as_string() ?? "Fragment", .import_source = ctx.arg(5).as_string() ?? "preact", }, };
        AstIndex* index = ast::index_begin(source, g_runtime.rt.rt.heap, opts);
        defer ast::index_end(index);
        if (!index.built || !index.use) {
            ctx.throw_error(SYNTAX, (String)index.parser.err_msg[:index.parser.err_len]);
            return;
        }
        SourceWriter writer = { .ast = &index.tree };
        writer.out.init(mem);
        defer writer.out.free();
        writer.node(index.tree.node_count() - 1);
        if (writer.failed) {
            ctx.throw_error(SYNTAX, "source cannot be emitted as browser JavaScript");
            return;
        }
        // Validate the output as JavaScript too, including factories supplied
        // by JSX pragmas/options. Never return syntax the JS parser rejects.
        ParseOptions js_opts = { .is_module = opts.is_module };
        AstIndex* emitted    = ast::index_begin(writer.out.str_view(), g_runtime.rt.rt.heap, js_opts);
        defer ast::index_end(emitted);
        if (!emitted.built || !emitted.use) {
            ctx.throw_error(
                SYNTAX,
                string::tformat("cannot emit JavaScript: %s", (String)emitted.parser.err_msg[:emitted.parser.err_len])
            );
            return;
        }
        ctx.ret_string(writer.out.str_view());
    };
}

const Native[] TRANSPILE_NATIVES = { { "transpile", &js_transpile, 7 } };
