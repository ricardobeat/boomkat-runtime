module bkr;

import boomkat;
import boomkat::builtins;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;

struct NativeWebClass {
    HObject* prototype;
    JsValue initialize;
    JsValue getter;
    TVal dependency;
    TVal url_fast;
    TVal slice;
    TVal stream_ctor;
    TVal file_ctor;
    HString* k_raw;
    HString* k_flags;
    HString* k_string;
    HString* k_url_fast;
    HString* k_slice;
    HString* k_body;
    HString* k_ct;
    HString* k_u8;
    HString* k_file;
    JsValue[5] keys;
    JsValue[4] keep;
}

NativeWebClass g_native_url;
NativeWebClass g_native_response;

// Raw reads are safe only for ordinary data properties. Accessors and proxies
// must run through JS so their effects occur in the same order.
fn bool web_own_data(HObject* obj, HString* key, Heap* h, TVal* value) {
    if (!obj || obj.flags.exotic_proxyobj) return false;
    int slot = obj.find_prop_idx(key, h);
    if (slot < 0 || obj.get_prop_flags((uint)slot, h).is_accessor) return false;
    *value = obj.prop_values()[slot].get();
    return true;
}

fn bool web_can_assign(HObject* obj, HString* key, Heap* h) {
    for (uint depth = 0; obj && depth < 32; depth++, obj = obj.prototype) {
        if (obj.flags.exotic_proxyobj) return false;
        int slot = obj.find_prop_idx(key, h);
        if (slot < 0) continue;
        PropFlags flags = obj.get_prop_flags((uint)slot, h);
        return !flags.is_accessor && flags.writable;
    }
    return obj == null;
}

fn void web_initialize(JsCtx ctx, NativeWebClass* cls) {
    JsArg[2] args = { ctx.arg(0), ctx.arg(1) };
    if (catch ctx.call(ctx.value(cls.initialize), args[..], ctx.this_value())) return;
    ctx.ret(ctx.this_value());
}

fn void native_url_construct(BuiltinContext* raw, void* user) {
    JsCtx ctx           = { .ctx = raw };
    NativeWebClass* cls = (NativeWebClass*)user;
    if (!ctx.is_construct()) return ctx.throw_error(JsErrorKind.TYPE, "URL requires new");
    Heap* h      = raw.heap;
    TVal input   = ctx.arg(0).tv;
    HObject* obj = ctx.this_value().tv.get_heapptr();
    TVal string_ctor, url_fast;
    if (!input.is_string() || obj.prototype != cls.prototype || !web_own_data(
        raw.global_env.bindings,
        cls.k_string,
        h,
        &string_ctor
    ) || string_ctor.get_raw_bits() != cls.dependency.get_raw_bits() || !web_own_data(ctx.value(g_bk)
        .tv.get_heapptr(), cls.k_url_fast, h, &url_fast) || url_fast.get_raw_bits()
            != cls.url_fast.get_raw_bits() || !web_can_assign(
            obj,
            cls.k_raw,
            h
        ) || !web_can_assign(obj, cls.k_flags, h)) {
        return web_initialize(ctx, cls);
    }
    HString* str = input.get_heapptr();
    long flags   = str.is_ascii() ? url_fast_flags((String)str.get_data()) : -1;
    if (flags < 0) return web_initialize(ctx, cls);
    TVal parts;
    parts.set_number((double)flags);
    if (!obj.put_prop(
        cls.k_raw,
        input,
        hobject::PROP_FLAGS_WEC,
        h
    ) || !obj.put_prop(cls.k_flags, parts, hobject::PROP_FLAGS_WEC, h)) {
        return ctx.throw_error(JsErrorKind.ERROR, "URL allocation failed");
    }
    ctx.ret(ctx.this_value());
}

fn void native_url_pathname(BuiltinContext* raw, void* user) {
    JsCtx ctx           = { .ctx = raw };
    NativeWebClass* cls = (NativeWebClass*)user;
    TVal receiver       = ctx.this_value().tv;
    TVal input, parts;
    if (receiver.is_object()) {
        HObject* obj = receiver.get_heapptr();
        if (web_own_data(
            obj,
            cls.k_raw,
            raw.heap,
            &input
        ) && input.is_string() && web_own_data(obj, cls.k_flags, raw.heap, &parts) && parts.is_numeric()) {
            HString* str  = input.get_heapptr();
            double number = parts.is_fastint() ? (double)parts.get_fastint() : parts.get_number();
            // User writes to these public fields can make JS slice coercion
            // observable. Native slicing accepts only the parser's encoding.
            if (str.is_ascii() && number >= 0 && number <= 9007199254740991.0) {
                ulong flags = (ulong)number;
                usz slash   = flags & 0xFFFF;
                usz query   = (flags >> 16) & 0xFFFF;
                String text = (String)str.get_data();
                if ((double)flags == number && slash <= text.len
                    && (query == 0xFFFF || (query >= slash && query <= text.len))) {
                    if (slash == text.len) return ctx.ret_string("/");
                    TVal slice;
                    if (web_own_data(
                        raw.heap.string_proto,
                        cls.k_slice,
                        raw.heap,
                        &slice
                    ) && slice.get_raw_bits() == cls.slice.get_raw_bits()) {
                        usz end = query == 0xFFFF ? text.len : query;
                        return ctx.ret_string(text[slash:end - slash]);
                    }
                }
            }
        }
    }
    if (try result = ctx.call(ctx.value(cls.getter), { }, ctx.this_value())) ctx.ret(result);
}

// OrdinaryHasInstance is pure for an ordinary constructor with the intrinsic
// hasInstance method. Other methods, accessors and proxies use the JS path.
fn bool web_instanceof(Heap* h, TVal value, TVal ctor, bool* result) {
    *result = false;
    if (!ctor.is_object()) return false;
    HObject* fn_obj = ctor.get_heapptr();
    if (!fn_obj.is_callable() || fn_obj.flags.exotic_proxyobj
        || fn_obj.callable_kind() == hobject::CallableKind.BOUND_FN) return false;
    HObject* owner    = fn_obj;
    bool found_method = false;
    for (uint depth = 0; owner && depth < 32; depth++, owner = owner.prototype) {
        if (owner.flags.exotic_proxyobj) return false;
        int slot = owner.find_prop_idx(h.hasinstance_symbol, h);
        if (slot < 0) continue;
        if (owner.get_prop_flags((uint)slot, h).is_accessor) return false;
        found_method = true;
        TVal method = owner.prop_values()[slot].get();
        if (!method.is_null() && !method.is_undefined()) {
            uint index;
            if (method.is_lightfunc()) {
                index = (uint)(usz)method.get_heapptr();
            } else if (method.is_object()) {
                HObject* m = method.get_heapptr();
                if (m.flags.exotic_proxyobj || m.callable_kind() != hobject::CallableKind.BUILTIN_FN) return false;
                index = (uint)m.extra_ptr().func.builtin_fn_index;
            } else {
                return false;
            }
            if (index != builtins::Builtin.FUNCTION_PROTO_HASINSTANCE.ordinal) return false;
        }
        break;
    }
    if (owner && !found_method) return false;
    if (!value.is_object()) return !value.is_lightfunc();
    TVal prototype;
    if (!web_own_data(fn_obj, h.str(PROTOTYPE), h, &prototype) || !prototype.is_object()) return false;
    HObject* obj = value.get_heapptr();
    for (uint depth = 0; obj && depth < 32; depth++, obj = obj.prototype) {
        if (obj.flags.exotic_proxyobj) return false;
        // The instance itself is excluded from OrdinaryHasInstance's walk.
        if (obj.prototype == prototype.get_heapptr()) {
            *result = true;
            return true;
        }
    }
    return obj == null;
}

fn void native_response_construct(BuiltinContext* raw, void* user) {
    JsCtx ctx           = { .ctx = raw };
    NativeWebClass* cls = (NativeWebClass*)user;
    if (!ctx.is_construct()) return ctx.throw_error(JsErrorKind.TYPE, "Response requires new");
    Heap* h      = raw.heap;
    HObject* obj = ctx.this_value().tv.get_heapptr();
    TVal body    = ctx.arg(0).tv;
    TVal init    = ctx.arg(1).tv;
    if (obj.prototype != cls.prototype || (!init.is_undefined() && !init.is_null())) {
        return web_initialize(ctx, cls);
    }
    bool native_body = false;
    if (init.is_undefined()) {
        TVal u8, file;
        if (!web_own_data(
            raw.global_env.bindings,
            cls.k_u8,
            h,
            &u8
        ) || u8.get_raw_bits() != cls.dependency.get_raw_bits() || !web_own_data(ctx.value(g_bk)
            .tv.get_heapptr(), cls.k_file, h, &file) || file.get_raw_bits()
                != cls.file_ctor.get_raw_bits()) return web_initialize(
                ctx,
                cls
            );
        bool match;
        if (!web_instanceof(h, body, u8, &match)) return web_initialize(ctx, cls);
        native_body = match;
        if (!native_body) {
            if (!web_instanceof(h, body, cls.stream_ctor, &match)) return web_initialize(ctx, cls);
            native_body = match;
        }
        if (!native_body) {
            if (!web_instanceof(h, body, file, &match)) return web_initialize(ctx, cls);
            native_body = match;
        }
    }
    bool string_body = body.is_string() && init.is_undefined();
    bool empty_body  = body.is_undefined() || body.is_null();
    if ((!native_body && !string_body && !empty_body) || ((native_body || string_body) && !web_can_assign(
        obj,
        cls.k_body,
        h
    )) || (!string_body && !web_can_assign(obj, cls.k_ct, h))) return web_initialize(ctx, cls);
    if (!string_body) {
        TVal null_value;
        null_value.set_null();
        if (!obj.put_prop(cls.k_ct, null_value, hobject::PROP_FLAGS_WEC, h)) {
            return ctx.throw_error(JsErrorKind.ERROR, "Response allocation failed");
        }
    }
    if ((native_body || string_body) && !obj.put_prop(cls.k_body, body, hobject::PROP_FLAGS_WEC, h)) {
        return ctx.throw_error(JsErrorKind.ERROR, "Response allocation failed");
    }
    ctx.ret(ctx.this_value());
}

fn HObject*? web_host_function(
    Heap* h,
    String name,
    builtins::HostFunc handler,
    NativeWebClass* cls,
    int arity,
    bool constructable
) {
    HString* key = h.str_intern((char[])name);
    if (!key) return heap::HEAP_ALLOC_FAULT~;
    long slot = h.register_host_fn((void*)handler, cls, key, arity, constructable);
    if (slot < 0) return heap::HEAP_ALLOC_FAULT~;
    return builtins::make_host_function(h, (uint)slot);
}

fn HString* web_key(JsCtx ctx, NativeWebClass* cls, uint index, String text) {
    JsArg key = ctx.string(text);
    if (!key.tv.is_string()) return null;
    cls.keys[index] = ctx.persist(key) ?? { };
    if (cls.keys[index].is_empty()) return null;
    return key.tv.get_heapptr();
}

fn void js_native_class(JsCtx ctx, void* user) {
    Heap* h = ctx.ctx.heap;
    if (!ctx.arg(0).tv.is_object() || !ctx.arg(1).tv.is_object() || !ctx.arg(2).tv.is_string()) {
        return ctx.throw_error(JsErrorKind.TYPE, "Invalid native class");
    }
    String name = (String)ctx.arg(2).bytes();
    if (name != "URL" && name != "Response") return ctx.throw_error(JsErrorKind.TYPE, "Invalid native class");
    bool is_url         = name == "URL";
    NativeWebClass* cls = is_url ? &g_native_url : &g_native_response;
    HObject* original   = ctx.arg(0).tv.get_heapptr();
    HObject* initialize = ctx.arg(1).tv.get_heapptr();
    if (cls.prototype || original.flags.exotic_proxyobj || !original.is_callable() || initialize.flags.exotic_proxyobj
        || !initialize.is_callable()) {
        return ctx.throw_error(JsErrorKind.TYPE, "Invalid native class");
    }
    TVal proto;
    if (!web_own_data(original, h.str(PROTOTYPE), h, &proto) || !proto.is_object()) {
        return ctx.throw_error(JsErrorKind.TYPE, "Invalid native class");
    }
    cls.prototype = proto.get_heapptr();
    cls.initialize = ctx.persist(ctx.arg(1)) ?? { };
    cls.dependency = ctx.arg(3).tv;
    cls.keep[0] = ctx.persist(ctx.arg(0)) ?? { };
    cls.keep[1] = ctx.persist(ctx.arg(3)) ?? { };
    if (cls.initialize.is_empty() || cls.keep[0].is_empty() || cls.keep[1].is_empty()) {
        return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
    }
    if (!is_url) {
        cls.stream_ctor = ctx.arg(4).tv;
        cls.file_ctor = ctx.arg(5).tv;
        cls.keep[2] = ctx.persist(ctx.arg(4)) ?? { };
        cls.keep[3] = ctx.persist(ctx.arg(5)) ?? { };
        if (cls.keep[2].is_empty() || cls.keep[3].is_empty()) {
            return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
        }
        cls.k_body = web_key(ctx, cls, 0, "_body");
        cls.k_ct = web_key(ctx, cls, 1, "_ct");
        cls.k_u8 = web_key(ctx, cls, 2, "Uint8Array");
        cls.k_file = web_key(ctx, cls, 3, "FileBody");
        if (!cls.k_body || !cls.k_ct || !cls.k_u8 || !cls.k_file) {
            return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
        }
        HObject*? made = web_host_function(h, "Response", &native_response_construct, cls, 2, true);
        if (catch made) return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
        HObject* ctor = made;
        ctor.put_prop(h.str(PROTOTYPE), proto, hobject::PROP_FLAGS_NNC, h);
        JsArg result;
        result.tv.set_object(ctor);
        return ctx.ret(result);
    }
    cls.k_raw = web_key(ctx, cls, 0, "_raw");
    cls.k_flags = web_key(ctx, cls, 1, "_f");
    cls.k_string = web_key(ctx, cls, 2, "String");
    cls.k_url_fast = web_key(ctx, cls, 3, "urlFast");
    cls.k_slice = web_key(ctx, cls, 4, "slice");
    if (!cls.k_raw || !cls.k_flags || !cls.k_string || !cls.k_url_fast || !cls.k_slice) {
        return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
    }
    (void)web_own_data(ctx.value(g_bk).tv.get_heapptr(), cls.k_url_fast, h, &cls.url_fast);
    (void)web_own_data(h.string_proto, cls.k_slice, h, &cls.slice);
    cls.keep[2] = ctx.persist((JsArg) { .tv = cls.url_fast }) ?? { };
    cls.keep[3] = ctx.persist((JsArg) { .tv = cls.slice }) ?? { };
    if (cls.keep[2].is_empty() || cls.keep[3].is_empty()) {
        return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
    }
    HObject*? made = web_host_function(h, "URL", &native_url_construct, cls, 2, true);
    if (catch made) return ctx.throw_error(JsErrorKind.ERROR, "Native class allocation failed");
    HObject* ctor = made;
    ctor.put_prop(h.str(PROTOTYPE), proto, hobject::PROP_FLAGS_NNC, h);
    HString* path = h.str_intern("pathname");
    int slot      = cls.prototype.find_prop_idx(path, h);
    if (slot < 0 || !cls.prototype.get_prop_flags((uint)slot, h).is_accessor) {
        return ctx.throw_error(JsErrorKind.TYPE, "Invalid URL getter");
    }
    TVal pair = cls.prototype.prop_values()[slot].get();
    cls.getter = g_rt.root(hobject::hobject_access_getter(pair)) ?? { };
    if (cls.getter.is_empty()) return ctx.throw_error(JsErrorKind.ERROR, "Native getter allocation failed");
    HObject*? getter = web_host_function(h, "get pathname", &native_url_pathname, cls, 0, false);
    if (catch getter) return ctx.throw_error(JsErrorKind.ERROR, "Native getter allocation failed");
    TVal fn_value;
    fn_value.set_object(getter);
    TVal accessors = hobject::hobject_create_accessors(h, fn_value, hobject::hobject_access_setter(pair));
    cls.prototype.put_prop(path, accessors, cls.prototype.get_prop_flags((uint)slot, h), h);
    JsArg result;
    result.tv.set_object(ctor);
    ctx.ret(result);
}

const Native[] WEB_NATIVES = { { "nativeClass", &js_native_class, 6 } };