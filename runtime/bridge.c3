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


// ---- bytes ----

// The bytes behind a Uint8Array (any view) or ArrayBuffer, valid until JS
// runs again. ASCII strings are viewed in place; other strings transcode
// into tmem.
fn char[] JsArg.bytes(self) {
    TVal tv = self.tv;
    if (tv.is_string()) {
        HString* hs = (HString*)tv.get_heapptr();
        if (hs.is_ascii()) return hs.ascii_bytes();
        return (char[])(self.as_string() ?? "");
    }
    if (!tv.is_object()) return { };
    HObject* o   = (HObject*)tv.get_heapptr();
    ObjClass cls = o.get_class();
    if (cls == ARRAYBUFFER) {
        HObjectArrayBuffer* ab = &o.extra_ptr().ab;
        if (ab.byte_length == 0xFFFFFFFF || !ab.data) return { };
        return ab.data[:ab.byte_length];
    }
    if (cls != DATAVIEW && !builtins::is_typed_array_class(cls)) return { };
    uint len = builtins::view_effective_byte_length(o);
    if (!len) return { };
    HObject* buf = o.extra_ptr().view.buffer;
    return buf.extra_ptr().ab.data[o.extra_ptr().view.byte_offset:len];
}

fn bool JsArg.is_bytes(self) {
    if (!self.tv.is_object()) return false;
    ObjClass cls = ((HObject*)self.tv.get_heapptr()).get_class();
    return cls == ARRAYBUFFER || cls == DATAVIEW || builtins::is_typed_array_class(cls);
}

// A Uint8Array that takes ownership of `data`, which must come from `mem`.
fn HObject*? new_u8(char[] data) {
    Heap* h      = g_runtime.rt.rt.heap;
    HObject* buf = h.alloc_object(ARRAYBUFFER)!;
    h.set_prototype(buf, h.arraybuffer_proto);
    buf.extra_ptr().ab = { .data = data.len ? data.ptr : null, .byte_length = (uint)data.len };
    HObject* view = h.alloc_object(UINT8ARRAY)!;
    h.set_prototype(view, h.uint8array_proto);
    view.extra_ptr().view.byte_offset = 0;
    view.extra_ptr().view.byte_length = (uint)data.len;
    view.extra_ptr().view.length_tracking = false;
    builtins::typedarray_link_view(h, buf, view);
    // Ownership includes the backing store, so its bytes contribute to GC pressure.
    h.account_auxiliary_allocation(data.len);
    return view;
}

fn char[] copy_bytes(char[] src) {
    if (!src.len) return { };
    char[] out = mem::alloc_array(char, src.len);
    out[..] = src[..];
    return out;
}

fn JsArg JsCtx.bytes(self, char[] owned) {
    JsArg a;
    HObject*? o = new_u8(owned);
    if (catch o) {
        free(owned.ptr);
        a.tv.set_undefined();
        return a;
    }
    a.tv.set_object(o);
    return a;
}

fn void JsCtx.ret_bytes(self, char[] owned) => self.ret(self.bytes(owned));

fn JsValue? bytes_value(char[] owned) {
    HObject*? o = new_u8(owned);
    if (catch err = o) {
        free(owned.ptr);
        return err~;
    }
    TVal tv;
    tv.set_object(o);
    return g_runtime.rt.root(tv);
}

fn void release_string_bytes(void* user, void* data, usz length) => free(user ? user : data);

// `owned` has a trailing NUL outside its slice. Ownership passes to JS.
fn JsValue? owned_text_value(char[] owned) {
    char* base = owned.ptr;
    bool transferred;
    defer if (!transferred && base) free(base);
    if (owned.len >= 3 && owned[0] == 0xEF && owned[1] == 0xBB && owned[2] == 0xBF) owned = owned[3..];
    @pool() {
        String text = utf8_clean(owned, false) ?? "";
        $if $defined(Heap.alloc_external_string):
            if (owned.len && text.ptr == owned.ptr && hstring::check_is_ascii(owned)) {
                HString* hs = g_runtime.rt.rt.heap.alloc_external_string(hstring::narrow_units(owned), &release_string_bytes, base);
                if (hs != null) {
                    hs.finish_data();
                    transferred = true;
                    TVal tv;
                    tv.set_string_borrowed(hs);
                    return g_runtime.rt.root(tv);
                }
            }
        $endif
        return g_runtime.rt.string(text);
    };
}

// ---- settling async ops ----

// Async ops own native promise capabilities. IDs are never reused, so a late
// completion cannot settle a different operation after cancellation.
fn void js_op(JsCtx ctx, void* user) {
    if (ctx.arg(0).type_of() != FUNCTION) {
        ctx.throw_error(TYPE, "operation must be callable");
        return;
    }
    if (g_runtime.next_op == uint::max) {
        ctx.throw_error(RANGE, "async operation IDs exhausted");
        return;
    }
    JsDeferred? made = g_runtime.rt.deferred();
    if (catch made) { ctx.throw_error(ERROR, "cannot create async operation"); return; }
    JsDeferred op = made;
    uint id = ++g_runtime.next_op;
    // The operation may complete synchronously, releasing its owned roots.
    g_runtime.rt.@scope() {
        JsValue promise = g_runtime.rt.root(ctx.value(op.promise).tv) ?? { };
        if (promise.is_empty()) {
            g_runtime.rt.release_deferred(op);
            ctx.throw_error(ERROR, "cannot retain async operation");
            return;
        }
        g_runtime.pending_ops.set(id, op);
        JsArg[5] args = { ctx.number(id), ctx.arg(1), ctx.arg(2), ctx.arg(3), ctx.arg(4) };
        if (catch ctx.call(ctx.arg(0), args[..])) {
            if (try pending = g_runtime.pending_ops.get(id)) {
                g_runtime.pending_ops.remove(id);
                g_runtime.rt.release_deferred(pending);
            }
            return;
        }
        ctx.ret(ctx.value(promise));
    };
}

fn JsValue? system_error(String code, String message) {
    Heap* h = g_runtime.rt.rt.heap;
    HString* text = h.str_intern((char[])message);
    if (!text) return boomkat::OUT_OF_MEMORY~;
    TVal value;
    if (!builtins::host_new_error(h, g_runtime.rt.rt.vm, 0, text, &value)) return boomkat::OUT_OF_MEMORY~;
    JsValue error = g_runtime.rt.root(value)!;
    TVal proto;
    if (g_runtime.rt.load(g_runtime.system_error_proto, &proto)) h.set_prototype(value.get_heapptr(), proto.get_heapptr());
    g_runtime.rt.set(error, "code", g_runtime.rt.string(code)!)!;
    return error;
}

fn void settle(uint id, bool ok, JsValue value = { }, String code = "") {
    if (g_runtime.closing || worker_stopping()) return;
    JsDeferred? found = g_runtime.pending_ops.get(id);
    if (catch found) return;
    JsDeferred op = found;
    g_runtime.pending_ops.remove(id);
    defer g_runtime.rt.release_deferred(op);
    g_runtime.depth++;
    defer g_runtime.depth--;
    bool started = begin_dispatch();
    defer end_dispatch(started);
    g_runtime.rt.@scope() {
        if (!ok) {
            String message = g_runtime.rt.as_string(value) ?? "";
            JsValue? error = system_error(code, message);
            if (catch err = error) { (void)dispatch_error(err); return; }
            value = error;
        }
        if (catch err = g_runtime.rt.settle_deferred(op, ok, value)) {
            (void)dispatch_error(err);
            return;
        }
        if (g_runtime.depth == 1) {
            if (catch err = checkpoint()) { (void)dispatch_error(err); return; }
            if (g_runtime.rejections.len()) flush_rejections();
        }
    };
}

fn void resolve(uint id, JsValue value = { }) => settle(id, true, value);
fn void resolve_number(uint id, double n) {
    g_runtime.rt.@scope() {
        settle(id, true, g_runtime.rt.number(n) ?? { });
    };
}
fn void resolve_string(uint id, String s) {
    g_runtime.rt.@scope() {
        settle(id, true, g_runtime.rt.string(s) ?? { });
    };
}
fn void resolve_bytes(uint id, char[] owned) {
    g_runtime.rt.@scope() {
        settle(id, true, bytes_value(owned) ?? { });
    };
}
fn void reject(uint id, String code, String msg) {
    g_runtime.rt.@scope() {
        settle(id, false, g_runtime.rt.string(msg) ?? { }, code);
    };
}
fn void reject_errno(
    uint id,
    CInt err,
    String what
) => reject(id, errno_code(err), string::tformat("%s: %s", what, errno_text(err)));

fn void JsCtx.throw_coded(self, String code, String msg) {
    JsArg? make = self.get_prop(self.value(g_runtime.bk), "error");
    if (try make) {
        JsArg[2] args = { self.string(code), self.string(msg) };
        if (try e = self.call(make, args[..])) {
            self.throw_value(e);
            return;
        }
    }
    self.throw_error(ERROR, msg);
}

// ---- errors ----


// An exception escaped into the loop. Like Deno, that ends the process.
// Calls `f` like call_js, but a JS throw comes back as the thrown value in
// `thrown` instead of ending the process. Rejections are left for the
// caller to flush once it has handled the result.
fn JsValue? call_catch(JsValue f, JsValue[] args, JsValue* thrown) {
    if (g_runtime.closing || worker_stopping()) return WORKER_STOPPED~;
    g_runtime.depth++;
    defer g_runtime.depth--;
    bool started = begin_dispatch();
    defer end_dispatch(started);
    JsValue? result = g_runtime.rt.call(f, args);
    if (catch err = result) {
        if (err == boomkat::INTERRUPTED) {
            g_runtime.engine.clear_interrupt();
            if (worker_stopping()) { worker_stop(); return WORKER_STOPPED~; }
            io::eprintfn("error: script ran past the %d ms time limit", g_runtime.time_limit_ns / 1_000_000);
            return TIMED_OUT~;
        }
        *thrown = g_runtime.rt.get_exception()!;
        return err~;
    }
    return result;
}

// The uncaught exception's stack when it has one, else the engine's message,
// which also covers syntax errors and other failures before code runs.
fn String uncaught_text() {
    String message = g_runtime.rt.last_error().tcopy();
    if (g_runtime.describe.is_empty()) return message;
    g_runtime.rt.@scope() {
        JsValue? thrown = g_runtime.rt.get_exception();
        if (catch thrown) return message;
        TVal tv;
        if (!g_runtime.rt.load(thrown, &tv) || !tv.is_object()) return message;
        JsValue[1] a = { thrown };
        String? stack = g_runtime.rt.as_string(g_runtime.rt.call(g_runtime.describe, a[..]) ?? { });
        if (try stack && stack.contains("\n    at ")) return stack.tcopy();
    };
    return message;
}

fn void report_uncaught() {
    io::eprintfn("error: %s", uncaught_text());
    g_runtime.exit_code = 1;
    exit_now();
}

// ---- the native table ----


struct Native {
    String name;
    JsHostFn f;
    int argc;
}

fn void? install_natives(Native[] natives) {
    if (g_runtime.bk.is_empty()) {
        g_runtime.bk = g_runtime.rt.object()!;
        JsValue global = g_runtime.rt.global()!;
        defer g_runtime.rt.release(global);
        g_runtime.rt.set(global, "__bk", g_runtime.bk)!;
    }
    foreach (n : natives) g_runtime.rt.register_method(g_runtime.bk, n.name, n.f, null, n.argc)!;
}

fn uint JsArg.id(self) => (uint)(self.as_number() ?? 0);
fn int JsArg.as_int(self, int fallback = 0) => (int)(self.as_number() ?? fallback);
