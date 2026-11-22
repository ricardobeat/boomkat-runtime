// Each execution thread owns one runtime. Native tasks retain their return loop;
// queues carry owned bytes, never values or pointers into another VM's heap.
module bkr;

import boomkat;
import boomkat::hobject;
import std::thread;
import std::collections::list;
import std::collections::map;

struct RuntimeState {
    List{String} args;
    long time_limit_ms;
    String main;
    JsValue immediate_fire;
    bool immediate_armed;
    List{PendingTimer*} timer_heap;
    uint next_timer;
    UsTimer* timer_native;
    ulong timer_armed_due;
    JsValue sink_fallback;
    JsValue sink_global;
    JsValue sink_constructor;
    HObject* sink_global_object;
    HObject* sink_constructor_object;
    SinkSlot[9] sink_slots;
    JsValue[9] sink_keys;
    uint sink_shape;
    uint sink_layout_epoch;
    uint[4] sink_indices;
    bool sink_layout_valid;
    uint password_jobs;
    PendingImmediate* immediate_head;
    PendingImmediate* immediate_tail;
    ulong next_immediate;
    JsValue unhandled;
    JsValue describe;
    long time_limit_ns;
    ulong entered_ns;
    uint depth;
    void* loop;
    int holds;
    UsTimer* hold_timer;
    List{Server*} servers;
    List{Conn*} conns;
    List{uint} free_slots;
    List{Conn*} spare;
    ulong generation;
    List{ulong} http_queue;
    sz http_queue_at;
    bool http_queue_armed;
    ulong http_turn_ns;
    ulong http_prev_ns;
    JsValue[METHODS.len] methods;
    JsValue dispatch;
    JsValue handled;
    JsValue failed;
    JsValue pump;
    FastTypes fast;
    JsValue drain;
    JsValue aborted;
    JsValue http_fulfilled;
    JsValue http_rejected;
    JsValue http_then;
    JsValue http_error;
    UsContext*[2] client_ctx;
    SqlApi sql;
    void* sql_library;
    ulong sql_next_id;
    long sql_statement_class;
    JsValue[3] sql_statement_fallback;
    Permissions perms;
    DirEntry[4] dirs;
    usz dir_next;
    JsRuntime engine;
    JsContext rt;
    JsValue system_error_proto;
    HashMap{uint, JsDeferred} pending_ops;
    uint next_op;
    int exit_code;
    JsValue bk;
    List{Res*} res;
    List{uint} res_free;
    uint res_gen;
    NativeWebClass native_url;
    NativeWebClass native_response;
    NativeHeadersBlob native_headers_blob;
    NativeHeadersParse native_headers_parse;
    NativeHeadersRecord native_headers_record;
    HashMap{uint, PendingTimer*} timer_ids;
    HashMap{ulong, PendingImmediate*} immediate_ids;
    HashMap{ulong, Rejection} rejections;
    HashMap{ulong, SqlDatabase*} sql_databases;
    HashMap{ulong, SqlStatement*} sql_statements;
    WorkerThread* worker;
    bool closing;
    HashMap{ulong, WorkerThread*} workers;
    ulong next_worker;
    JsValue worker_event;
    WatchdogState* watchdog_state;
    uint http_workers;
    uint http_processes;
}

tlocal RuntimeState g_runtime = {
    .next_timer = 1,
    .next_immediate = 1,
    .sql_next_id = 1,
    .sql_statement_class = -1,
    .next_worker = 1,
    .http_workers = 1,
};
