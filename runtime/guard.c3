// Every entry from the loop into JS goes through call_js, which owns what
// happens around it: uncaught exceptions, unhandled rejections and the
// watchdog that interrupts JS running past --time-limit.
module bkr;

import boomkat;
import std::io;
import std::thread;
import std::time;
import std::collections::map;

faultdef TIMED_OUT;
faultdef WORKER_STOPPED;

// ---- unhandled rejections ----

struct Rejection {
    JsValue promise;
    JsValue reason;
}


fn void on_rejection(JsRuntime* rt, ulong id, JsValue promise, JsValue reason, bool handled, void* udata) {
    if (handled) {
        Rejection? r = g_runtime.rejections.get(id);
        if (catch r) return;
        rt.release(r.promise);
        rt.release(r.reason);
        g_runtime.rejections.remove(id);
        return;
    }
    if (g_runtime.rejections.has_key(id)) return;
    g_runtime.rejections.set(id, { rt.persist(promise) ?? { }, rt.persist(reason) ?? { } });
}

// Rejections still unhandled once the microtasks have drained reach the
// global "unhandledrejection" event; unless a listener prevents its default,
// the process ends, as in Deno.
fn void flush_rejections() {
    while (g_runtime.rejections.len()) {
        ulong id    = g_runtime.rejections.keys(tmem)[0];
        Rejection r = g_runtime.rejections.get(id)!!;
        g_runtime.rejections.remove(id);
        defer {
            g_runtime.rt.release(r.promise);
            g_runtime.rt.release(r.reason);
        }
        JsValue[2] args    = { r.reason, r.promise };
        JsValue? prevented = g_runtime.rt.call(g_runtime.unhandled, args[..]);
        if (catch prevented) {
            report_uncaught();
            continue;
        }
        defer g_runtime.rt.release(prevented);
        if (g_runtime.rt.as_bool(prevented) ?? false) continue;
        g_runtime.rt.@scope() {
            JsValue[1] a  = { r.reason };
            JsValue? text = g_runtime.rt.call(g_runtime.describe, a[..]);
            io::eprintfn("error: Uncaught (in promise) %s", g_runtime.rt.as_string(text ?? { }) ?? "?");
        };
        g_runtime.exit_code = 1;
        exit_now();
        return;
    }
}


// ---- the watchdog ----


struct WatchdogState {
    JsRuntime* runtime;
    ulong* entered;
    long limit;
    bool stopped;
    Thread thread;
}

fn int watchdog(void* arg) {
    WatchdogState* state = arg;
    long period = min(max(state.limit / 4, 1_000_000), 50_000_000l);
    while (!mem::@atomic_load(state.stopped)) {
        thread::sleep_ns((NanoDuration)period);
        ulong t = mem::@atomic_load(*state.entered);
        if (t && (long)(now_ns() - t) > state.limit) state.runtime.request_interrupt();
    }
    return 0;
}

fn void start_watchdog(long ms) {
    g_runtime.time_limit_ns = ms * 1_000_000;
    WatchdogState* state = mem::new(WatchdogState);
    state.runtime = &g_runtime.engine;
    state.entered = &g_runtime.entered_ns;
    state.limit = g_runtime.time_limit_ns;
    g_runtime.watchdog_state = state;
    state.thread.create(&watchdog, state)!!;
}

fn void stop_watchdog() {
    WatchdogState* state = g_runtime.watchdog_state;
    if (!state) return;
    mem::@atomic_store(state.stopped, true);
    (void)state.thread.join();
    free(state);
    g_runtime.watchdog_state = null;
}

fn ulong now_ns() => clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

// ---- entering JS ----


fn bool begin_dispatch() {
    if (!g_runtime.time_limit_ns || mem::@atomic_load(g_runtime.entered_ns)) return false;
    mem::@atomic_store(g_runtime.entered_ns, now_ns());
    return true;
}

fn void end_dispatch(bool started) {
    if (started) mem::@atomic_store(g_runtime.entered_ns, (ulong)0);
}

fn void? checkpoint() {
    bool started = begin_dispatch();
    defer end_dispatch(started);
    return g_runtime.engine.drain_microtasks();
}

fn fault dispatch_error(fault err) {
    if (g_runtime.closing || worker_stopping()) return WORKER_STOPPED;
    if (err == boomkat::INTERRUPTED) {
        g_runtime.engine.clear_interrupt();
        if (g_runtime.worker) { worker_report_error("Worker script time limit exceeded"); worker_stop(); }
        io::eprintfn("error: script ran past the %d ms time limit", g_runtime.time_limit_ns / 1_000_000);
        return TIMED_OUT;
    }
    report_uncaught();
    return err;
}

fn void? call_js(JsValue f, JsValue[] args) {
    if (g_runtime.closing || worker_stopping()) return WORKER_STOPPED~;
    g_runtime.depth++;
    defer g_runtime.depth--;
    bool started = begin_dispatch();
    defer end_dispatch(started);
    JsValue? r = g_runtime.rt.call(f, args);
    if (catch err = r) return dispatch_error(err)~;
    g_runtime.rt.release(r);
    if (g_runtime.depth == 1) {
        if (catch err = checkpoint()) return dispatch_error(err)~;
        if (g_runtime.rejections.len()) flush_rejections();
    }
}

fn void init_guard() {
    g_runtime.rejections.init(mem);
    g_runtime.engine.set_promise_rejection_tracker(&on_rejection);
}
