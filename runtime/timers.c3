// setTimeout and setInterval: one binary heap of timers ordered by due time,
// served by a single native timer armed for the earliest. Callbacks are held
// as registry handles, so a timer costs no JS bookkeeping.
module bkr;

import boomkat;
import std::collections::list;
import std::collections::map;

struct PendingTimer {
    ulong due; // ns, CLOCK_MONOTONIC_RAW
    uint id;
    long interval; // ns, or -1 for a one-shot
    JsValue callback;
    JsValue[] args;
    sz at; // index in g_runtime.timer_heap
}


fn void init_timers() {
    g_runtime.timer_heap.init(mem, 64);
    g_runtime.timer_ids.init(mem);
}

fn bool timer_before(PendingTimer* a, PendingTimer* b) @inline => a.due < b.due || (a.due == b.due && a.id < b.id);

fn void timer_place(PendingTimer* t, sz i) @inline {
    g_runtime.timer_heap[i] = t;
    t.at = i;
}

fn void timer_up(sz i) {
    PendingTimer* t = g_runtime.timer_heap[i];
    while (i > 0) {
        sz parent = (i - 1) / 2;
        if (!timer_before(t, g_runtime.timer_heap[parent])) break;
        timer_place(g_runtime.timer_heap[parent], i);
        i = parent;
    }
    timer_place(t, i);
}

fn void timer_down(sz i) {
    sz n            = (sz)g_runtime.timer_heap.len();
    PendingTimer* t = g_runtime.timer_heap[i];
    while (true) {
        sz c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && timer_before(g_runtime.timer_heap[c + 1], g_runtime.timer_heap[c])) c++;
        if (!timer_before(g_runtime.timer_heap[c], t)) break;
        timer_place(g_runtime.timer_heap[c], i);
        i = c;
    }
    timer_place(t, i);
}

fn void timer_push(PendingTimer* t) {
    g_runtime.timer_heap.push(t);
    timer_up((sz)g_runtime.timer_heap.len() - 1);
}

fn void timer_remove(PendingTimer* t) {
    sz i               = t.at;
    PendingTimer* last = g_runtime.timer_heap.pop()!!;
    if (last == t) return;
    timer_place(last, i);
    timer_down(i);
    timer_up(last.at);
}

fn void timer_free(PendingTimer* t) {
    g_runtime.rt.release(t.callback);
    foreach (a : t.args) g_runtime.rt.release(a);
    if (t.args.len) free(t.args.ptr);
    free(t);
}

fn void timer_native_fired(void* user) {
    g_runtime.timer_native = null;
    fire_timers();
}

// Point the native timer at the earliest due time, if that changed.
fn void timer_arm(ulong now) {
    if (!g_runtime.timer_heap.len()) {
        if (g_runtime.timer_native) {
            timer_cancel(g_runtime.timer_native);
            g_runtime.timer_native = null;
        }
        return;
    }
    ulong due = g_runtime.timer_heap[0].due;
    if (g_runtime.timer_native) {
        if (due >= g_runtime.timer_armed_due) return;
        timer_cancel(g_runtime.timer_native);
    }
    g_runtime.timer_armed_due = due;
    ulong delay = due > now ? due - now : 1;
    g_runtime.timer_native = timer_start_ns(delay, &timer_native_fired, null);
}

fn void fire_timers() {
    // Keep this cutoff fixed: intervals reinserted by this batch belong to a
    // later loop turn even if their callbacks take longer than the interval.
    ulong now = now_ns();
    while (g_runtime.timer_heap.len() && g_runtime.timer_heap[0].due <= now) {
        PendingTimer* t = g_runtime.timer_heap[0];
        timer_remove(t);
        if (t.interval >= 0) {
            t.due = now_ns() + (ulong)t.interval;
            timer_push(t);
            (void)call_js(t.callback, t.args);
        } else {
            g_runtime.timer_ids.remove(t.id);
            defer timer_free(t);
            (void)call_js(t.callback, t.args);
        }
    }
    timer_arm(now_ns());
}

fn void add_timer(JsCtx ctx, bool repeat) {
    JsArg f = ctx.arg(0);
    if (f.type_of() != JsType.FUNCTION) {
        ctx.throw_error(TYPE, "callback must be a function");
        return;
    }
    double ms = ctx.argc() > 1 ? ctx.arg(1).as_number() ?? 0 : 0;
    if (!(ms >= 0)) ms = 0;
    if (ms > 2147483647) ms = 1;
    PendingTimer* t = mem::new(PendingTimer);
    t.id = g_runtime.next_timer++;
    t.callback = ctx.persist(f) ?? { };
    if (ctx.argc() > 2) {
        t.args = mem::new_array(JsValue, (usz)ctx.argc() - 2);
        foreach (i, &a : t.args) *a = ctx.persist(ctx.arg((uint)i + 2)) ?? { };
    }
    long span = max((long)(ms * 1e6), (long)1_000_000);
    t.interval = repeat ? span : -1;
    ulong now = now_ns();
    t.due = now + (ulong)span;
    timer_push(t);
    g_runtime.timer_ids.set(t.id, t);
    timer_arm(now);
    ctx.ret_number(t.id);
}

fn void js_set_timeout(JsCtx ctx, void* udata) => add_timer(ctx, false);

fn void js_set_interval(JsCtx ctx, void* udata) => add_timer(ctx, true);

fn void js_clear_timer(JsCtx ctx, void* udata) {
    if (!ctx.arg(0).is_number()) return;
    PendingTimer*? t = g_runtime.timer_ids.get(ctx.arg(0).id());
    if (catch t) return;
    g_runtime.timer_ids.remove(t.id);
    timer_remove(t);
    timer_free(t);
    if (!g_runtime.timer_heap.len()) timer_arm(0);
}

const Native[] TIMER_NATIVES = {
    { "setTimeout", &js_set_timeout, 2 },
    { "setInterval", &js_set_interval, 2 },
    { "clearTimer", &js_clear_timer, 1 },
};
