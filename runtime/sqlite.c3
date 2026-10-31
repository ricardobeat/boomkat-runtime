// System SQLite is resolved at boot; no SQLite link dependency is introduced.
module bkr;

import boomkat;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::hstring;
import boomkat::types;
import boomkat::builtins;
import libc;
import std::collections::map;

alias SqlAuthorizer = fn CInt(void*, CInt, ZString, ZString, ZString, ZString);
alias SqlProgress = fn CInt(void*);

alias SqlOpenV2 = fn CInt(ZString, void**, CInt, ZString);
alias SqlClose = fn CInt(void*);
alias SqlPrepareV2 = fn CInt(void*, char*, CInt, void**, char**);
alias SqlStep = fn CInt(void*);
alias SqlFinalize = fn CInt(void*);
alias SqlReset = fn CInt(void*);
alias SqlClearBindings = fn CInt(void*);
alias SqlErrmsg = fn ZString(void*);
alias SqlExtendedErrcode = fn CInt(void*);
alias SqlExec = fn CInt(void*, ZString, void*, void*, char**);
alias SqlFree = fn void(void*);
alias SqlBindParameterCount = fn CInt(void*);
alias SqlBindParameterName = fn ZString(void*, CInt);
alias SqlBindNull = fn CInt(void*, CInt);
alias SqlBindInt64 = fn CInt(void*, CInt, long);
alias SqlBindDouble = fn CInt(void*, CInt, double);
alias SqlBindText = fn CInt(void*, CInt, char*, CInt, void*);
alias SqlBindBlob = fn CInt(void*, CInt, char*, CInt, void*);
alias SqlColumnCount = fn CInt(void*);
alias SqlColumnName = fn ZString(void*, CInt);
alias SqlColumnType = fn CInt(void*, CInt);
alias SqlColumnInt64 = fn long(void*, CInt);
alias SqlColumnDouble = fn double(void*, CInt);
alias SqlColumnText = fn char*(void*, CInt);
alias SqlColumnBlob = fn char*(void*, CInt);
alias SqlColumnBytes = fn CInt(void*, CInt);
alias SqlChanges = fn CInt(void*);
alias SqlGetAutocommit = fn CInt(void*);
alias SqlLastInsertRowid = fn long(void*);
alias SqlLibversion = fn ZString();
alias SqlLibversionNumber = fn CInt();
alias SqlSetAuthorizer = fn CInt(void*, SqlAuthorizer, void*);
alias SqlProgressHandler = fn void(void*, CInt, SqlProgress, void*);
alias SqlStmtStatus = fn CInt(void*, CInt, CInt);

struct SqlApi {
    SqlOpenV2 open_v2;
    SqlClose close;
    SqlPrepareV2 prepare_v2;
    SqlStep step;
    SqlFinalize finalize;
    SqlReset reset;
    SqlClearBindings clear_bindings;
    SqlErrmsg errmsg;
    SqlExtendedErrcode extended_errcode;
    SqlExec exec;
    SqlFree free;
    SqlBindParameterCount bind_parameter_count;
    SqlBindParameterName bind_parameter_name;
    SqlBindNull bind_null;
    SqlBindInt64 bind_int64;
    SqlBindDouble bind_double;
    SqlBindText bind_text;
    SqlBindBlob bind_blob;
    SqlColumnCount column_count;
    SqlColumnName column_name;
    SqlColumnType column_type;
    SqlColumnInt64 column_int64;
    SqlColumnDouble column_double;
    SqlColumnText column_text;
    SqlColumnBlob column_blob;
    SqlColumnBytes column_bytes;
    SqlChanges changes;
    SqlGetAutocommit get_autocommit;
    SqlLastInsertRowid last_insert_rowid;
    SqlLibversion libversion;
    SqlLibversionNumber libversion_number;
    SqlSetAuthorizer set_authorizer;
    SqlProgressHandler progress_handler;
    SqlStmtStatus stmt_status;
}


// Host objects carry an ID, never a borrowed statement pointer: close/finalize
// can invalidate the resource while the JavaScript object remains reachable.
fn void sql_statement_object_free(void* payload, void* user) => mem::free(payload);

fn void js_sqlite_statement_class(JsCtx ctx, void* user) {
    JsArg proto = ctx.arg(0);
    if (!proto.tv.is_object()) return ctx.throw_error(TYPE, "invalid statement prototype");
    if (g_runtime.sql_statement_class >= 0) return ctx.throw_error(TYPE, "statement class already registered");
    g_runtime.sql_statement_class = ctx.ctx.heap.register_host_class(
        (void*)&sql_statement_object_free,
        null,
        null,
        null,
        proto.tv.get_heapptr()
    );
    if (g_runtime.sql_statement_class < 0) return ctx.throw_error(ERROR, "SQLite allocation failed");
    for (uint i = 0; i < 3; i++) g_runtime.sql_statement_fallback[i] = ctx.persist(ctx.arg(i + 1))!!;
}

fn void js_sqlite_statement_object(JsCtx ctx, void* user) {
    if (g_runtime.sql_statement_class < 0) return ctx.throw_error(TYPE, "statement class is not initialized");
    SqlStatement* stmt = sql_statement(ctx);
    if (!stmt) return;
    HObject*? obj = ctx.ctx.heap.alloc_object(HOST);
    if (catch obj) return ctx.throw_error(ERROR, "SQLite allocation failed");
    ulong* id = mem::new(ulong);
    *id = stmt.id;
    (*obj.extra_ptr()).host.payload = id;
    (*obj.extra_ptr()).host.class_id = (uint)g_runtime.sql_statement_class;
    ctx.ctx.heap.set_prototype(obj, ctx.ctx.heap.host_class_at((uint)g_runtime.sql_statement_class).proto);
    JsArg result;
    result.tv.set_object(obj);
    ctx.ret(result);
}

struct SqlDatabase {
    void* handle;
    ulong id;
    ulong deadline;
    SqlStatement* statements;
}
struct SqlStatement {
    void* handle;
    ulong id;
    SqlDatabase* db;
    SqlStatement* next;
    SqlStatement* prev;
    JsValue layout;
    HString*[] keys;
    uint[] slots;
    uint shape;
    CInt reprepares;
    bool indexed_keys;
}

fn bool load_sqlite(void* library) {
    SqlApi api;
    api.open_v2 = (SqlOpenV2)libc::dlsym(library, "sqlite3_open_v2");
    if (!api.open_v2) return false;
    api.close = (SqlClose)libc::dlsym(library, "sqlite3_close");
    if (!api.close) return false;
    api.prepare_v2 = (SqlPrepareV2)libc::dlsym(library, "sqlite3_prepare_v2");
    if (!api.prepare_v2) return false;
    api.step = (SqlClose)libc::dlsym(library, "sqlite3_step");
    if (!api.step) return false;
    api.finalize = (SqlClose)libc::dlsym(library, "sqlite3_finalize");
    if (!api.finalize) return false;
    api.reset = (SqlClose)libc::dlsym(library, "sqlite3_reset");
    if (!api.reset) return false;
    api.clear_bindings = (SqlClose)libc::dlsym(library, "sqlite3_clear_bindings");
    if (!api.clear_bindings) return false;
    api.errmsg = (SqlErrmsg)libc::dlsym(library, "sqlite3_errmsg");
    if (!api.errmsg) return false;
    api.extended_errcode = (SqlClose)libc::dlsym(library, "sqlite3_extended_errcode");
    if (!api.extended_errcode) return false;
    api.exec = (SqlExec)libc::dlsym(library, "sqlite3_exec");
    if (!api.exec) return false;
    api.free = (SqlFree)libc::dlsym(library, "sqlite3_free");
    if (!api.free) return false;
    api.bind_parameter_count = (SqlClose)libc::dlsym(library, "sqlite3_bind_parameter_count");
    if (!api.bind_parameter_count) return false;
    api.bind_parameter_name = (SqlBindParameterName)libc::dlsym(library, "sqlite3_bind_parameter_name");
    if (!api.bind_parameter_name) return false;
    api.bind_null = (SqlBindNull)libc::dlsym(library, "sqlite3_bind_null");
    if (!api.bind_null) return false;
    api.bind_int64 = (SqlBindInt64)libc::dlsym(library, "sqlite3_bind_int64");
    if (!api.bind_int64) return false;
    api.bind_double = (SqlBindDouble)libc::dlsym(library, "sqlite3_bind_double");
    if (!api.bind_double) return false;
    api.bind_text = (SqlBindText)libc::dlsym(library, "sqlite3_bind_text");
    if (!api.bind_text) return false;
    api.bind_blob = (SqlBindText)libc::dlsym(library, "sqlite3_bind_blob");
    if (!api.bind_blob) return false;
    api.column_count = (SqlClose)libc::dlsym(library, "sqlite3_column_count");
    if (!api.column_count) return false;
    api.column_name = (SqlBindParameterName)libc::dlsym(library, "sqlite3_column_name");
    if (!api.column_name) return false;
    api.column_type = (SqlBindNull)libc::dlsym(library, "sqlite3_column_type");
    if (!api.column_type) return false;
    api.column_int64 = (SqlColumnInt64)libc::dlsym(library, "sqlite3_column_int64");
    if (!api.column_int64) return false;
    api.column_double = (SqlColumnDouble)libc::dlsym(library, "sqlite3_column_double");
    if (!api.column_double) return false;
    api.column_text = (SqlColumnText)libc::dlsym(library, "sqlite3_column_text");
    if (!api.column_text) return false;
    api.column_blob = (SqlColumnText)libc::dlsym(library, "sqlite3_column_blob");
    if (!api.column_blob) return false;
    api.column_bytes = (SqlBindNull)libc::dlsym(library, "sqlite3_column_bytes");
    if (!api.column_bytes) return false;
    api.changes = (SqlClose)libc::dlsym(library, "sqlite3_changes");
    if (!api.changes) return false;
    api.get_autocommit = (SqlGetAutocommit)libc::dlsym(library, "sqlite3_get_autocommit");
    if (!api.get_autocommit) return false;
    api.last_insert_rowid = (SqlLastInsertRowid)libc::dlsym(library, "sqlite3_last_insert_rowid");
    if (!api.last_insert_rowid) return false;
    api.libversion = (SqlLibversion)libc::dlsym(library, "sqlite3_libversion");
    if (!api.libversion) return false;
    api.libversion_number = (SqlLibversionNumber)libc::dlsym(library, "sqlite3_libversion_number");
    if (!api.libversion_number) return false;
    api.set_authorizer = (SqlSetAuthorizer)libc::dlsym(library, "sqlite3_set_authorizer");
    if (!api.set_authorizer) return false;
    api.progress_handler = (SqlProgressHandler)libc::dlsym(library, "sqlite3_progress_handler");
    if (!api.progress_handler) return false;
    api.stmt_status = (SqlStmtStatus)libc::dlsym(library, "sqlite3_stmt_status");
    if (!api.stmt_status) return false;
    // The binding requires SQLite 3.31 or newer.
    if (api.libversion_number() < 3031000) return false;
    g_runtime.sql = api;
    return true;
}

fn bool init_sqlite() {
    ZString[] names;
    $switch:
        $case env::DARWIN:
            names = { "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib" };
        $default:
            names = { "libsqlite3.so.0", "libsqlite3.so" };
    $endswitch
    foreach (name : names) {
        void* library = libc::dlopen(name, libc::RTLD_NOW | libc::RTLD_LOCAL);
        if (!library) continue;
        if (!load_sqlite(library)) {
            libc::dlclose(library);
            continue;
        }
        g_runtime.sql_library = library;
        g_runtime.sql_databases.init(mem);
        g_runtime.sql_statements.init(mem);
        return true;
    }
    return false;
}

// Error construction stays native: a replaced __bk.error must not re-enter
// JS and close a statement while its SQLite operation is unwinding.
fn void sql_throw(JsCtx ctx, String code, String message) {
    ctx.throw_error(ERROR, message);
    TVal error = ctx.ctx.throw_value;
    if (error.is_object()) {
        HObject* obj = error.get_heapptr();
        sql_put(ctx, obj, "code", ctx.string(code).tv);
    }
}

fn void sql_error(JsCtx ctx, SqlDatabase* db) {
    String message = g_runtime.sql.errmsg(db.handle).str_view();
    sql_throw(ctx, string::tformat("SQLITE_%d", g_runtime.sql.extended_errcode(db.handle)), message);
}

fn ulong sql_id(JsArg value) {
    double n = value.as_number() ?? 0;
    if (!(n >= 1) || n > 9007199254740991.0 || (double)(ulong)n != n) return 0;
    return (ulong)n;
}

fn SqlDatabase* sql_database(JsCtx ctx) {
    SqlDatabase* db = g_runtime.sql_databases.get(sql_id(ctx.arg(0))) ?? null;
    if (!db) ctx.throw_error(TYPE, "database is closed or invalid");
    return db;
}

fn SqlStatement* sql_statement(JsCtx ctx) {
    SqlStatement* stmt = g_runtime.sql_statements.get(sql_id(ctx.arg(0))) ?? null;
    if (!stmt) ctx.throw_error(TYPE, "statement is finalized or its database is closed");
    return stmt;
}

fn void sql_finalize(SqlStatement* stmt) {
    g_runtime.sql_statements.remove(stmt.id);
    if (stmt.prev) {
        stmt.prev.next = stmt.next;
    } else {
        stmt.db.statements = stmt.next;
    }
    if (stmt.next) stmt.next.prev = stmt.prev;
    g_runtime.sql.finalize(stmt.handle);
    sql_layout_clear(stmt);
    free(stmt);
}

fn void sql_layout_clear(SqlStatement* stmt) {
    if (!stmt.layout.is_empty()) g_runtime.rt.release(stmt.layout);
    if (stmt.keys.len) free(stmt.keys.ptr);
    if (stmt.slots.len) free(stmt.slots.ptr);
    stmt.layout = { };
    stmt.keys = { };
    stmt.slots = { };
    stmt.shape = heap::SHAPE_NONE;
}

fn bool sql_layout(JsCtx ctx, SqlStatement* stmt) {
    // step() can recompile a prepared statement after schema changes.
    CInt reprepares = g_runtime.sql.stmt_status(stmt.handle, 5, 0); // SQLITE_STMTSTATUS_REPREPARE
    if (!stmt.layout.is_empty() && stmt.reprepares == reprepares) return true;
    Heap* h         = ctx.ctx.heap;
    CInt columns    = g_runtime.sql.column_count(stmt.handle);
    HString*[] keys = mem::new_array(HString*, columns);
    uint[] slots    = mem::new_array(uint, columns);
    bool saved;
    defer if (!saved) {
        free(keys.ptr);
        free(slots.ptr);
    }
    HObject* layout = sql_object(ctx) ?? null;
    if (!layout) {
        ctx.throw_error(ERROR, "SQLite allocation failed");
        return false;
    }
    TVal undefined;
    undefined.set_undefined();
    for (CInt i = 0; i < columns; i++) {
        HString* key = h.str_intern((char[])g_runtime.sql.column_name(stmt.handle, i).str_view());
        if (!key) {
            ctx.throw_error(ERROR, "SQLite allocation failed");
            return false;
        }
        keys[i] = h.ensure_interned(key);
        if (!layout.put_prop(keys[i], undefined, hobject::PROP_FLAGS_WEC, h)) {
            ctx.throw_error(ERROR, "SQLite allocation failed");
            return false;
        }
        slots[i] = (uint)layout.find_prop_idx(keys[i], h);
    }
    JsArg value;
    value.tv.set_object(layout);
    JsValue root = ctx.persist(value) ?? { };
    if (root.is_empty()) {
        ctx.throw_error(ERROR, "SQLite allocation failed");
        return false;
    }
    sql_layout_clear(stmt);
    stmt.layout = root;
    stmt.keys = keys;
    stmt.slots = slots;
    stmt.reprepares = reprepares;
    stmt.indexed_keys = layout.flags.has_indexed_named_prop;
    Shape* shape = layout.get_shape(h);
    if (shape && !shape.dict && shape.parent != hobject::PRIVATE_SHAPE_PARENT) {
        shape.shared = true;
        stmt.shape = layout.shape_id;
    }
    saved = true;
    return true;
}

fn void sql_close(SqlDatabase* db) {
    while (db.statements) sql_finalize(db.statements);
    g_runtime.sql_databases.remove(db.id);
    g_runtime.sql.close(db.handle);
    free(db);
}

fn void close_sqlite() {
    if (!g_runtime.sql_library) return;
    @pool() {
        ulong[] ids = g_runtime.sql_databases.keys(tmem);
        foreach (id : ids) sql_close(g_runtime.sql_databases.get(id)!!);
    };
    g_runtime.sql_statements.free();
    g_runtime.sql_databases.free();
    libc::dlclose(g_runtime.sql_library);
    g_runtime.sql_library = null;
}

// ATTACH also covers VACUUM INTO. File access is limited to the checked
// database and its sidecars; SQL must not change temporary storage paths.
fn CInt sql_authorize(void* user, CInt action, ZString first, ZString second, ZString db, ZString trigger) {
    if (action == 24) return 1;
    if (action == 31 && second && second.str_view().compare_to_ignore_case("load_extension") == 0) return 1;
    if (action == 19 && first) {
        String name = first.str_view();
        if (name.compare_to_ignore_case(
            "temp_store_directory"
        ) == 0 || name.compare_to_ignore_case("data_store_directory") == 0) return 1;
        if (name.compare_to_ignore_case("temp_store") == 0 && second) return 1;
    }
    return 0;
}

fn CInt sql_progress(void* user) {
    SqlDatabase* db = user;
    if (db.deadline && now_ns() >= db.deadline) {
        g_runtime.engine.request_interrupt();
        return 1;
    }
    return 0;
}

fn void sql_deadline(SqlDatabase* db) {
    db.deadline = g_runtime.time_limit_ms > 0 ? now_ns() + (ulong)g_runtime.time_limit_ms * 1_000_000 : 0;
}

fn String? sql_string(JsCtx ctx, uint index) {
    if (!ctx.arg(index).is_string()) {
        ctx.throw_error(TYPE, "SQLite expects a string");
        return boomkat::WRONG_TYPE~;
    }
    String text = ctx.arg(index).as_string()!;
    if (text.contains("\x00")) {
        ctx.throw_error(TYPE, "SQLite strings must not contain NUL bytes");
        return boomkat::WRONG_TYPE~;
    }
    return text;
}

fn bool sql_access(JsCtx ctx, String database, bool readonly) {
    if (database == ":memory:") return true;
    String[] suffixes = { "", "-journal", "-wal", "-shm" };
    foreach (suffix : suffixes) {
        String path   = string::tformat("%s%s", database, suffix);
        // Grants apply to the normalized pathname, including existing links.
        // Validate once at open; the handle retains that access capability.
        String target = path;
        if (!check_path_location(READ, target)) {
            sql_throw(ctx, "PERMISSION_DENIED", denied_path(READ, target));
            return false;
        }
        if (!readonly && !check_path_location(WRITE, target)) {
            sql_throw(ctx, "PERMISSION_DENIED", denied_path(WRITE, target));
            return false;
        }
    }
    return true;
}

fn void js_sqlite_open(JsCtx ctx, void* user) {
    @pool() {
        String? raw = sql_string(ctx, 0);
        if (catch raw) return;
        if (!raw.len || raw.starts_with(
            "file:"
        )) return ctx.throw_error(TYPE, "use a file path or :memory:, not a SQLite URI");
        bool readonly = ctx.arg(1).as_bool() ?? false;
        String path   = raw == ":memory:" ? raw : absolute(raw);
        if (!sql_access(ctx, path, readonly)) return;
        SqlDatabase* db = mem::new(SqlDatabase);
        bool opened;
        defer if (!opened) {
            if (db.handle) g_runtime.sql.close(db.handle);
            free(db);
        }
        // All handle access stays on the loop thread: per-connection mutexes
        // add no protection here. File locks and journal durability remain on.
        CInt flags = (readonly ? 1 : 2 | 4) | 0x8000; // NOMUTEX
        if (g_runtime.sql.open_v2(path.zstr_tcopy(), &db.handle, flags, null) != 0) {
            if (db.handle) {
                sql_error(ctx, db);
            } else {
                ctx.throw_error(ERROR, "SQLite allocation failed");
            }
            return;
        }
        // Avoid implicit temp files outside the database's permission scope.
        if (g_runtime.sql.exec(
            db.handle,
            "PRAGMA temp_store=MEMORY",
            null,
            null,
            null
        ) != 0 || g_runtime.sql.set_authorizer(db.handle, &sql_authorize, db) != 0) return sql_error(ctx, db);
        db.id = g_runtime.sql_next_id++;
        g_runtime.sql.progress_handler(db.handle, 10000, &sql_progress, db);
        g_runtime.sql_databases.set(db.id, db);
        opened = true;
        ctx.ret_number((double)db.id);
    };
}

// Autocommit also detects explicit SQL transactions and nested savepoints.
fn void js_sqlite_in_transaction(JsCtx ctx, void* user) {
    SqlDatabase* db = sql_database(ctx);
    if (db) ctx.ret_bool(g_runtime.sql.get_autocommit(db.handle) == 0);
}

fn void js_sqlite_close(JsCtx ctx, void* user) {
    @pool() {
        if (try db = g_runtime.sql_databases.get(sql_id(ctx.arg(0)))) sql_close(db);
    };
}

fn void js_sqlite_exec(JsCtx ctx, void* user) {
    @pool() {
        SqlDatabase* db = sql_database(ctx);
        if (!db) return;
        String? sql = sql_string(ctx, 1);
        if (catch sql) return;
        sql_deadline(db);
        if (g_runtime.sql.exec(db.handle, sql.zstr_tcopy(), null, null, null) != 0) sql_error(ctx, db);
    };
}

fn void js_sqlite_prepare(JsCtx ctx, void* user) {
    @pool() {
        SqlDatabase* db = sql_database(ctx);
        if (!db) return;
        String? sql = sql_string(ctx, 1);
        if (catch sql) return;
        if (sql.len >= int::max) return ctx.throw_error(RANGE, "SQL is too long");
        SqlStatement* stmt = mem::new(SqlStatement);
        bool prepared;
        defer if (!prepared) {
            if (stmt.handle) g_runtime.sql.finalize(stmt.handle);
            free(stmt);
        }
        char* tail;
        sql_deadline(db);
        if (g_runtime.sql.prepare_v2(db.handle, sql.ptr, (CInt)sql.len, &stmt.handle, &tail) != 0) return sql_error(ctx, db);
        if (!stmt.handle) return ctx.throw_error(TYPE, "expected one SQL statement");
        // Parse the tail to accept comments/semicolons but reject a second statement.
        sz remaining = sql.len - (tail - sql.ptr);
        if (remaining > 0) {
            void* extra;
            char* rest;
            CInt rc = g_runtime.sql.prepare_v2(db.handle, tail, (CInt)remaining, &extra, &rest);
            if (extra) g_runtime.sql.finalize(extra);
            if (rc != 0) return sql_error(ctx, db);
            if (extra) return ctx.throw_error(
                TYPE,
                "prepare accepts one SQL statement; use exec for multiple statements"
            );
        }
        stmt.db = db;
        stmt.id = g_runtime.sql_next_id++;
        stmt.next = db.statements;
        if (stmt.next) stmt.next.prev = stmt;
        db.statements = stmt;
        g_runtime.sql_statements.set(stmt.id, stmt);
        prepared = true;
        ctx.ret_number((double)stmt.id);
    };
}

fn HObject*? sql_object(JsCtx ctx, ObjClass kind = OBJECT) {
    HObject* obj = ctx.ctx.heap.alloc_object(kind)!;
    ctx.ctx.heap.set_prototype(obj, kind == ARRAY ? ctx.ctx.heap.array_proto : null);
    return obj;
}

fn bool sql_put(JsCtx ctx, HObject* obj, String name, TVal value) {
    HString* key = ctx.ctx.heap.str_intern((char[])name);
    return key && obj.put_prop(key, value, hobject::PROP_FLAGS_WEC, ctx.ctx.heap);
}

fn JsArg? sql_integer(JsCtx ctx, long value) {
    if (value >= -9007199254740991 && value <= 9007199254740991) {
        JsArg result;
        result.tv.set_fastint_or_number(value);
        return result;
    }
    HBigInt* bigint = hbigint::hbigint_alloc(ctx.ctx.heap, (int128)value)!;
    JsArg result;
    result.tv.set_bigint(bigint);
    return result;
}

fn void js_sqlite_params(JsCtx ctx, void* user) {
    @pool() {
        SqlStatement* stmt = sql_statement(ctx);
        if (!stmt) return;
        HObject*? names = sql_object(ctx, ARRAY);
        if (catch names) return ctx.throw_error(ERROR, "SQLite allocation failed");
        CInt count = g_runtime.sql.bind_parameter_count(stmt.handle);
        *names.array_len_ptr() = (uint)count;
        for (CInt i = 0; i < count; i++) {
            ZString name = g_runtime.sql.bind_parameter_name(stmt.handle, i + 1);
            JsArg val    = name ? ctx.string(name.str_view()) : ctx.null_value();
            if (!names.set_array_idx(
                (uint)i,
                val.tv,
                ctx.ctx.heap
            )) return ctx.throw_error(ERROR, "SQLite allocation failed");
        }
        JsArg result;
        result.tv.set_object(names);
        ctx.ret(result);
    };
}

fn bool sql_bind(JsCtx ctx, SqlStatement* stmt, uint index, TVal value) {
    CInt position = (CInt)index + 1;
    CInt rc;
    if (value.is_null()) {
        rc = g_runtime.sql.bind_null(stmt.handle, position);
    } else if (value.is_boolean()) {
        rc = g_runtime.sql.bind_int64(stmt.handle, position, value.get_boolean() ? 1 : 0);
    } else if (value.is_numeric()) {
        double n = value.get_number_or_fastint();
        if (n != n || n > double::max || n < -double::max) {
            ctx.throw_error(RANGE, "SQLite numbers must be finite");
            return false;
        }
        if (n >= -9007199254740991.0 && n <= 9007199254740991.0 && (double)(long)n == n) {
            rc = g_runtime.sql.bind_int64(stmt.handle, position, (long)n);
        } else {
            rc = g_runtime.sql.bind_double(stmt.handle, position, n);
        }
    } else if (value.is_bigint()) {
        HBigInt* b = value.get_heapptr();
        if (!b.fits_int128() || b.to_int128() < (int128)long::min || b.to_int128() > (int128)long::max) {
            ctx.throw_error(RANGE, "SQLite BigInts must fit signed 64 bits");
            return false;
        }
        rc = g_runtime.sql.bind_int64(stmt.handle, position, (long)b.to_int128());
    } else if (value.is_string()) {
        String text = (JsArg) { .tv = value }.as_string() ?? "";
        if (text.len > int::max) {
            ctx.throw_error(RANGE, "SQLite text is too long");
            return false;
        }
        rc = g_runtime.sql.bind_text(stmt.handle, position, text.ptr, (CInt)text.len, (void*)usz::max);
    } else {
        JsArg arg = { .tv = value };
        if (!arg.is_bytes()) {
            ctx.throw_error(TYPE, "SQLite parameters must be null, boolean, number, BigInt, string or bytes");
            return false;
        }
        char[] bytes = arg.bytes();
        if (bytes.len > int::max) {
            ctx.throw_error(RANGE, "SQLite blob is too long");
            return false;
        }
        // A non-null pointer preserves an empty BLOB instead of binding NULL.
        rc = g_runtime.sql.bind_blob(stmt.handle, position, bytes.len ? bytes.ptr : "", (CInt)bytes.len, (void*)usz::max);
    }
    if (rc != 0) {
        sql_error(ctx, stmt.db);
        return false;
    }
    return true;
}

fn JsArg? sql_column(JsCtx ctx, SqlStatement* stmt, CInt column) {
    switch (g_runtime.sql.column_type(stmt.handle, column)) {
        case 1: return sql_integer(ctx, g_runtime.sql.column_int64(stmt.handle, column));
        case 2: return ctx.number(g_runtime.sql.column_double(stmt.handle, column));
        case 3:
            char* text = g_runtime.sql.column_text(stmt.handle, column);
            CInt len = g_runtime.sql.column_bytes(stmt.handle, column);
            if (!text && len) return boomkat::OUT_OF_MEMORY~;
            // Result data is not an identifier. Long ASCII values can avoid
            // hashing and comparing their entire contents in the intern table.
            // Copy before SQLite advances; retain the normal UTF-8 path otherwise.
            if (len >= 64 && hstring::check_is_ascii(text[:len])) {
                HString* string = hstring::hstring_alloc(ctx.ctx.heap, hstring::narrow_units(text[:len]), hstring::HASH_DEFERRED)!;
                ctx.ctx.heap.large_string_register(string);
                JsArg value;
                value.tv.set_string_borrowed(string);
                return value;
            }
            return ctx.string((String)text[:len]);
        case 4:
            char* data = g_runtime.sql.column_blob(stmt.handle, column);
            CInt len = g_runtime.sql.column_bytes(stmt.handle, column);
            if (!data && len) return boomkat::OUT_OF_MEMORY~;
            return ctx.bytes(copy_bytes(data[:len]));
        default: return ctx.null_value();
    }
}

fn void sql_execute(JsCtx ctx, SqlStatement* stmt, HObject* bindings, uint count, int mode) {
    @pool() {
        g_runtime.sql.reset(stmt.handle);
        g_runtime.sql.clear_bindings(stmt.handle);
        defer {
            g_runtime.sql.reset(stmt.handle);
            g_runtime.sql.clear_bindings(stmt.handle);
        }
        for (uint i = 0; i < count; i++) {
            TVal value = bindings ? (bindings.get_array_idx(i) ?? (TVal) { }) : ctx.arg(i).tv;
            if (!sql_bind(ctx, stmt, i, value)) return;
        }
        HObject* output;
        if (mode != 1 && mode != 2) {
            output = sql_object(ctx, ARRAY) ?? null;
            if (!output) return ctx.throw_error(ERROR, "SQLite allocation failed");
        }
        uint row_index;
        bool have_layout;
        sql_deadline(stmt.db);
        while (true) {
            CInt rc = g_runtime.sql.step(stmt.handle);
            if (rc == 101) break;
            if (rc != 100) return sql_error(ctx, stmt.db);
            if (mode == 2) continue;
            if (!have_layout) {
                if (!sql_layout(ctx, stmt)) return;
                have_layout = true;
            }
            HObject*? row = stmt.shape == heap::SHAPE_NONE ? sql_object(ctx)
                : ctx.ctx.heap.alloc_shaped_object(stmt.shape);
            if (catch row) return ctx.throw_error(ERROR, "SQLite allocation failed");
            if (stmt.shape != heap::SHAPE_NONE) {
                ctx.ctx.heap.set_prototype(row, null);
                row.flags.has_indexed_named_prop = stmt.indexed_keys;
            }
            for (CInt i = 0; i < stmt.keys.len; i++) {
                JsArg? value = sql_column(ctx, stmt, i);
                if (catch value) return ctx.throw_error(ERROR, "SQLite allocation failed");
                if (stmt.shape != heap::SHAPE_NONE) {
                    ctx.ctx.heap.store_slot_ref(row, &row.prop_values()[stmt.slots[i]], &value.tv);
                } else if (!row.put_prop(stmt.keys[i], value.tv, hobject::PROP_FLAGS_WEC, ctx.ctx.heap)) {
                    return ctx.throw_error(ERROR, "SQLite allocation failed");
                }
            }
            JsArg value;
            value.tv.set_object(row);
            if (mode == 1) return ctx.ret(value);
            if (!output.set_array_idx(
                row_index++,
                value.tv,
                ctx.ctx.heap
            )) return ctx.throw_error(ERROR, "SQLite allocation failed");
            *output.array_len_ptr() = row_index;
        }
        if (mode == 1) return; // undefined on no match
        JsArg result;
        if (mode == 2) {
            HObject*? stats = sql_object(ctx);
            if (catch stats) return ctx.throw_error(ERROR, "SQLite allocation failed");
            JsArg? rowid = sql_integer(ctx, g_runtime.sql.last_insert_rowid(stmt.db.handle));
            if (catch rowid) return ctx.throw_error(ERROR, "SQLite allocation failed");
            if (!sql_put(ctx, stats, "changes", ctx.number(g_runtime.sql.changes(stmt.db.handle))
                .tv) || !sql_put(
                    ctx,
                    stats,
                    "lastInsertRowid",
                    rowid.tv
                )) return ctx.throw_error(ERROR, "SQLite allocation failed");
            result.tv.set_object(stats);
        } else {
            result.tv.set_object(output);
        }
        ctx.ret(result);
    };
}

fn void js_sqlite_query(JsCtx ctx, void* user) {
    SqlStatement* stmt = sql_statement(ctx);
    if (!stmt) return;
    JsArg params = ctx.arg(1);
    if (!params.tv.is_object() || ((HObject*)params.tv.get_heapptr()).get_class() != ARRAY) return ctx.throw_error(
        TYPE,
        "SQLite bindings must be an array"
    );
    HObject* bindings = params.tv.get_heapptr();
    uint count        = *bindings.array_len_ptr();
    if (count != (uint)g_runtime.sql.bind_parameter_count(
        stmt.handle
    )) return ctx.throw_error(RANGE, "incorrect SQLite parameter count");
    sql_execute(ctx, stmt, bindings, count, ctx.arg(2).as_int());
}

fn void sql_native_statement(JsCtx ctx, int mode) {
    JsArg receiver = ctx.this_value();
    if (!receiver.tv.is_object()) return ctx.throw_error(TYPE, "invalid SQLite statement");
    HObject* obj = receiver.tv.get_heapptr();
    if (obj.get_class() != HOST
        || (*obj.extra_ptr()).host.class_id != (uint)g_runtime.sql_statement_class) return ctx.throw_error(
        TYPE,
        "invalid SQLite statement"
    );
    uint count = builtins::host_argc(ctx.ctx);
    // Arrays, named objects and their getters use the original validation path.
    // Do not retain a resource pointer across that JavaScript call.
    if (count == 1 && ctx.arg(0).tv.is_object()) {
        JsArg[1] args = { ctx.arg(0) };
        if (try result = ctx.call(ctx.value(g_runtime.sql_statement_fallback[mode]), args[..], receiver)) ctx.ret(result);
        return;
    }
    ulong id           = *(ulong*)(*obj.extra_ptr()).host.payload;
    SqlStatement* stmt = g_runtime.sql_statements.get(id) ?? null;
    if (!stmt) return ctx.throw_error(TYPE, "statement is finalized or its database is closed");
    if (count != (uint)g_runtime.sql.bind_parameter_count(
        stmt.handle
    )) return ctx.throw_error(RANGE, "incorrect SQLite parameter count");
    sql_execute(ctx, stmt, null, count, mode);
}
fn void js_sqlite_all(JsCtx ctx, void* user) => sql_native_statement(ctx, 0);
fn void js_sqlite_get(JsCtx ctx, void* user) => sql_native_statement(ctx, 1);
fn void js_sqlite_run(JsCtx ctx, void* user) => sql_native_statement(ctx, 2);

fn void js_sqlite_finalize(JsCtx ctx, void* user) {
    @pool() {
        if (try stmt = g_runtime.sql_statements.get(sql_id(ctx.arg(0)))) sql_finalize(stmt);
    };
}
fn void js_sqlite_version(JsCtx ctx, void* user) => ctx.ret_string(g_runtime.sql.libversion().str_view());

const Native[] SQLITE_NATIVES = {
    { "sqliteStatementClass", &js_sqlite_statement_class, 4 },
    { "sqliteStatement", &js_sqlite_statement_object, 1 },
    { "sqliteAll", &js_sqlite_all, 0 },
    { "sqliteGet", &js_sqlite_get, 0 },
    { "sqliteRun", &js_sqlite_run, 0 },
    { "sqliteOpen", &js_sqlite_open, 2 },
    { "sqliteClose", &js_sqlite_close, 1 },
    { "sqliteInTransaction", &js_sqlite_in_transaction, 1 },
    { "sqliteExec", &js_sqlite_exec, 2 },
    { "sqlitePrepare", &js_sqlite_prepare, 2 },
    { "sqliteParams", &js_sqlite_params, 1 },
    { "sqliteQuery", &js_sqlite_query, 3 },
    { "sqliteFinalize", &js_sqlite_finalize, 1 },
    { "sqliteVersion", &js_sqlite_version, 0 },
};
