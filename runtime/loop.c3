// The event loop is uSockets, owned by uWS on the main thread. Blocking work
// (files, DNS, waiting on children) runs on a small thread pool and posts
// its completion back through uws_loop_defer.
module bkr;

import std::thread;
import std::collections::list;

typedef UsTimer = void;
alias Callback = fn void(void* user);
alias UsTimerCb = fn void(UsTimer* t);

extern fn void* uws_loop();
extern fn void uws_loop_run();
extern fn void uws_loop_defer(void* loop, Callback cb, void* user);

extern fn UsTimer* us_create_timer(void* loop, CInt fallthrough, CUInt ext_size);
extern fn void* us_timer_ext(UsTimer* t);
extern fn void us_timer_set(UsTimer* t, UsTimerCb cb, CInt ms, CInt repeat_ms);
extern fn void uws_timer_set_ns(UsTimer* t, UsTimerCb cb, ulong ns);
extern fn void us_timer_close(UsTimer* t);

void* g_loop;

// ---- timers ----

struct TimerExt {
    Callback cb;
    void* user;
}

fn void timer_fired(UsTimer* t) {
    TimerExt e = *(TimerExt*)us_timer_ext(t);
    us_timer_close(t);
    e.cb(e.user);
}

// One-shot. The handle is valid until the callback starts or it is cancelled.
fn UsTimer* timer_start(long ms, Callback cb, void* user) {
    UsTimer* t = us_create_timer(g_loop, 0, TimerExt::size);
    *(TimerExt*)us_timer_ext(t) = { cb, user };
    // uSockets reads 0 as disarmed.
    us_timer_set(t, &timer_fired, (CInt)max(1, min(ms, (long)int::max)), 0);
    return t;
}

// Precise one-shot for JS deadlines, including deadlines already overdue.
fn UsTimer* timer_start_ns(ulong ns, Callback cb, void* user) {
    UsTimer* t = us_create_timer(g_loop, 0, TimerExt::size);
    *(TimerExt*)us_timer_ext(t) = { cb, user };
    uws_timer_set_ns(t, &timer_fired, max(ns, 1ul));
    return t;
}

fn void timer_cancel(UsTimer* t) => us_timer_close(t);

// ---- keeping the loop alive ----

// uSockets returns from run once nothing but fallthrough polls remain, and
// the cross-thread wakeup is one. A pending pool task holds this timer so the
// loop waits for it.
int g_holds;
UsTimer* g_hold_timer;

fn void hold_tick(UsTimer* t) {
}

fn void hold() {
    if (g_holds++) return;
    g_hold_timer = us_create_timer(g_loop, 0, 0);
    us_timer_set(g_hold_timer, &hold_tick, 1 << 30, 1 << 30);
}

fn void unhold() {
    if (--g_holds) return;
    us_timer_close(g_hold_timer);
    g_hold_timer = null;
}

// ---- thread pool ----

alias TaskFn = fn void(Task* t);

// `work` runs on a pool thread, `done` back on the loop. A task is owned by
// whoever submitted it; `done` is where it is usually freed.
struct Task {
    TaskFn work;
    TaskFn done;
    Task* next;
}

const POOL_THREADS = 16;

struct Pool {
    Mutex lock;
    ConditionVariable ready;
    Task* head;
    Task* tail;
    bool started;
    Thread[POOL_THREADS] threads;
}

Pool g_pool;

fn void task_done(void* user) {
    Task* t = user;
    unhold();
    @pool() {
        t.done(t);
    };
}

fn int pool_thread(void* arg) {
    @pool_init(mem, 64 * 1024) {
        while (true) {
            Task* t;
            g_pool.lock.@in_lock() {
                while (!g_pool.head) g_pool.ready.wait(&g_pool.lock);
                t = g_pool.head;
                g_pool.head = t.next;
                if (!g_pool.head) g_pool.tail = null;
            };
            @pool() {
                t.work(t);
            };
            uws_loop_defer(g_loop, &task_done, t);
        }
    };
}

fn void submit(Task* t) {
    if (!g_pool.started) {
        g_pool.lock.init()!!;
        g_pool.ready.init()!!;
        foreach (&th : g_pool.threads) {
            th.create(&pool_thread, null)!!;
            th.detach();
        }
        g_pool.started = true;
    }
    hold();
    t.next = null;
    g_pool.lock.@in_lock() {
        if (g_pool.tail) {
            g_pool.tail.next = t;
        } else {
            g_pool.head = t;
        }
        g_pool.tail = t;
    };
    g_pool.ready.signal();
}
