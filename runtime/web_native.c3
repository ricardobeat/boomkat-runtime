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
    ShapePath[3] shapes;
    WebSlot[3] slots;
    WebChain[2] chains;
    WebGet[2] gets;
}


// Raw reads are safe only for ordinary data properties. Accessors and proxies
// must run through JS so their effects occur in the same order.
fn bool web_own_data(HObject* obj, HString* key, Heap* h, TVal* value) {
    if (!obj || obj.flags.exotic_proxyobj) return false;
    int slot = obj.find_prop_idx(key, h);
    if (slot < 0 || obj.get_prop_flags((uint)slot, h).is_accessor) return false;
    *value = obj.prop_values()[slot].get();
    return true;
}

// The shapes a fresh object passes through when the runtime gives it the same
// keys in the same order, as it does for every Request, URL and Response. Once
// each step is a transition another object already took, the path is in the
// heap's transition table, where a shape stays valid while
// shape_recycle_epoch does. A later object starting on the same shape then
// takes all the values at once and moves straight to the last shape, as a
// cached store (HObject.append_cached_prop) moves one key.
struct ShapePath {
    uint epoch;
    uint start;
    uint end;
    bool ready;
}

// Put `vals` under `keys` with default flags on `obj`, which has none of the
// keys. False when the object could not take a key.
fn bool shape_path_put(ShapePath* path, HObject* obj, HString*[] keys, TVal[] vals, Heap* h) {
    uint n = (uint)keys.len;
    if (path.ready && obj.shape_id == path.start && path.epoch == h.shape_recycle_epoch
        && obj.prop_count == 0 && obj.prop_capacity >= n && obj.prop_hash == null
        && !obj.gc.prototype_observed && !obj.flags.exotic_array) {
        hobject::PropValue* slots = obj.prop_values();
        for (uint i = 0; i < n; i++) {
            mem::clear(&slots[i], (sz)hobject::PropValue::size);
            h.store_slot(obj, &slots[i], vals[i]);
            vals[i].incref_if_heap();
        }
        obj.prop_count = n;
        obj.shape_id = path.end;
        return true;
    }
    uint start = obj.shape_id;
    bool shared = obj.prop_count == 0;
    for (uint i = 0; i < n; i++) {
        uint next = h.lookup_transition(obj.shape_id, keys[i], (char)hobject::PROP_FLAGS_WEC);
        if (!obj.put_prop(keys[i], vals[i], hobject::PROP_FLAGS_WEC, h)) return false;
        if (next == heap::SHAPE_NONE || obj.shape_id != next) shared = false;
    }
    if (shared) {
        path.start = start;
        path.end = obj.shape_id;
        path.epoch = h.shape_recycle_epoch;
        path.ready = true;
    }
    return true;
}

// ---- guard caches ----
//
// The per-request guards ask the same questions of the same long-lived objects
// on every request: whether a prototype has gained a setter, whether a global
// constructor or String.prototype.slice is still the original. Each cache
// below keeps an answer while Heap.prototype_epoch holds. The long-lived
// objects it read are marked observed (HObject.observe_prototype), and adding,
// removing or re-flagging a property of an observed object, or changing its
// prototype, advances the epoch, as the engine's own read caches rely on. A
// value can change without advancing it, so a cache keeps the slot and reads
// the value again. Per-request objects are never observed, since freeing an
// observed object advances the epoch too; their layout is matched by shape.

// A property's slot in one long-lived object.
struct WebSlot {
    ulong epoch;
    HObject* obj;
    int slot;
    bool accessor;
    bool ok;
}

fn int web_slot(WebSlot* c, HObject* obj, HString* key, Heap* h, bool* accessor) {
    if (c.ok && c.obj == obj && c.epoch == h.prototype_epoch) {
        *accessor = c.accessor;
        return c.slot;
    }
    int slot  = obj.find_prop_idx(key, h);
    *accessor = slot >= 0 && obj.get_prop_flags((uint)slot, h).is_accessor;
    if (obj.flags.exotic_proxyobj) return slot;
    obj.observe_prototype();
    *c = { .epoch = h.prototype_epoch, .obj = obj, .slot = slot, .accessor = *accessor, .ok = true };
    return slot;
}

// web_own_data of a long-lived object.
fn bool web_own_data_at(WebSlot* c, HObject* obj, HString* key, Heap* h, TVal* value) {
    if (!obj || obj.flags.exotic_proxyobj) return false;
    bool accessor;
    int slot = web_slot(c, obj, key, h, &accessor);
    if (slot < 0 || accessor) return false;
    *value = obj.prop_values()[slot].get();
    return true;
}

// Mark the prototype chain from `first` observed. False, having marked nothing,
// when a proxy or a chain longer than the guards walk can change an answer
// without advancing the epoch.
fn bool web_observe_chain(HObject* first) {
    uint depth;
    for (HObject* p = first; p; p = p.prototype) {
        if (p.flags.exotic_proxyobj || ++depth > 32) return false;
    }
    for (HObject* p = first; p; p = p.prototype) p.observe_prototype();
    return true;
}

// web_can_assign's walk of a prototype chain, by its first link.
struct WebChain {
    ulong epoch;
    HObject* first;
    bool result;
    bool ok;
}

// web_can_assign for a receiver that has no own properties, as a constructor's
// fresh `this` has: the answer is its prototype chain's.
fn bool web_can_assign_at(WebChain* c, HObject* obj, HString* key, Heap* h) {
    if (!hobject::plain_property_object(obj) || obj.prop_count != 0) return web_can_assign(obj, key, h);
    HObject* first = obj.prototype;
    if (c.ok && c.first == first && c.epoch == h.prototype_epoch) return c.result;
    bool result = web_can_assign(first, key, h);
    if (web_observe_chain(first)) *c = { .epoch = h.prototype_epoch, .first = first, .result = result, .ok = true };
    return result;
}

// Where a key of a per-request receiver lives, by the receiver's shape: in the
// receiver itself, valid while its shape id names the same shape
// (shape_recycle_epoch), or on its prototype chain, which is observed. A
// dictionary or private receiver shape is never recorded: keys join a
// dictionary shape in place, and a private shape's flags change in place.
struct WebGet {
    ulong epoch;
    uint recycle;
    uint shape;
    HObject* first;
    HObject* owner;
    int slot;
    bool accessor;
    bool ok;
}

// The slot of `key` as get_prop_proto finds it, and its owner; -1 when no
// object on the chain has it. -2 when the receiver or its chain is not one the
// cache can describe; the caller then asks get_prop_proto.
fn int web_find_at(WebGet* c, HObject* o, HString* key, Heap* h, HObject** owner, bool* accessor) {
    if (c.ok && o.shape_id == c.shape && c.recycle == h.shape_recycle_epoch
        && (c.owner == null || (o.prototype == c.first && c.epoch == h.prototype_epoch))) {
        *owner = c.owner ? c.owner : o;
        *accessor = c.accessor;
        return c.slot;
    }
    if (!hobject::plain_property_object(o)) return -2;
    // Only a transition table shape: a private one can change its flags in place.
    hobject::Shape* sh = h.get_shape(o.shape_id);
    if (sh == null || sh.dict || (o.shape_id != 0 && sh.parent == hobject::PRIVATE_SHAPE_PARENT)) return -2;
    int slot = o.find_prop_idx(key, h);
    HObject* found = o;
    if (slot < 0) {
        found = null;
        uint depth;
        for (HObject* p = o.prototype; p; p = p.prototype) {
            if (!hobject::plain_property_object(p) || ++depth > 32) return -2;
            slot = p.find_prop_idx(key, h);
            if (slot >= 0) {
                found = p;
                break;
            }
        }
        if (!web_observe_chain(o.prototype)) return -2;
    }
    *owner = found;
    *accessor = slot >= 0 && found.get_prop_flags((uint)slot, h).is_accessor;
    *c = { .epoch = h.prototype_epoch, .recycle = h.shape_recycle_epoch, .shape = o.shape_id,
           .first = o.prototype, .owner = found == o ? null : found, .slot = slot,
           .accessor = *accessor, .ok = true };
    // An absent key is recorded as found on the chain, so the epoch check guards it.
    if (slot < 0) c.owner = o.prototype ? o.prototype : o;
    return slot;
}

// fast_get through a cache: the raw value get_prop_proto returns, undefined
// when absent.
fn TVal web_get_at(WebGet* c, HObject* o, HString* key, Heap* h) {
    HObject* owner;
    bool accessor;
    int slot = web_find_at(c, o, key, h, &owner, &accessor);
    if (slot == -2) return o.get_prop_proto(key, h) ?? (TVal) { };
    if (slot < 0) return (TVal) { };
    return owner.prop_values()[slot].get();
}

// web_own_data of a per-request receiver.
fn bool web_own_data_get(WebGet* c, HObject* o, HString* key, Heap* h, TVal* value) {
    HObject* owner;
    bool accessor;
    int slot = web_find_at(c, o, key, h, &owner, &accessor);
    if (slot == -2) return web_own_data(o, key, h, value);
    if (slot < 0 || owner != o || accessor) return false;
    *value = o.prop_values()[slot].get();
    return true;
}

// web_method_is of a per-request receiver.
fn bool web_method_is_at(WebGet* c, HObject* o, HString* key, TVal expected, Heap* h) {
    HObject* owner;
    bool accessor;
    int slot = web_find_at(c, o, key, h, &owner, &accessor);
    if (slot == -2) return web_method_is(o, key, expected, h);
    if (slot < 0 || accessor) return false;
    return owner.prop_values()[slot].get().get_raw_bits() == expected.get_raw_bits();
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
    if (!input.is_string() || obj.prototype != cls.prototype
        || !web_own_data_at(&cls.slots[0], raw.global_env.bindings, cls.k_string, h, &string_ctor)
        || string_ctor.get_raw_bits() != cls.dependency.get_raw_bits()
        || !web_own_data_at(&cls.slots[1], ctx.value(g_runtime.bk).tv.get_heapptr(), cls.k_url_fast, h, &url_fast)
        || url_fast.get_raw_bits() != cls.url_fast.get_raw_bits()
        || !web_can_assign_at(&cls.chains[0], obj, cls.k_raw, h)
        || !web_can_assign_at(&cls.chains[1], obj, cls.k_flags, h)) {
        return web_initialize(ctx, cls);
    }
    HString* str = input.get_heapptr();
    long flags   = str.is_ascii() ? url_fast_flags((String)str.ascii_bytes()) : -1;
    if (flags < 0) return web_initialize(ctx, cls);
    HString*[2] keys = { cls.k_raw, cls.k_flags };
    TVal[2] vals     = { input, { } };
    vals[1].set_number((double)flags);
    if (!shape_path_put(&cls.shapes[0], obj, keys[..], vals[..], h)) {
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
        if (web_own_data_get(&cls.gets[0], obj, cls.k_raw, raw.heap, &input) && input.is_string()
            && web_own_data_get(&cls.gets[1], obj, cls.k_flags, raw.heap, &parts) && parts.is_numeric()) {
            HString* str  = input.get_heapptr();
            double number = parts.is_fastint() ? (double)parts.get_fastint() : parts.get_number();
            // User writes to these public fields can make JS slice coercion
            // observable. Native slicing accepts only the parser's encoding.
            if (str.is_ascii() && number >= 0 && number <= 9007199254740991.0) {
                ulong flags = (ulong)number;
                usz slash   = flags & 0xFFFF;
                usz query   = (flags >> 16) & 0xFFFF;
                String text = (String)str.ascii_bytes();
                if ((double)flags == number && slash <= text.len
                    && (query == 0xFFFF || (query >= slash && query <= text.len))) {
                    if (slash == text.len) return ctx.ret_string("/");
                    TVal slice;
                    if (web_own_data_at(&cls.slots[2], raw.heap.string_proto, cls.k_slice, raw.heap, &slice)
                        && slice.get_raw_bits() == cls.slice.get_raw_bits()) {
                        usz end = query == 0xFFFF ? text.len : query;
                        return ctx.ret_string(text[slash:end - slash]);
                    }
                }
            }
        }
    }
    if (try result = ctx.call(ctx.value(cls.getter), { }, ctx.this_value())) ctx.ret(result);
}

// What web_instanceof learns from a constructor alone: where its
// Symbol.hasInstance method is, if any object on its chain has one, and the
// slot of its own `prototype`. Kept for a few constructors at once.
struct WebCtor {
    ulong epoch;
    HObject* ctor;
    HObject* method_owner;
    int method_slot;
    int proto_slot;
}

tlocal WebCtor[4] web_ctors;
tlocal uint web_ctor_next;

// The constructor's checks, from web_ctors when they hold. False when the JS
// path has to decide.
fn bool web_ctor_lookup(Heap* h, HObject* fn_obj, WebCtor** out) {
    foreach (&c : web_ctors) {
        if (c.ctor == fn_obj && c.epoch == h.prototype_epoch) {
            *out = c;
            return true;
        }
    }
    if (!fn_obj.is_callable() || fn_obj.flags.exotic_proxyobj
        || fn_obj.callable_kind() == hobject::CallableKind.BOUND_FN) return false;
    HObject* owner = fn_obj;
    int method_slot = -1;
    for (uint depth = 0; owner && depth < 32; depth++, owner = owner.prototype) {
        if (owner.flags.exotic_proxyobj) return false;
        method_slot = owner.find_prop_idx(h.hasinstance_symbol, h);
        if (method_slot < 0) continue;
        if (owner.get_prop_flags((uint)method_slot, h).is_accessor) return false;
        break;
    }
    if (owner && method_slot < 0) return false;
    int proto_slot = fn_obj.find_prop_idx(h.str(PROTOTYPE), h);
    if (proto_slot < 0 || fn_obj.get_prop_flags((uint)proto_slot, h).is_accessor) return false;
    // The hasInstance walk read every object up to the method's owner, or the
    // whole chain; observing all of it covers both.
    if (!web_observe_chain(fn_obj)) return false;
    WebCtor* c = &web_ctors[web_ctor_next++ % web_ctors.len];
    *c = { .epoch = h.prototype_epoch, .ctor = fn_obj, .method_owner = owner, .method_slot = method_slot,
           .proto_slot = proto_slot };
    *out = c;
    return true;
}

// OrdinaryHasInstance is pure for an ordinary constructor with the intrinsic
// hasInstance method. Other methods, accessors and proxies use the JS path.
fn bool web_instanceof(Heap* h, TVal value, TVal ctor, bool* result) {
    *result = false;
    if (!ctor.is_object()) return false;
    HObject* fn_obj = ctor.get_heapptr();
    WebCtor* c;
    if (!web_ctor_lookup(h, fn_obj, &c)) return false;
    if (c.method_owner) {
        TVal method = c.method_owner.prop_values()[c.method_slot].get();
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
    }
    if (!value.is_object()) return !value.is_lightfunc();
    TVal prototype = fn_obj.prop_values()[c.proto_slot].get();
    if (!prototype.is_object()) return false;
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
        if (!web_own_data_at(&cls.slots[0], raw.global_env.bindings, cls.k_u8, h, &u8)
            || u8.get_raw_bits() != cls.dependency.get_raw_bits()
            || !web_own_data_at(&cls.slots[1], ctx.value(g_runtime.bk).tv.get_heapptr(), cls.k_file, h, &file)
            || file.get_raw_bits() != cls.file_ctor.get_raw_bits()) return web_initialize(ctx, cls);
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
    if ((!native_body && !string_body && !empty_body)
        || ((native_body || string_body) && !web_can_assign_at(&cls.chains[0], obj, cls.k_body, h))
        || (!string_body && !web_can_assign_at(&cls.chains[1], obj, cls.k_ct, h))) return web_initialize(ctx, cls);
    HString*[2] keys;
    TVal[2] vals;
    uint n;
    if (!string_body) {
        keys[n] = cls.k_ct;
        vals[n++].set_null();
    }
    if (native_body || string_body) {
        keys[n] = cls.k_body;
        vals[n++] = body;
    }
    // One path per key list: body alone, _ct alone, or _ct then body.
    if (!shape_path_put(&cls.shapes[string_body ? 0 : n], obj, keys[:n], vals[:n], h)) {
        return ctx.throw_error(JsErrorKind.ERROR, "Response allocation failed");
    }
    ctx.ret(ctx.this_value());
}

fn HObject*? web_host_function(
    Heap* h,
    String name,
    builtins::HostFunc handler,
    void* cls,
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
    NativeWebClass* cls = is_url ? &g_runtime.native_url : &g_runtime.native_response;
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
    (void)web_own_data(ctx.value(g_runtime.bk).tv.get_heapptr(), cls.k_url_fast, h, &cls.url_fast);
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
    cls.getter = g_runtime.rt.root(hobject::hobject_access_getter(pair)) ?? { };
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

struct NativeHeadersBlob {
    HObject* prototype;
    TVal iterator;
    TVal next;
    HString* map_key;
    HString* cookies_key;
    HString* next_key;
    HString* blob_key;
    TVal blob_method;
    JsValue[9] roots;
}

// A getter or proxy may run guest code; let the JS implementation perform
// those lookups in order. A plain data method can be checked without effects.
fn bool web_method_is(HObject* obj, HString* key, TVal expected, Heap* h) {
    for (uint depth = 0; obj && depth < 32; depth++, obj = obj.prototype) {
        if (obj.flags.exotic_proxyobj) return false;
        int index = obj.find_prop_idx(key, h);
        if (index < 0) continue;
        if (obj.get_prop_flags((uint)index, h).is_accessor) return false;
        return obj.prop_values()[(uint)index].get().get_raw_bits() == expected.get_raw_bits();
    }
    return false;
}

fn bool web_headers_blob(Heap* h, HObject* obj, builtins::StrBuf* output, bool ascii_only = false) {
    NativeHeadersBlob* cls = &g_runtime.native_headers_blob;
    TVal map_value, cookies;
    bool fast              = obj && obj.prototype == cls.prototype && web_method_is(
        obj,
        cls.blob_key,
        cls.blob_method,
        h
    ) && web_own_data(
        obj,
        cls.map_key,
        h,
        &map_value
    ) && web_own_data(obj, cls.cookies_key, h, &cookies) && cookies.is_null() && map_value.is_object();
    HObject* map           = fast ? map_value.get_heapptr() : null;
    fast = fast && map.get_class() == MAP && web_method_is(
        map,
        builtins::ensure_iterator_symbol(h),
        cls.iterator,
        h
    ) && web_method_is(h.map_iterator_proto, cls.next_key, cls.next, h);
    usz length;
    if (fast) {
        for (uint i = 0; i + 1 < map.array_used; i += 2) {
            TVal key = map.array_part()[i].get();
            if (key.is_deleted()) continue;
            TVal value = map.array_part()[i + 1].get();
            // A lone surrogate has no UTF-8 form: the copy would turn it into
            // U+FFFD where the JS method keeps it, so that string declines.
            if (!key.is_string() || !value.is_string() || ((HString*)key.get_heapptr()).is_symbol()
                || ((HString*)value.get_heapptr()).is_symbol()
                || !((HString*)key.get_heapptr()).is_well_formed()
                || !((HString*)value.get_heapptr()).is_well_formed()
                || (ascii_only
                    && (!((HString*)key.get_heapptr()).is_ascii() || !((HString*)value.get_heapptr()).is_ascii()))) {
                fast = false;
                break;
            }
            length += ((HString*)key.get_heapptr()).utf8_len() + ((HString*)value.get_heapptr()).utf8_len() + 2;
        }
    }
    if (!fast) return false;
    // All values and methods are now known to need no coercion or callbacks.
    // Reserve once and copy entries in Map insertion order, skipping deletions.
    if (!output.reserve(length)) return false;
    for (uint i = 0; i + 1 < map.array_used; i += 2) {
        TVal key = map.array_part()[i].get();
        if (key.is_deleted()) continue;
        HString* name  = key.get_heapptr();
        HString* value = map.array_part()[i + 1].get().get_heapptr();
        name.copy_utf8(output.data + output.len);
        output.len += name.utf8_len();
        output.data[output.len++] = '\n';
        value.copy_utf8(output.data + output.len);
        output.len += value.utf8_len();
        output.data[output.len++] = '\n';
    }
    return true;
}

fn void native_headers_blob(BuiltinContext* raw, void* user) {
    JsCtx ctx              = { .ctx = raw };
    NativeHeadersBlob* cls = user;
    TVal receiver          = ctx.this_value().tv;
    HObject* obj           = receiver.is_object() ? receiver.get_heapptr() : null;
    builtins::StrBuf output;
    output.init(raw.heap);
    defer output.free();
    if (web_headers_blob(raw.heap, obj, &output)) return ctx.ret_string((String)output.bytes());
    if (output.failed) return ctx.throw_error(RANGE, "Invalid string length");
    if (try result = ctx.call(ctx.value(cls.roots[1]), { }, ctx.this_value())) ctx.ret(result);
}

fn void js_native_headers_blob(JsCtx ctx, void* user) {
    NativeHeadersBlob* cls = &g_runtime.native_headers_blob;
    if (cls.prototype || !ctx.arg(0).tv.is_object()) return ctx.throw_error(TYPE, "Invalid Headers prototype");
    for (uint i = 0; i < 4; i++) cls.roots[i] = ctx.persist(ctx.arg(i))!!;
    cls.prototype = ctx.arg(0).tv.get_heapptr();
    cls.iterator = ctx.arg(2).tv;
    cls.next = ctx.arg(3).tv;
    String[3] names = { "_map", "_cookies", "next" };
    HString*[3] keys;
    for (uint i = 0; i < 3; i++) {
        JsArg key = ctx.string(names[i]);
        cls.roots[i + 4] = ctx.persist(key)!!;
        keys[i] = key.tv.get_heapptr();
    }
    cls.map_key = keys[0];
    cls.cookies_key = keys[1];
    cls.next_key = keys[2];
    HObject*? made = web_host_function(ctx.ctx.heap, "_blob", &native_headers_blob, cls, 0, false);
    if (catch made) return ctx.throw_error(ERROR, "Native Headers allocation failed");
    JsArg result;
    result.tv.set_object(made);
    JsArg key = ctx.string("_blob");
    cls.blob_key = key.tv.get_heapptr();
    cls.roots[7] = ctx.persist(key)!!;
    cls.blob_method = result.tv;
    cls.roots[8] = ctx.persist(result)!!;
    ctx.ret(result);
}

struct NativeHeadersParse {
    TVal[9] dependencies;
    HString*[8] keys;
    JsValue[17] roots;
}

fn bool web_header_ascii_space(char c) => c == ' ' || (c >= 9 && c <= 13);

fn void native_headers_from_blob(BuiltinContext* raw, void* user) {
    @pool() {
        JsCtx ctx                  = { .ctx = raw };
        NativeHeadersParse* cls    = user;
        NativeHeadersBlob* headers = &g_runtime.native_headers_blob;
        TVal input                 = ctx.arg(0).tv;
        TVal map_ctor, string_ctor;
        bool fast                  = input.is_string() && ((HString*)input.get_heapptr()).is_ascii() && web_own_data(
            raw.global_env.bindings,
            cls.keys[0],
            raw.heap,
            &map_ctor
        ) && map_ctor.get_raw_bits() == cls.dependencies[1].get_raw_bits() && web_own_data(
            raw.global_env.bindings,
            cls.keys[1],
            raw.heap,
            &string_ctor
        ) && string_ctor.get_raw_bits() == cls.dependencies[2].get_raw_bits() && web_method_is(
            raw.heap.string_proto,
            cls.keys[2],
            cls.dependencies[3],
            raw.heap
        ) && web_method_is(
            raw.heap.string_proto,
            cls.keys[3],
            cls.dependencies[4],
            raw.heap
        ) && web_method_is(
            raw.heap.string_proto,
            cls.keys[4],
            cls.dependencies[5],
            raw.heap
        ) && web_method_is(
            headers.prototype,
            cls.keys[5],
            cls.dependencies[6],
            raw.heap
        ) && web_method_is(
            raw.heap.map_proto,
            cls.keys[6],
            cls.dependencies[7],
            raw.heap
        ) && web_method_is(
            raw.heap.map_proto,
            cls.keys[7],
            cls.dependencies[8],
            raw.heap
        ) && web_can_assign(
            headers.prototype,
            headers.map_key,
            raw.heap
        ) && web_can_assign(headers.prototype, headers.cookies_key, raw.heap);
        char[] bytes               = fast ? ((HString*)input.get_heapptr()).ascii_bytes() : (char[]) { };
        // Set-Cookie has a separate array and joining policy in the JS class.
        // Preflight before creating any partially populated native object.
        for (usz at = 0; fast && at < bytes.len;) {
            usz key_end = at;
            while (key_end < bytes.len && bytes[key_end] != '\n') key_end++;
            if (key_end == bytes.len) break;
            if (((String)bytes[at:key_end - at]).compare_to_ignore_case("set-cookie") == 0) {
                fast = false;
                break;
            }
            at = key_end + 1;
            while (at < bytes.len && bytes[at] != '\n') at++;
            at++;
        }
        if (!fast) {
            JsArg[1] args = { ctx.arg(0) };
            if (try result = ctx.call(ctx.value(cls.roots[0]), args[..], ctx.this_value())) ctx.ret(result);
            return;
        }
        HObject*? made = raw.heap.alloc_object(OBJECT);
        if (catch made) return ctx.throw_error(ERROR, "Headers allocation failed");
        HObject* obj = made;
        raw.heap.set_prototype(obj, headers.prototype);
        HObject*? map_raw = raw.heap.alloc_object(MAP);
        if (catch map_raw) return ctx.throw_error(ERROR, "Headers allocation failed");
        HObject* map = map_raw;
        raw.heap.set_prototype(map, raw.heap.map_proto);
        TVal map_value;
        map_value.set_object(map);
        if (!obj.put_prop(
            headers.map_key,
            map_value,
            hobject::PROP_FLAGS_WEC,
            raw.heap
        ) || !obj.put_prop(headers.cookies_key, ctx.null_value()
            .tv, hobject::PROP_FLAGS_WEC, raw.heap)) return ctx.throw_error(ERROR, "Headers allocation failed");
        for (usz at = 0; at < bytes.len;) {
            usz key_end = at;
            while (key_end < bytes.len && bytes[key_end] != '\n') key_end++;
            if (key_end == bytes.len) break;
            char[] name = mem::temp_array(char, (sz)(key_end - at));
            for (usz i = 0; i < name.len; i++) {
                char c = bytes[at + i];
                name[i] = c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
            }
            usz start = key_end + 1;
            usz end   = start;
            while (end < bytes.len && bytes[end] != '\n') end++;
            at = end + 1;
            while (start < end && web_header_ascii_space(bytes[start])) start++;
            while (end > start && web_header_ascii_space(bytes[end - 1])) end--;
            JsArg key   = ctx.string((String)name);
            JsArg value = ctx.string((String)bytes[start:end - start]);
            int found   = builtins::map_find_key(map, key.tv, raw.heap);
            if (found >= 0) {
                HString* old = map.array_part()[(uint)found + 1].get().get_heapptr();
                builtins::StrBuf joined;
                joined.init(raw.heap);
                defer joined.free();
                if (!joined.append_bytes(
                    (char[])boomkat::utf8_of(old, tmem)
                ) || !joined.append_bytes(
                    ", "
                ) || !joined.append_bytes(
                    bytes[start:end - start]
                )) return ctx.throw_error(RANGE, "Invalid string length");
                value = ctx.string((String)joined.bytes());
                raw.heap.store_slot_ref(map, &map.array_part()[(uint)found + 1], &value.tv);
            } else {
                uint count = map.array_used;
                if (!map.set_array_idx(
                    count,
                    key.tv,
                    raw.heap
                ) || !map.set_array_idx(
                    count + 1,
                    value.tv,
                    raw.heap
                )) return ctx.throw_error(ERROR, "Headers allocation failed");
            }
        }
        JsArg result;
        result.tv.set_object(obj);
        ctx.ret(result);
    };
}

fn void js_native_headers_from_blob(JsCtx ctx, void* user) {
    NativeHeadersParse* cls = &g_runtime.native_headers_parse;
    if (!cls.roots[0].is_empty()) return ctx.throw_error(TYPE, "Headers parser already installed");
    for (uint i = 0; i < 9; i++) {
        cls.dependencies[i] = ctx.arg(i).tv;
        cls.roots[i] = ctx.persist(ctx.arg(i))!!;
    }
    String[8] names = { "Map", "String", "split", "toLowerCase", "trim", "append", "get", "set" };
    for (uint i = 0; i < 8; i++) {
        JsArg key = ctx.string(names[i]);
        cls.keys[i] = key.tv.get_heapptr();
        cls.roots[9 + i] = ctx.persist(key)!!;
    }
    HObject*? made = web_host_function(ctx.ctx.heap, "_fromBlob", &native_headers_from_blob, cls, 1, false);
    if (catch made) return ctx.throw_error(ERROR, "Headers parser allocation failed");
    JsArg result;
    result.tv.set_object(made);
    ctx.ret(result);
}

// Record construction uses no guest callbacks when all entries are ASCII
// strings and the conversion, enumeration and Map methods remain intrinsic.
struct NativeHeadersRecord
{
	TVal[7] dependencies;
	HString* object_key;
	HString* keys_key;
	HString* symbol_key;
	HString* iterator_key;
	JsValue[11] roots;
}

fn bool web_data_or_missing(HObject* obj, HString* key, Heap* h, TVal* value)
{
	for (uint depth = 0; obj && depth < 32; depth++, obj = obj.prototype)
	{
		if (obj.flags.exotic_proxyobj) return false;
		int slot = obj.find_prop_idx(key, h);
		if (slot < 0) continue;
		if (obj.get_prop_flags((uint)slot, h).is_accessor) return false;
		*value = obj.prop_values()[slot].get();
		return true;
	}
	value.set_undefined();
	return obj == null;
}

fn void native_headers_record(BuiltinContext* raw, void* user)
{
	@pool()
	{
		JsCtx ctx = { .ctx = raw };
		ctx.ret_bool(false);
		NativeHeadersRecord* cls   = user;
		NativeHeadersBlob* headers = &g_runtime.native_headers_blob;
		NativeHeadersParse* parse  = &g_runtime.native_headers_parse;
		TVal receiver              = ctx.arg(0).tv;
		TVal input                 = ctx.arg(1).tv;
		if (!receiver.is_object() || !input.is_object()) return;
		HObject* obj    = receiver.get_heapptr();
		HObject* record = input.get_heapptr();
		Heap* h         = raw.heap;
		if (obj.prototype != headers.prototype || obj.flags.exotic_proxyobj || record.get_class() != OBJECT
			|| record.flags.exotic_proxyobj
			|| record.array_used
			|| (record.prototype && record.prototype != h.object_proto)) return;
		TVal object_ctor, string_ctor, symbol_ctor, symbol_iterator, map_value, iterator;
		if (!web_own_data(
			raw.global_env.bindings,
			cls.object_key,
			h,
			&object_ctor
		) || object_ctor.get_raw_bits() != cls.dependencies[1].get_raw_bits() || !web_method_is(
			object_ctor.get_heapptr(),
			cls.keys_key,
			cls.dependencies[2],
			h
		) || !web_own_data(
			raw.global_env.bindings,
			parse.keys[1],
			h,
			&string_ctor
		) || string_ctor.get_raw_bits() != parse.dependencies[2].get_raw_bits() || !web_method_is(
			h.string_proto,
			parse.keys[3],
			parse.dependencies[4],
			h
		) || !web_method_is(
			h.string_proto,
			parse.keys[4],
			parse.dependencies[5],
			h
		) || !web_method_is(
			h.array_proto,
			builtins::ensure_iterator_symbol(h),
			cls.dependencies[3],
			h
		) || !web_method_is(
			h.array_iterator_proto,
			headers.next_key,
			cls.dependencies[4],
			h
		) || !web_own_data(
			raw.global_env.bindings,
			cls.symbol_key,
			h,
			&symbol_ctor
		) || symbol_ctor.get_raw_bits() != cls.dependencies[5].get_raw_bits() || !web_own_data(
			symbol_ctor.get_heapptr(),
			cls.iterator_key,
			h,
			&symbol_iterator
		) || symbol_iterator.get_raw_bits() != cls.dependencies[6].get_raw_bits() || !web_own_data(
			obj,
			headers.map_key,
			h,
			&map_value
		) || !map_value.is_object()) return;
		HObject* map = map_value.get_heapptr();
		if (map.get_class() != MAP || map.array_used || !web_method_is(
			map,
			parse.keys[7],
			parse.dependencies[8],
			h
		)) return;
		bool instance;
		if (!web_instanceof(
			h,
			input,
			cls.dependencies[0],
			&instance
		) || instance || !web_data_or_missing(
			record,
			builtins::ensure_iterator_symbol(h),
			h,
			&iterator
		) || (!iterator.is_undefined() && !iterator.is_null())) return;
		HString*[] keys = mem::temp_array(HString*, record.prop_count);
		uint count      = builtins::collect_own_string_keys(h, record, keys.ptr);
		// Validate before touching the receiver, so fallback preserves getters
		// and coercions in the original constructor's order.
		for (uint i = 0; i < count; i++)
		{
			TVal value;
			if (!keys[i].is_ascii() || ((String)keys[i].ascii_bytes()).compare_to_ignore_case(
				"set-cookie"
			) == 0 || !web_own_data(
				record,
				keys[i],
				h,
				&value
			) || !value
				.is_string() || ((HString*)value.get_heapptr())
					.is_symbol() || !((HString*)value.get_heapptr()).is_ascii()) return;
		}
		for (uint i = 0; i < count; i++)
		{
			char[] name = keys[i].ascii_bytes();
			bool lower  = true;
			foreach (c : name) if (c >= 'A' && c <= 'Z')
			{
				lower = false;
				break;
			}
			JsArg key;
			if (lower)
			{
				key.tv.set_string_borrowed(keys[i]);
			}
			else
			{
				char[] normalized = mem::temp_array(char, name.len);
				foreach (n, c : name) normalized[n] = c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
				key = ctx.string((String)normalized);
			}
			TVal value;
			(void)web_own_data(record, keys[i], h, &value);
			char[] bytes = ((HString*)value.get_heapptr()).ascii_bytes();
			usz start    = 0;
			usz end      = bytes.len;
			while (start < end && web_header_ascii_space(bytes[start])) start++;
			while (end > start && web_header_ascii_space(bytes[end - 1])) end--;
			if (start || end != bytes.len) value = ctx.string((String)bytes[start:end - start]).tv;
			int found = builtins::map_find_key(map, key.tv, h);
			if (found >= 0)
			{
				h.store_slot_ref(map, &map.array_part()[(uint)found + 1], &value);
			}
			else
			{
				uint at = map.array_used;
				if (!map.set_array_idx(at, key.tv, h) || !map.set_array_idx(at + 1, value, h))
				{
					return ctx.throw_error(ERROR, "Headers allocation failed");
				}
			}
		}
		ctx.ret_bool(true);
	};
}

fn void js_native_headers_record(JsCtx ctx, void* user)
{
	NativeHeadersRecord* cls = &g_runtime.native_headers_record;
	if (!cls.roots[0].is_empty()) return ctx.throw_error(TYPE, "Headers record initializer already installed");
	for (uint i = 0; i < 7; i++)
	{
		cls.dependencies[i] = ctx.arg(i).tv;
		cls.roots[i] = ctx.persist(ctx.arg(i))!!;
	}
	JsArg object_key = ctx.string("Object");
	JsArg keys_key   = ctx.string("keys");
	cls.object_key = object_key.tv.get_heapptr();
	cls.keys_key = keys_key.tv.get_heapptr();
	cls.roots[7] = ctx.persist(object_key)!!;
	cls.roots[8] = ctx.persist(keys_key)!!;
	JsArg symbol_key   = ctx.string("Symbol");
	JsArg iterator_key = ctx.string("iterator");
	cls.symbol_key = symbol_key.tv.get_heapptr();
	cls.iterator_key = iterator_key.tv.get_heapptr();
	cls.roots[9] = ctx.persist(symbol_key)!!;
	cls.roots[10] = ctx.persist(iterator_key)!!;
	HObject*? made = web_host_function(ctx.ctx.heap, "_initRecord", &native_headers_record, cls, 2, false);
	if (catch made) return ctx.throw_error(ERROR, "Headers record initializer allocation failed");
	JsArg result;
	result.tv.set_object(made);
	ctx.ret(result);
}

const Native[] WEB_NATIVES = {
    { "nativeClass", &js_native_class, 6 },
    { "nativeHeadersBlob", &js_native_headers_blob, 4 },
    { "nativeHeadersFromBlob", &js_native_headers_from_blob, 9 },
    { "nativeHeadersRecord", &js_native_headers_record, 7 },
};
