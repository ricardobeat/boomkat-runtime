// Each worker owns its VM and loop. Cross-thread queues contain owned native
// storage; the only foreign VM operation is its atomic interrupt request.
module bkr;

import boomkat;
import boomkat::types;
import boomkat::hobject;
import boomkat::builtins;
import std::thread;
import std::collections::map;
import std::io;
import std::os::posix;

const usz WORKER_QUEUE_BYTES   = 64 * 1024 * 1024;
const usz WORKER_MESSAGE_BYTES = 16 * 1024 * 1024;
uint g_worker_live;
faultdef WORKER_LIMIT, WORKER_CREATE_FAILED;

fn bool worker_reserve_slot() {
    uint count = mem::@atomic_load(g_worker_live);
    while (true) {
        if (count >= 64) return false;
        uint observed = mem::compare_exchange(&g_worker_live, count, count + 1u);
        if (observed == count) return true;
        count = observed;
    }
}

fn void worker_release_slot() {
    uint count = mem::@atomic_load(g_worker_live);
    while (mem::compare_exchange(&g_worker_live, count, count - 1u) != count) {
        count = mem::@atomic_load(g_worker_live);
    }
}


struct WorkerPacket {
    WorkerPacket* next;
    String text;
    char[][] buffers;
    usz bytes;
    int kind;
}

struct WorkerThread {
    ulong id;
    Server* http_server;
    String[] arguments;
    String path;
    String name;
    Permissions permissions;
    long time_limit;
    Thread thread;
    Mutex lock;
    void* parent_loop;
    void* loop;
    JsRuntime* runtime;
    WorkerPacket* inbox_head;
    WorkerPacket* inbox_tail;
    WorkerPacket* outbox_head;
    WorkerPacket* outbox_tail;
    usz inbox_bytes;
    usz outbox_bytes;
    bool inbox_armed;
    bool outbox_armed;
    bool stopping;
    bool finished;
    bool errored;
}

fn void worker_packet_free(WorkerPacket* p) {
    free(p.text.ptr);
    foreach (bytes : p.buffers) free(bytes.ptr);
    free(p.buffers.ptr);
    free(p);
}

fn void worker_packet_list_free(WorkerPacket* p) {
    while (p) {
        WorkerPacket* next = p.next;
        worker_packet_free(p);
        p = next;
    }
}

fn void worker_append(WorkerPacket** head, WorkerPacket** tail, WorkerPacket* p) {
    if (*tail) {
        (*tail).next = p;
    } else {
        *head = p;
    }
    *tail = p;
}

fn void worker_emit(ulong id, int kind, WorkerPacket* packet = null) {
    if (g_runtime.closing) return;
    g_runtime.rt.@scope() {
        JsValue[] args = mem::temp_array(JsValue, 4);
        args[0] = g_runtime.rt.number((double)id) ?? { };
        args[1] = g_runtime.rt.number(kind) ?? { };
        args[2] = g_runtime.rt.string(packet ? packet.text : "") ?? { };
        args[3] = g_runtime.rt.array() ?? { };
        if (packet) {
            foreach (i, bytes : packet.buffers) {
                JsValue value = bytes_value(copy_bytes(bytes)) ?? { };
                (void)g_runtime.rt.set_index(args[3], (uint)i, value);
            }
        }
        (void)call_js(g_runtime.worker_event, args);
    };
}

fn void worker_deliver_parent(void* arg) {
    WorkerThread* w = arg;
    WorkerPacket* packets;
    bool finished;
    w.lock.@in_lock() {
        packets = w.outbox_head;
        w.outbox_head = null;
        w.outbox_tail = null;
        w.outbox_bytes = 0;
        w.outbox_armed = false;
        finished = w.finished;
    };
    while (packets) {
        WorkerPacket* p = packets;
        packets = p.next;
        if (w.http_server) {
            if (p.kind == 1 && !w.http_server.stopped) {
                io::eprintfn("error: HTTP worker failed: %s", p.text);
                g_runtime.exit_code = 1;
                exit_now();
            }
        } else {
            worker_emit(w.id, p.kind, p);
        }
        worker_packet_free(p);
    }
    if (!finished) return;
    (void)w.thread.join();
    if (w.http_server) {
        w.http_server.pool_live--;
        if (!w.http_server.stopped) {
            io::eprintn("error: HTTP worker exited unexpectedly");
            g_runtime.exit_code = 1;
            exit_now();
        }
    }
    foreach (value : w.arguments) free(value.ptr);
    free(w.arguments.ptr);
    ulong id = w.id;
    g_runtime.workers.remove(id);
    w.lock.destroy();
    free(w.path.ptr);
    free(w.name.ptr);
    free(w);
    worker_release_slot();
    unhold();
    worker_emit(id, 2);
}

fn void worker_arm_parent(WorkerThread* w) {
    if (w.outbox_armed) return;
    w.outbox_armed = true;
    uws_loop_defer(w.parent_loop, &worker_deliver_parent, w);
}

fn void worker_report_error(String message) {
    WorkerThread* w = g_runtime.worker;
    if (!w) return;
    w.lock.@in_lock() {
        if (w.errored || w.stopping) return;
        w.errored = true;
        WorkerPacket* p = mem::new(WorkerPacket);
        p.text = message.copy(mem);
        p.kind = 1;
        worker_append(&w.outbox_head, &w.outbox_tail, p);
        worker_arm_parent(w);
    };
}

fn void worker_deliver_child(void* arg) {
    WorkerThread* w = arg;
    WorkerPacket* packets;
    w.lock.@in_lock() {
        packets = w.inbox_head;
        w.inbox_head = null;
        w.inbox_tail = null;
        w.inbox_bytes = 0;
        w.inbox_armed = false;
    };
    while (packets) {
        WorkerPacket* p = packets;
        packets = p.next;
        worker_emit(0, 0, p);
        worker_packet_free(p);
    }
}

fn void worker_request_stop(WorkerThread* w) {
    w.lock.@in_lock() {
        if (w.stopping || w.finished) return;
        w.stopping = true;
        if (w.runtime) w.runtime.request_interrupt();
        if (w.loop) uws_loop_defer(w.loop, &worker_stop_deferred, w);
    };
}

fn void worker_stop_deferred(void* arg) => worker_stop();

fn void worker_http_poll_idle(void* arg) {
    if (g_runtime.closing) return;
    foreach (server : g_runtime.servers) {
        if (!uws_app_pool_idle(server.app)) {
            (void)timer_start(1, &worker_http_poll_idle, null);
            return;
        }
    }
    worker_stop();
}

fn void worker_http_drain(void* arg) {
    if (g_runtime.closing) return;
    foreach (server : g_runtime.servers) {
        server.stopped = true;
        uws_app_stop(server.app, 0);
    }
    worker_http_poll_idle(null);
}

fn void worker_request_http_drain(WorkerThread* w) {
    w.lock.@in_lock() {
        if (w.stopping || w.finished) return;
        if (w.loop) {
            uws_loop_defer(w.loop, &worker_http_drain, w);
        } else {
            w.stopping = true;
        } // no request has reached an unbooted worker
    };
}

fn void worker_stop() {
    if (!g_runtime.worker || g_runtime.closing) return;
    g_runtime.closing = true;
    WorkerThread* w = g_runtime.worker;
    w.lock.@in_lock() {
        w.stopping = true;
    };
    // Resource callbacks can still hold native cursors into these tables.
    // Tear them down on a later turn, after the current callback unwinds.
    uws_loop_defer(g_runtime.loop, &worker_shutdown_resources, null);
}

fn void worker_shutdown_resources(void* arg) {
    stop_worker_resources();
    unhold(); // in-flight native jobs retain their own holds
}

fn bool worker_stopping() {
    WorkerThread* w = g_runtime.worker;
    if (!w) return false;
    bool stopped;
    w.lock.@in_lock() {
        stopped = w.stopping;
    };
    return stopped;
}

fn void clone_permissions(Permissions* dst) {
    dst.prompt = false;
    dst.locked = true;
    foreach (i, &out : dst.grants) {
        Grant* source = &g_runtime.perms.grants[i];
        out.all = source.all;
        out.allow.init(mem);
        out.deny.init(mem);
        out.location_allow.init(mem);
        out.location_deny.init(mem);
        foreach (s : source.allow) out.allow.push(s.copy(mem));
        foreach (s : source.deny) out.deny.push(s.copy(mem));
        foreach (s : source.location_allow) out.location_allow.push(s.copy(mem));
        foreach (s : source.location_deny) out.location_deny.push(s.copy(mem));
    }
}

fn void free_permissions(Permissions* permissions) {
    foreach (&g : permissions.grants) {
        foreach (s : g.allow) free(s.ptr);
        foreach (s : g.deny) free(s.ptr);
        foreach (s : g.location_allow) free(s.ptr);
        foreach (s : g.location_deny) free(s.ptr);
        g.allow.free();
        g.deny.free();
        g.location_allow.free();
        g.location_deny.free();
    }
}

fn void free_worker_permissions() {
    free_permissions(&g_runtime.perms);
    foreach (&entry : g_runtime.dirs) {
        if (entry.dir.len) {
            free(entry.dir.ptr);
            free(entry.real.ptr);
        }
    }
}

fn int worker_thread_main(void* arg) {
    WorkerThread* w = arg;
    @pool_init(mem, 64 * 1024) {
        g_runtime.worker = w;
        g_runtime.perms = w.permissions;
        g_runtime.main = w.path;
        g_runtime.args.init(mem);
        foreach (value : w.arguments) g_runtime.args.push(value);
        bool booted;
        if (catch boot_error = boot()) {
            worker_report_error(g_runtime.rt.last_error());
        } else {
            booted = true;
            hold();
            bool stopping;
            w.lock.@in_lock() {
                w.loop = g_runtime.loop;
                w.runtime = &g_runtime.engine;
                stopping = w.stopping;
                if (w.inbox_head && !stopping) {
                    w.inbox_armed = true;
                    uws_loop_defer(w.loop, &worker_deliver_child, w);
                }
            };
            if (stopping) {
                worker_stop();
            } else {
                if (w.time_limit) start_watchdog(w.time_limit);
                if (try source = file::load(mem, w.path)) {
                    g_runtime.depth++;
                    if (g_runtime.time_limit_ns) mem::@atomic_store(g_runtime.entered_ns, now_ns());
                    JsValue? ns = g_runtime.rt.eval_module((String)source, w.path);
                    if (g_runtime.time_limit_ns) mem::@atomic_store(g_runtime.entered_ns, 0ul);
                    g_runtime.depth--;
                    free(source.ptr);
                    if (catch module_error = ns) {
                        bool stopped;
                        w.lock.@in_lock() {
                            stopped = w.stopping;
                        };
                        if (!stopped) worker_report_error(g_runtime.rt.last_error());
                        worker_stop();
                    } else {
                        g_runtime.rt.release(ns);
                        if (catch checkpoint()) worker_report_error(g_runtime.rt.last_error());
                        if (!g_runtime.closing) flush_rejections();
                    }
                } else {
                    worker_report_error("Cannot read worker module");
                    worker_stop();
                }
            }
            uws_loop_run();
        }
        stop_watchdog();
        w.lock.@in_lock() {
            w.runtime = null;
            w.loop = null;
            w.stopping = true;
        };
        if (booted) free_worker_resources();
        close_sqlite();
        g_runtime.rt.destroy();
        g_runtime.engine.destroy();
        free_worker_permissions();
        g_runtime.args.free();
        w.lock.@in_lock() {
            worker_packet_list_free(w.inbox_head);
            w.inbox_head = null;
            w.inbox_tail = null;
            w.finished = true;
            worker_arm_parent(w);
        };
    };
    return 0;
}

fn WorkerThread*? start_worker(String filename, String name, Server* server = null) {
    if (!worker_reserve_slot()) return WORKER_LIMIT~;
    WorkerThread* w = mem::new(WorkerThread);
    w.id = g_runtime.next_worker++;
    w.path = filename.copy(mem);
    w.name = name.copy(mem);
    w.parent_loop = g_runtime.loop;
    w.time_limit = g_runtime.time_limit_ms;
    w.http_server = server;
    if (server) {
        w.arguments = mem::new_array(String, g_runtime.args.len());
        foreach (i, value : g_runtime.args) w.arguments[i] = value.copy(mem);
    }
    clone_permissions(&w.permissions);
    w.lock.init()!!;
    if (catch w.thread.create(&worker_thread_main, w)) {
        free_permissions(&w.permissions);
        foreach (value : w.arguments) free(value.ptr);
        free(w.arguments.ptr);
        w.lock.destroy();
        free(w.path.ptr);
        free(w.name.ptr);
        free(w);
        worker_release_slot();
        return WORKER_CREATE_FAILED~;
    }
    g_runtime.workers.set(w.id, w);
    hold();
    return w;
}

fn void js_worker_start(JsCtx ctx, void* user) {
    @pool() {
        String requested = ctx.arg(0).as_string() ?? "";
        if (!requested.len || requested.contains(
            "://"
        )) return ctx.throw_error(TYPE, "Worker requires a local module path");
        String filename = absolute(requested, g_runtime.main[:g_runtime.main.rindex_of_char('/')!!]);
        if (!check_path(
            READ,
            canonical(filename)
        )) return ctx.throw_coded("PERMISSION_DENIED", "Worker module read access denied");
        if (g_runtime.closing) return ctx.throw_error(ERROR, "Runtime is closing");
        WorkerThread*? worker = start_worker(filename, ctx.arg(1).as_string() ?? "");
        if (catch err = worker) return ctx.throw_error(
            err == WORKER_LIMIT ? RANGE : ERROR,
            err == WORKER_LIMIT ? "Too many workers" : "Cannot create worker thread"
        );
        ctx.ret_number((double)worker.id);
    };
}

fn HObject* worker_array(JsCtx ctx, uint index) {
    JsArg arg = ctx.arg(index);
    if (!arg.tv.is_object()) return null;
    HObject* object = arg.tv.get_heapptr();
    return object.get_class() == ARRAY ? object : null;
}

fn bool worker_validate_transfers(JsCtx ctx, HObject* list) {
    if (!list) {
        ctx.throw_error(TYPE, "Invalid transfer list");
        return false;
    }
    uint count = *list.array_len_ptr();
    if (count > 32768) {
        ctx.throw_error(RANGE, "Too many transfers");
        return false;
    }
    HashMap{uptr, bool} seen;
    seen.init(mem);
    defer seen.free();
    for (uint i = 0; i < count; i++) {
        TVal value = list.get_array_idx(i) ?? (TVal) { };
        if (!value.is_object()) {
            ctx.throw_error(TYPE, "Invalid transferable");
            return false;
        }
        HObject* buffer = value.get_heapptr();
        if (buffer.get_class() != ARRAYBUFFER || buffer.extra_ptr()
            .ab.is_shared || buffer.extra_ptr().ab.immutable || buffer.extra_ptr().ab.byte_length == 0xFFFFFFFFu) {
            ctx.throw_error(TYPE, "Invalid transferable buffer");
            return false;
        }
        uptr identity = (uptr)buffer;
        if (seen.has_key(identity)) {
            ctx.throw_error(TYPE, "Duplicate transferable");
            return false;
        }
        seen.set(identity, true);
    }
    return true;
}

fn void worker_detach_transfers(HObject* list) {
    for (uint i = 0; i < *list.array_len_ptr(); i++) {
        TVal value = list.get_array_idx(i)!!;
        builtins::arraybuffer_detach(g_runtime.rt.rt.heap, value.get_heapptr());
    }
}

fn void js_worker_detach(JsCtx ctx, void* user) {
    HObject* list = worker_array(ctx, 0);
    if (worker_validate_transfers(ctx, list)) worker_detach_transfers(list);
}

fn WorkerPacket* worker_packet(JsCtx ctx) {
    HObject* buffers = worker_array(ctx, 2);
    if (!buffers) {
        ctx.throw_error(TYPE, "Invalid message buffers");
        return null;
    }
    String text = ctx.arg(1).as_string() ?? "";
    uint count  = *buffers.array_len_ptr();
    if (text.len > WORKER_MESSAGE_BYTES || count > 32768) {
        ctx.throw_error(RANGE, "Worker message is too large");
        return null;
    }
    WorkerPacket* p = mem::new(WorkerPacket);
    p.text = text.copy(mem);
    p.bytes = text.len;
    p.buffers = mem::new_array(char[], count);
    for (uint i = 0; i < count; i++) {
        JsArg arg;
        arg.tv = buffers.get_array_idx(i) ?? (TVal) { };
        if (!arg.is_bytes()) {
            worker_packet_free(p);
            ctx.throw_error(TYPE, "Invalid message buffer");
            return null;
        }
        char[] bytes = arg.bytes();
        if (bytes.len > WORKER_MESSAGE_BYTES - p.bytes) {
            worker_packet_free(p);
            ctx.throw_error(RANGE, "Worker message is too large");
            return null;
        }
        p.buffers[i] = copy_bytes(bytes);
        p.bytes += bytes.len;
    }
    return p;
}

fn void js_worker_send(JsCtx ctx, void* user) {
    ulong id        = (ulong)(ctx.arg(0).as_number() ?? 0);
    WorkerThread* w = id ? g_runtime.workers.get(id) ?? null : g_runtime.worker;
    if (!w) return;
    HObject* transfers = worker_array(ctx, 3);
    if (!worker_validate_transfers(ctx, transfers)) return;
    WorkerPacket* p = worker_packet(ctx);
    if (!p) return;
    w.lock.@in_lock() {
        if (w.stopping || w.finished) {
            worker_packet_free(p);
            return;
        }
        usz bytes = id ? w.inbox_bytes : w.outbox_bytes;
        if (p.bytes > WORKER_QUEUE_BYTES - bytes) {
            worker_packet_free(p);
            return ctx.throw_error(RANGE, "Worker message queue is full");
        }
        worker_detach_transfers(transfers);
        if (id) {
            worker_append(&w.inbox_head, &w.inbox_tail, p);
            w.inbox_bytes += p.bytes;
            if (w.loop && !w.inbox_armed) {
                w.inbox_armed = true;
                uws_loop_defer(w.loop, &worker_deliver_child, w);
            }
        } else {
            worker_append(&w.outbox_head, &w.outbox_tail, p);
            w.outbox_bytes += p.bytes;
            worker_arm_parent(w);
        }
    };
}

fn void js_worker_terminate(JsCtx ctx, void* user) {
    if (try w = g_runtime.workers.get((ulong)(ctx.arg(0).as_number() ?? 0))) worker_request_stop(w);
}

fn void js_worker_close(JsCtx ctx, void* user) {
    if (!g_runtime.worker) return;
    // Self-close finishes the current task; parent termination additionally interrupts JS.
    uws_loop_defer(g_runtime.loop, &worker_stop_deferred, g_runtime.worker);
}

fn void js_worker_is_worker(JsCtx ctx, void* user) => ctx.ret_bool(g_runtime.worker != null);
fn void js_worker_name(JsCtx ctx, void* user) => ctx.ret_string(g_runtime.worker ? g_runtime.worker.name : "");

fn String worker_view_type(ObjClass cls) {
    switch (cls) {
        case INT8ARRAY: return "Int8Array";
        case UINT8ARRAY: return "Uint8Array";
        case UINT8CLAMPEDARRAY: return "Uint8ClampedArray";
        case INT16ARRAY: return "Int16Array";
        case UINT16ARRAY: return "Uint16Array";
        case INT32ARRAY: return "Int32Array";
        case UINT32ARRAY: return "Uint32Array";
        case FLOAT16ARRAY: return "Float16Array";
        case FLOAT32ARRAY: return "Float32Array";
        case FLOAT64ARRAY: return "Float64Array";
        case BIGINT64ARRAY: return "BigInt64Array";
        case BIGUINT64ARRAY: return "BigUint64Array";
        case DATAVIEW: return "DataView";
        default: return "";
    }
}

fn void js_worker_info(JsCtx ctx, void* user) {
    Heap* h      = ctx.ctx.heap;
    HObject* out = h.alloc_object(OBJECT) ?? null;
    if (!out) return ctx.throw_error(ERROR, "Clone allocation failed");
    h.set_prototype(out, null);
    JsArg result;
    result.tv.set_object(out);
    String kind = "unsupported";
    JsArg value = ctx.arg(0);
    if (value.tv.is_object()) {
        HObject* object = value.tv.get_heapptr();
        ObjClass cls    = object.get_class();
        switch (cls) {
            case OBJECT: kind = "object";
            case ARRAY: kind = "array";
            case MAP: kind = "map";
            case SET: kind = "set";
            case DATE: kind = "date";
            case REGEXP: kind = "regexp";
            case ERROR: kind = "error";
            case ARRAYBUFFER:
                if (!object.extra_ptr().ab.is_shared && object.extra_ptr().ab.byte_length != 0xFFFFFFFFu) {
                    kind = "buffer";
                    (void)ctx.set_prop(result, "length", ctx.number(object.extra_ptr().ab.byte_length));
                    (void)ctx.set_prop(result, "transferable", ctx.boolean(!object.extra_ptr().ab.immutable));
                    (void)ctx.set_prop(result, "resizable", ctx.boolean(object.extra_ptr().ab.resizable));
                    (void)ctx.set_prop(result, "maxLength", ctx.number(object.extra_ptr().ab.max_byte_length));
                    (void)ctx.set_prop(result, "immutable", ctx.boolean(object.extra_ptr().ab.immutable));
                }
            default:
                String type = worker_view_type(cls);
                if (type.len) {
                    HObject* buffer = object.extra_ptr().view.buffer;
                    if (buffer && !buffer.extra_ptr().ab.is_shared && !builtins::view_is_out_of_bounds(object)) {
                        kind = "view";
                        JsArg buffer_arg;
                        buffer_arg.tv.set_object(buffer);
                        (void)ctx.set_prop(result, "buffer", buffer_arg);
                        (void)ctx.set_prop(result, "type", ctx.string(type));
                        (void)ctx.set_prop(result, "offset", ctx.number(object.extra_ptr().view.byte_offset));
                        (void)ctx.set_prop(result, "length", ctx.number(builtins::view_effective_byte_length(object)));
                        (void)ctx.set_prop(result, "tracking", ctx.boolean(object.extra_ptr().view.length_tracking));
                    }
                }
        }
    }
    (void)ctx.set_prop(result, "kind", ctx.string(kind));
    ctx.ret(result);
}

fn void js_worker_copy_buffer(JsCtx ctx, void* user) {
    JsArg arg = ctx.arg(0);
    if (!arg.tv.is_object()) return ctx.throw_error(TYPE, "Not an ArrayBuffer");
    HObject* buffer = arg.tv.get_heapptr();
    if (buffer.get_class() != ARRAYBUFFER || buffer.extra_ptr()
        .ab.is_shared || buffer.extra_ptr()
            .ab.byte_length == 0xFFFFFFFFu) return ctx.throw_error(TYPE, "Invalid ArrayBuffer");
    if (buffer.extra_ptr()
        .ab.byte_length > WORKER_MESSAGE_BYTES) return ctx.throw_error(RANGE, "Worker buffer is too large");
    ctx.ret_bytes(copy_bytes(arg.bytes()));
}

fn void js_worker_fill_buffer(JsCtx ctx, void* user) {
    JsArg dst = ctx.arg(0);
    JsArg src = ctx.arg(1);
    if (!dst.tv.is_object() || !src.is_bytes()) return ctx.throw_error(TYPE, "Invalid clone buffer");
    HObject* buffer = dst.tv.get_heapptr();
    if (buffer.get_class() != ARRAYBUFFER || buffer.extra_ptr()
        .ab.is_shared || buffer.extra_ptr()
            .ab.immutable || buffer.extra_ptr().ab.byte_length == 0xFFFFFFFFu || dst.bytes().len != src.bytes().len) {
        return ctx.throw_error(TYPE, "Invalid clone buffer");
    }
    char[] bytes = dst.bytes();
    if (bytes.len) bytes[..] = src.bytes()[..];
    if (ctx.arg(2).as_bool() ?? false) {
        if (buffer.extra_ptr().ab.resizable) return ctx.throw_error(TYPE, "Invalid immutable clone buffer");
        buffer.extra_ptr().ab.immutable = true;
    }
}

const Native[] WORKER_NATIVES = {
    { "workerStart", &js_worker_start, 2 },
    { "workerSend", &js_worker_send, 4 },
    { "workerTerminate", &js_worker_terminate, 1 },
    { "workerClose", &js_worker_close, 0 },
    { "workerIsWorker", &js_worker_is_worker, 0 },
    { "workerName", &js_worker_name, 0 },
    { "workerInfo", &js_worker_info, 1 },
    { "workerCopyBuffer", &js_worker_copy_buffer, 1 },
    { "workerFillBuffer", &js_worker_fill_buffer, 3 },
    { "workerDetach", &js_worker_detach, 1 },
};

extern fn void uws_app_free(UwsApp* app);
extern fn void us_socket_context_free(CInt ssl, UsContext* ctx);

fn void stop_worker_resources() {
    @pool() {
        ulong[] ids = g_runtime.workers.keys(tmem);
        foreach (id : ids) if (try w = g_runtime.workers.get(id)) worker_request_stop(w);
    };
    if (g_runtime.timer_native) {
        timer_cancel(g_runtime.timer_native);
        g_runtime.timer_native = null;
    }
    foreach (t : g_runtime.timer_heap) timer_free(t);
    g_runtime.timer_heap.clear();
    g_runtime.timer_ids.clear();
    PendingImmediate* immediate = g_runtime.immediate_head;
    g_runtime.immediate_head = null;
    g_runtime.immediate_tail = null;
    while (immediate) {
        PendingImmediate* next = immediate.next;
        immediate_free(immediate);
        immediate = next;
    }
    g_runtime.immediate_ids.clear();
    foreach (server : g_runtime.servers) {
        server.stopped = true;
        uws_app_stop(server.app, 1);
    }
    for (sz i = 0; i < g_runtime.res.len(); i++) {
        Res* res = g_runtime.res[i];
        if (!res) continue;
        if (res.kind == PIPE && res.pid > 0) (void)posix::kill(res.pid, 15);
        close_resource(res);
    }
}

fn void worker_free_static(Static* response) {
    if (response.headers.len) free(response.headers.ptr);
    if (response.status_line.len) free(response.status_line.ptr);
    if (response.status_text.len) free(response.status_text.ptr);
    if (response.blob.len) free(response.blob.ptr);
    if (response.body.len) free(response.body.ptr);
}

fn void free_worker_resources() {
    foreach (server : g_runtime.servers) {
        uws_app_free(server.app);
        @pool() {
            String[] paths = server.statics.keys(tmem);
            foreach (key : paths) {
                Static response = server.statics.get(key)!!;
                worker_free_static(&response);
                free(key.ptr);
            }
        };
        server.statics.free();
        foreach (route : server.routes) {
            if (route.fixed) worker_free_static(&route.response);
            free(route.keys.ptr);
            free(route);
        }
        free(server.hostname.ptr);
        server.routes.free();
        free(server);
    }
    foreach (conn : g_runtime.conns) if (conn) conn_free(conn);
    foreach (conn : g_runtime.spare) free(conn);
    g_runtime.servers.free();
    g_runtime.conns.free();
    g_runtime.spare.free();
    g_runtime.free_slots.free();
    g_runtime.http_queue.free();
    for (sz i = 0; i < g_runtime.res.len(); i++) {
        Res* res = g_runtime.res[i];
        if (!res) continue;
        res.inbox.free();
        res.outbox.free();
        if (res.backlog.is_initialized()) res.backlog.free();
        if (res.host.len) free(res.host.ptr);
        free(res);
    }
    g_runtime.res.free();
    g_runtime.res_free.free();
    for (CInt ssl = 0; ssl < 2; ssl++) {
        if (g_runtime.client_ctx[ssl]) us_socket_context_free(ssl, g_runtime.client_ctx[ssl]);
    }
    g_runtime.timer_heap.free();
    g_runtime.timer_ids.free();
    g_runtime.immediate_ids.free();
    foreach (op : g_runtime.pending_ops.values(tmem)) g_runtime.rt.release_deferred(op);
    g_runtime.pending_ops.free();
    g_runtime.rejections.free();
    g_runtime.workers.free();
}
