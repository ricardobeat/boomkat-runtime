// Registry handles keep callbacks alive until their loop turn or cancellation.
module bkr;

import boomkat;
import boomkat::builtins;
import boomkat::types;
import std::collections::map;

struct PendingImmediate {
    PendingImmediate* next;
    ulong id;
    JsValue callback;
    JsValue[] args;
    bool canceled;
}

PendingImmediate* g_immediate_head;
PendingImmediate* g_immediate_tail;
HashMap{ulong, PendingImmediate*} g_immediate_ids;
ulong g_next_immediate = 1;

fn void init_immediates() => g_immediate_ids.init(mem);

fn void immediate_free(PendingImmediate* t) {
    g_rt.release(t.callback);
    foreach (a : t.args) g_rt.release(a);
    if (t.args.len) free(t.args.ptr);
    free(t);
}

fn void js_set_immediate(JsCtx ctx, void* user) {
    JsArg callback = ctx.arg(0);
    if (!builtins::is_callable_tval(callback.tv)) {
        ctx.throw_error(TYPE, "callback must be a function");
        return;
    }
    PendingImmediate* t = mem::new(PendingImmediate);
    t.id = g_next_immediate++;
    t.callback = ctx.persist(callback) ?? { };
    if (t.callback.is_empty()) {
        immediate_free(t);
        return ctx.throw_error(ERROR, "immediate allocation failed");
    }
    if (ctx.argc() > 1) {
        t.args = mem::new_array(JsValue, (sz)ctx.argc() - 1);
        foreach (i, &arg : t.args) {
            *arg = ctx.persist(ctx.arg((uint)i + 1)) ?? { };
            if (arg.is_empty()) {
                immediate_free(t);
                return ctx.throw_error(ERROR, "immediate allocation failed");
            }
        }
    }
    if (g_immediate_tail) {
        g_immediate_tail.next = t;
    } else {
        g_immediate_head = t;
    }
    g_immediate_tail = t;
    g_immediate_ids.set(t.id, t);
    js_immediate_arm(ctx, null);
    ctx.ret_number((double)t.id);
}

fn void js_clear_immediate(JsCtx ctx, void* user) {
    if (!ctx.arg(0).is_number()) return;
    double id = ctx.arg(0).as_number() ?? -1;
    if (!(id >= 1) || id > 9007199254740991.0 || (double)(ulong)id != id) return;
    if (try t = g_immediate_ids.get((ulong)id)) {
        t.canceled = true;
        g_immediate_ids.remove(t.id);
    }
}

// Called inside one JS entry, preserving the batch's microtask checkpoint.
// Detaching the queue sends callbacks added by this batch to the next turn.
fn void js_run_immediates(JsCtx ctx, void* user) {
    PendingImmediate* batch = g_immediate_head;
    g_immediate_head = null;
    g_immediate_tail = null;
    defer while (batch) {
        PendingImmediate* t = batch;
        batch = t.next;
        g_immediate_ids.remove(t.id);
        immediate_free(t);
    }
    while (batch) {
        PendingImmediate* t = batch;
        batch = t.next;
        g_immediate_ids.remove(t.id);
        defer immediate_free(t);
        if (t.canceled) continue;
        @pool() {
            TVal[] args = mem::temp_array(TVal, t.args.len);
            foreach (i, &arg : args) *arg = ctx.value(t.args[i]).tv;
            TVal this_value;
            this_value.set_undefined();
            bool ok;
            builtins::host_call(ctx.ctx, ctx.value(t.callback).tv, args.ptr, (uint)args.len, this_value, &ok);
            if (!ok) return;
        };
    }
}

const Native[] IMMEDIATE_NATIVES = {
    { "setImmediate", &js_set_immediate, 1 },
    { "clearImmediate", &js_clear_immediate, 1 },
    { "runImmediates", &js_run_immediates, 0 },
};