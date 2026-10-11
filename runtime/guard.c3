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

// ---- unhandled rejections ----

struct Rejection {
    JsValue promise;
    JsValue reason;
}

HashMap{ulong, Rejection} g_rejections;
JsValue g_unhandled;

fn void on_rejection(JsRuntime* rt, ulong id, JsValue promise, JsValue reason, bool handled, void* udata) {
    if (handled) {
        Rejection? r = g_rejections.get(id);
        if (catch r) return;
        rt.release(r.promise);
        rt.release(r.reason);
        g_rejections.remove(id);
        return;
    }
    if (g_rejections.has_key(id)) return;
    g_rejections.set(id, { rt.persist(promise) ?? { }, rt.persist(reason) ?? { } });
}

// Rejections still unhandled once the microtasks have drained reach the
// global "unhandledrejection" event; unless a listener prevents its default,
// the process ends, as in Deno.
fn void flush_rejections() {
    while (g_rejections.len()) {
        ulong id    = g_rejections.keys(tmem)[0];
        Rejection r = g_rejections.get(id)!!;
        g_rejections.remove(id);
        defer {
            g_rt.release(r.promise);
            g_rt.release(r.reason);
        }
        JsValue[2] args    = { r.reason, r.promise };
        JsValue? prevented = g_rt.call(g_unhandled, args[..]);
        if (catch prevented) {
            report_uncaught();
            continue;
        }
        defer g_rt.release(prevented);
        if (g_rt.as_bool(prevented) ?? false) continue;
        g_rt.@scope() {
            JsValue[1] a  = { r.reason };
            JsValue? text = g_rt.call(g_describe, a[..]);
            io::eprintfn("error: Uncaught (in promise) %s", g_rt.as_string(text ?? { }) ?? "?");
        };
        g_exit_code = 1;
        exit_now();
    }
}

JsValue g_describe;

// ---- the watchdog ----

long g_time_limit_ns;
Thread g_watchdog;
ulong g_entered_ns;

fn int watchdog(void* arg) {
    long period = max(g_time_limit_ns / 4, 1_000_000);
    while (true) {
        thread::sleep_ns((NanoDuration)period);
        ulong t = mem::@atomic_load(g_entered_ns);
        if (t && (long)(now_ns() - t) > g_time_limit_ns) g_rt.request_interrupt();
    }
}

fn void start_watchdog(long ms) {
    g_time_limit_ns = ms * 1_000_000;
    g_watchdog.create(&watchdog, null)!!;
    g_watchdog.detach();
}

fn ulong now_ns() => clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

// ---- entering JS ----

uint g_depth;

fn void? call_js(JsValue f, JsValue[] args) {
    g_depth++;
    defer g_depth--;
    if (g_time_limit_ns) mem::@atomic_store(g_entered_ns, now_ns());
    JsValue? r = g_rt.call(f, args);
    if (g_time_limit_ns) mem::@atomic_store(g_entered_ns, (ulong)0);
    if (catch err = r) {
        if (err == boomkat::INTERRUPTED) {
            g_rt.clear_interrupt();
            io::eprintfn("error: script ran past the %d ms time limit", g_time_limit_ns / 1_000_000);
            return TIMED_OUT~;
        }
        report_uncaught();
        return err~;
    }
    g_rt.release(r);
    if (g_depth == 1 && g_rejections.len()) flush_rejections();
}

fn void init_guard() {
    g_rejections.init(mem);
    g_rt.set_promise_rejection_tracker(&on_rejection);
}