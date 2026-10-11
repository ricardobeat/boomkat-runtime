// What crosses between C3 and JS: bytes, async op results, and the native
// table JS sees as `__bk`.
module bkr;

import boomkat;
import boomkat::builtins;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import std::io;

JsRuntime g_rt;
JsValue g_settle;

// ---- bytes ----

// The bytes behind a Uint8Array (any view) or ArrayBuffer, valid until JS
// runs again. ASCII strings are viewed in place; other strings transcode
// into tmem.
fn char[] JsArg.bytes(self)
{
    TVal tv = self.tv;
    if (tv.is_string())
    {
        HString* hs = (HString*)tv.get_heapptr();
        if (hs.is_ascii()) return hs.get_data();
        return (char[])(self.as_string() ?? "");
    }
    if (!tv.is_object()) return {};
    HObject* o = (HObject*)tv.get_heapptr();
    ObjClass cls = o.get_class();
    if (cls == ARRAYBUFFER)
    {
        HObjectArrayBuffer* ab = &o.extra_ptr().ab;
        if (ab.byte_length == 0xFFFFFFFF || !ab.data) return {};
        return ab.data[:ab.byte_length];
    }
    if (cls != DATAVIEW && !builtins::is_typed_array_class(cls)) return {};
    uint len = builtins::view_effective_byte_length(o);
    if (!len) return {};
    HObject* buf = o.extra_ptr().view.buffer;
    return buf.extra_ptr().ab.data[o.extra_ptr().view.byte_offset:len];
}

fn bool JsArg.is_bytes(self)
{
    if (!self.tv.is_object()) return false;
    ObjClass cls = ((HObject*)self.tv.get_heapptr()).get_class();
    return cls == ARRAYBUFFER || cls == DATAVIEW || builtins::is_typed_array_class(cls);
}

// A Uint8Array that takes ownership of `data`, which must come from `mem`.
fn HObject*? new_u8(char[] data)
{
    Heap* h = g_rt.rt.heap;
    HObject* buf = h.alloc_object(ARRAYBUFFER)!;
    h.set_prototype(buf, h.arraybuffer_proto);
    buf.extra_ptr().ab = { .data = data.len ? data.ptr : null, .byte_length = (uint)data.len };
    HObject* view = h.alloc_object(UINT8ARRAY)!;
    h.set_prototype(view, h.uint8array_proto);
    view.extra_ptr().view.byte_offset = 0;
    view.extra_ptr().view.byte_length = (uint)data.len;
    view.extra_ptr().view.length_tracking = false;
    builtins::typedarray_link_view(h, buf, view);
    return view;
}

fn char[] copy_bytes(char[] src)
{
    if (!src.len) return {};
    char[] out = mem::alloc_array(char, src.len);
    out[..] = src[..];
    return out;
}

fn JsArg JsCtx.bytes(self, char[] owned)
{
    JsArg a;
    HObject*? o = new_u8(owned);
    if (catch o)
    {
        free(owned.ptr);
        a.tv.set_undefined();
        return a;
    }
    a.tv.set_object(o);
    return a;
}

fn void JsCtx.ret_bytes(self, char[] owned) => self.ret(self.bytes(owned));

fn JsValue? bytes_value(char[] owned)
{
    HObject*? o = new_u8(owned);
    if (catch err = o)
    {
        free(owned.ptr);
        return err~;
    }
    TVal tv;
    tv.set_object(o);
    return g_rt.root(tv);
}

// ---- settling async ops ----

// JS starts an op by passing a fresh id to a native; the native finishes it,
// now or from a later loop callback, through one of these. On the JS side
// __settle(id, ok, value, code) resolves or rejects the op's promise.
fn void settle(uint id, bool ok, JsValue value = {}, String code = "")
{
    g_rt.@scope()
    {
        JsValue[4] args = {
            g_rt.number(id) ?? {},
            g_rt.boolean(ok) ?? {},
            value,
            code.len ? g_rt.string(code) ?? {} : (JsValue){},
        };
        JsValue? r = g_rt.call(g_settle, args[..]);
        if (catch r) report_uncaught();
    };
}

fn void resolve(uint id, JsValue value = {}) => settle(id, true, value);
fn void resolve_number(uint id, double n) => settle(id, true, g_rt.number(n) ?? {});
fn void resolve_string(uint id, String s) => settle(id, true, g_rt.string(s) ?? {});
fn void resolve_bytes(uint id, char[] owned) => settle(id, true, bytes_value(owned) ?? {});
fn void reject(uint id, String code, String msg) => settle(id, false, g_rt.string(msg) ?? {}, code);
fn void reject_errno(uint id, CInt err, String what) => reject(id, errno_code(err), string::tformat("%s: %s", what, errno_text(err)));

fn void JsCtx.throw_coded(self, String code, String msg)
{
    JsArg? make = self.get_prop(self.value(g_bk), "error");
    if (try make)
    {
        JsArg[2] args = { self.string(code), self.string(msg) };
        if (try e = self.call(make, args[..])) { self.throw_value(e); return; }
    }
    self.throw_error(ERROR, msg);
}

// ---- errors ----

int g_exit_code;

// An exception escaped into the loop. Like Deno, that ends the process.
fn void report_uncaught()
{
    io::eprintfn("error: %s", g_rt.last_error());
    g_exit_code = 1;
    exit_now();
}

// ---- the native table ----

JsValue g_bk;

struct Native
{
    String name;
    JsHostFn f;
    int argc;
}

fn void? install_natives(Native[] natives)
{
    if (g_bk.is_empty())
    {
        g_bk = g_rt.object()!;
        JsValue global = g_rt.global()!;
        defer g_rt.release(global);
        g_rt.set(global, "__bk", g_bk)!;
    }
    foreach (n : natives) g_rt.register_method(g_bk, n.name, n.f, null, n.argc)!;
}

fn uint JsArg.id(self) => (uint)(self.as_number() ?? 0);
fn int JsArg.as_int(self, int fallback = 0) => (int)(self.as_number() ?? fallback);
