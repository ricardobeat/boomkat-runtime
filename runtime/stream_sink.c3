// The common direct-source controller operation, without a JS method frame.
// Misses run the original method before any observable mutation occurs.
module bkr;

import boomkat;
import boomkat::builtins;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;

struct SinkSlot {
    ICEntry ic;
    uint epoch;
    void* key;
}


fn void js_sink_types(JsCtx ctx, void* user) {
    if (!g_runtime.sink_fallback.is_empty()) {
        ctx.throw_error(TYPE, "stream controller is already configured");
        return;
    }
    JsArg fallback  = ctx.arg(0);
    TVal symbol_key = ctx.arg(3).tv;
    if (fallback.type_of() != FUNCTION || !ctx.arg(1)
        .tv.is_object() || !ctx.arg(2)
            .tv.is_object() || !symbol_key.is_string() || !((HString*)symbol_key.get_heapptr()).is_symbol()) {
        ctx.throw_error(TYPE, "invalid stream controller configuration");
        return;
    }
    g_runtime.sink_fallback = ctx.persist(ctx.arg(0)) ?? { };
    g_runtime.sink_global = ctx.persist(ctx.arg(1)) ?? { };
    g_runtime.sink_constructor = ctx.persist(ctx.arg(2)) ?? { };
    g_runtime.sink_global_object = ctx.arg(1).tv.get_heapptr();
    g_runtime.sink_constructor_object = ctx.arg(2).tv.get_heapptr();
    String[8] names = { "closed", "parts", "size", "nudge", "length", "push", "Uint8Array", "prototype" };
    foreach (i, name : names) {
        JsValue key = g_runtime.rt.string(name) ?? { };
        g_runtime.sink_keys[i] = key;
        g_runtime.sink_slots[i].key = ctx.value(key).tv.get_heapptr();
        // Registry handles keep the interned keys alive for the runtime.
    }
    JsValue symbol = ctx.persist(ctx.arg(3)) ?? { };
    g_runtime.sink_keys[8] = symbol;
    g_runtime.sink_slots[8].key = ctx.value(symbol).tv.get_heapptr();
}

// Shape and epoch protect the index; links are compared against the live
// chain before a weak prototype pointer can be dereferenced. Values, including
// accessor pairs, are always read from current storage.
fn PropValue* sink_slot(HObject* receiver, uint index, heap::Heap* h, bool own = false) @inline {
    if (receiver == null || receiver.flags.exotic_proxyobj) return null;
    SinkSlot* cache = &g_runtime.sink_slots[index];
    ICEntry* ic     = &cache.ic;
    // Globals use a mutable dictionary shape. An existing slot can be read,
    // but its index and flags must be checked against the live dictionary.
    if (own && receiver.in_dict_mode(h)) {
        int idx = receiver.find_prop_idx(cache.key, h);
        if (idx < 0) return null;
        ic.prop_flags = receiver.get_prop_flags((uint)idx, h);
        return &receiver.prop_values()[idx];
    }
    if (ic.key != (hstring::StringRef)null && cache.epoch == h.shape_recycle_epoch
        && ic.shape_id == receiver.shape_id) {
        PropValue* slot = hobject::ic_resolve_slot(ic, receiver);
        if (slot != null && (!own || !ic.has_proto)) return slot;
    }
    return sink_slot_fill(receiver, index, h, own);
}

fn PropValue* sink_slot_fill(HObject* receiver, uint index, heap::Heap* h, bool own) {
    SinkSlot* cache = &g_runtime.sink_slots[index];
    ICEntry* ic     = &cache.ic;
    // The chain block is pool memory the entry keeps across refills.
    hobject::ICChain* chain = ic.chain;
    *ic = { .chain = chain };
    HObject* cur = receiver;
    uint depth   = 0;
    while (cur != null) {
        if (cur.flags.exotic_proxyobj || cur.in_dict_mode(h)) return null;
        int idx = cur.find_prop_idx(cache.key, h);
        if (idx >= 0) {
            ic.shape_id = receiver.shape_id;
            ic.prop_idx = (uint)idx;
            ic.prop_flags = cur.get_prop_flags((uint)idx, h);
            ic.chain_len = (char)depth;
            ic.has_proto = depth != 0;
            ic.key = (hstring::StringRef)cache.key;
            cache.epoch = h.shape_recycle_epoch;
            return &cur.prop_values()[idx];
        }
        if (own || depth == hobject::IC_MAX_CHAIN) return null;
        cur = cur.prototype;
        if (cur == null || !hobject::ic_reserve_chain(ic, h)) return null;
        ic.chain.snapshot.protos[depth] = cur;
        ic.chain.snapshot.shapes[depth++] = cur.shape_id;
    }
    return null;
}

fn bool sink_builtin(TVal value, builtins::Builtin builtin) @inline {
    if (value.is_lightfunc()) return value.get_heapptr() == (void*)(usz)builtin.ordinal;
    if (!value.is_object()) return false;
    HObject* fn_obj = value.get_heapptr();
    return fn_obj.is_callable() && fn_obj.callable_kind() == BUILTIN_FN
        && (*fn_obj.extra_ptr()).func.builtin_fn_index == (int)builtin.ordinal;
}

fn bool sink_layout(HObject* sink, heap::Heap* h) {
    if (sink.flags.exotic_proxyobj || sink.in_dict_mode(h)) return false;
    uint[4] indices;
    for (uint i = 0; i < 4; i++) {
        int idx = sink.find_prop_idx(g_runtime.sink_slots[i].key, h);
        if (idx < 0) return false;
        PropFlags flags = sink.get_prop_flags((uint)idx, h);
        if (flags.is_accessor || (i == 2 && !flags.writable)) return false;
        indices[i] = (uint)idx;
    }
    g_runtime.sink_shape = sink.shape_id;
    g_runtime.sink_layout_epoch = h.shape_recycle_epoch;
    g_runtime.sink_indices = indices;
    g_runtime.sink_layout_valid = true;
    return true;
}

fn bool sink_enqueue_fast(JsCtx ctx) {
    heap::Heap* h = ctx.ctx.heap;
    TVal receiver = ctx.this_value().tv;
    TVal chunk    = ctx.arg(0).tv;
    if (!receiver.is_object() || !chunk.is_object()) return false;
    HObject* sink = receiver.get_heapptr();
    HObject* view = chunk.get_heapptr();
    if (sink.get_class() != OBJECT || sink.flags.exotic_proxyobj || view.get_class() != UINT8ARRAY
        || view.flags.exotic_proxyobj) return false;
    // Prove the same instanceof result as the fallback. Constructor changes,
    // custom @@hasInstance and alternate view prototypes use the JS method.
    HObject* ctor = g_runtime.sink_constructor_object;
    if (view.prototype != h.uint8array_proto) return false;
    // A later global lexical declaration can shadow the object-record value
    // seen by the prelude's free variable without changing globalThis.
    HObject* lexical = g_runtime.rt.rt.vm.global_lex_env.bindings;
    if (lexical.find_prop_idx(g_runtime.sink_slots[6].key, h) >= 0) return false;
    HObject* global        = g_runtime.sink_global_object;
    PropValue* global_ctor = sink_slot(global, 6, h, true);
    if (global_ctor == null || g_runtime.sink_slots[6].ic.prop_flags.is_accessor) return false;
    TVal global_value = global_ctor.get();
    if (!global_value.is_object() || global_value.get_heapptr() != ctor) return false;
    PropValue* ctor_proto   = sink_slot(ctor, 7, h);
    PropValue* has_instance = sink_slot(ctor, 8, h);
    if (ctor_proto == null || has_instance == null || g_runtime.sink_slots[7].ic.prop_flags.is_accessor
        || g_runtime.sink_slots[8].ic.prop_flags.is_accessor) return false;
    TVal prototype = ctor_proto.get();
    if (!prototype.is_object() || prototype.get_heapptr() != h.uint8array_proto || !sink_builtin(
        has_instance.get(),
        FUNCTION_PROTO_HASINSTANCE
    )) return false;
    bool layout_matches = g_runtime.sink_layout_valid && sink.shape_id == g_runtime.sink_shape
        && g_runtime.sink_layout_epoch == h.shape_recycle_epoch;
    if (!layout_matches && !sink_layout(sink, h)) return false;
    PropValue* slots  = sink.prop_values();
    PropValue* closed = &slots[g_runtime.sink_indices[0]];
    PropValue* parts  = &slots[g_runtime.sink_indices[1]];
    PropValue* size   = &slots[g_runtime.sink_indices[2]];
    PropValue* nudge  = &slots[g_runtime.sink_indices[3]];
    TVal closed_value = closed.get();
    TVal parts_value  = parts.get();
    TVal size_value   = size.get();
    TVal nudge_value  = nudge.get();
    if (!closed_value.is_boolean() || closed_value.get_boolean() || !nudge_value.is_null() || !parts_value.is_object()
        || !size_value.is_fastint()) return false;
    long count  = size_value.get_fastint();
    uint length = builtins::ta_element_count(view);
    if (count < 0 || count > types::FASTINT_MAX - length) return false;
    PropValue* view_length = sink_slot(view, 4, h);
    if (view_length == null || !g_runtime.sink_slots[4].ic.prop_flags.is_accessor) return false;
    TVal getter = hobject::hobject_access_getter(view_length.get());
    if (!sink_builtin(getter, TYPEDARRAY_PROTO_LENGTH_GET)) return false;
    HObject* array  = parts_value.get_heapptr();
    PropValue* push = sink_slot(array, 5, h);
    if (push == null || g_runtime.sink_slots[5].ic.prop_flags.is_accessor) return false;
    if (!sink_builtin(push.get(), ARRAY_PROTO_PUSH)) return false;
    // Reserve capacity without entering JS. Growing storage is invisible and
    // does not invoke property hooks; the helper still validates the append.
    if (array.get_class() == ARRAY && *array.array_len_ptr() == array.array_size && array.array_size < 0x1000000u) {
        array.grow_array(array.array_size ? array.array_size * 2 : 8, h);
    }
    // The engine helper checks writable length, extensibility, holes and
    // indexed prototype descriptors, and stores with the heap write barrier.
    if (builtins::array_push_one_fast(array, chunk, h) < 0) return false;
    size.set_fastint(count + length);
    return true;
}

fn void js_sink_enqueue(JsCtx ctx, void* user) {
    if (sink_enqueue_fast(ctx)) return;
    JsArg[1] args = { ctx.arg(0) };
    if (try result = ctx.call(ctx.value(g_runtime.sink_fallback), args[..], ctx.this_value())) ctx.ret(result);
}
