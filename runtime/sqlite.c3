// System SQLite is resolved at boot; no SQLite link dependency is introduced.
module bkr;

import boomkat;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::types;
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
alias SqlLastInsertRowid = fn long(void*);
alias SqlLibversion = fn ZString();
alias SqlLibversionNumber = fn CInt();
alias SqlSetAuthorizer = fn CInt(void*, SqlAuthorizer, void*);
alias SqlProgressHandler = fn void(void*, CInt, SqlProgress, void*);

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
    SqlLastInsertRowid last_insert_rowid;
    SqlLibversion libversion;
    SqlLibversionNumber libversion_number;
    SqlSetAuthorizer set_authorizer;
    SqlProgressHandler progress_handler;
}

SqlApi g_sql;
void* g_sql_library;
HashMap{ulong, SqlDatabase*} g_sql_databases;
HashMap{ulong, SqlStatement*} g_sql_statements;
ulong g_sql_next_id = 1;

struct SqlDatabase {
    void* handle;
    ulong id;
    ulong deadline;
    SqlStatement* statements;
    String path;
    bool readonly;
}
struct SqlStatement {
    void* handle;
    ulong id;
    SqlDatabase* db;
    SqlStatement* next;
    SqlStatement* prev;
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
    // NOFOLLOW is supported from 3.31 onward.
    if (api.libversion_number() < 3031000) return false;
    g_sql = api;
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
        g_sql_library = library;
        g_sql_databases.init(mem);
        g_sql_statements.init(mem);
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
    String message = g_sql.errmsg(db.handle).str_view();
    sql_throw(ctx, string::tformat("SQLITE_%d", g_sql.extended_errcode(db.handle)), message);
}

fn ulong sql_id(JsArg value) {
    double n = value.as_number() ?? 0;
    if (!(n >= 1) || n > 9007199254740991.0 || (double)(ulong)n != n) return 0;
    return (ulong)n;
}

fn SqlDatabase* sql_database(JsCtx ctx) {
    SqlDatabase* db = g_sql_databases.get(sql_id(ctx.arg(0))) ?? null;
    if (!db) ctx.throw_error(TYPE, "database is closed or invalid");
    if (db && !sql_access(ctx, db)) return null;
    return db;
}

fn SqlStatement* sql_statement(JsCtx ctx) {
    SqlStatement* stmt = g_sql_statements.get(sql_id(ctx.arg(0))) ?? null;
    if (!stmt) ctx.throw_error(TYPE, "statement is finalized or its database is closed");
    if (stmt && !sql_access(ctx, stmt.db)) return null;
    return stmt;
}

fn void sql_finalize(SqlStatement* stmt) {
    g_sql_statements.remove(stmt.id);
    if (stmt.prev) {
        stmt.prev.next = stmt.next;
    } else {
        stmt.db.statements = stmt.next;
    }
    if (stmt.next) stmt.next.prev = stmt.prev;
    g_sql.finalize(stmt.handle);
    free(stmt);
}

fn void sql_close(SqlDatabase* db) {
    while (db.statements) sql_finalize(db.statements);
    g_sql_databases.remove(db.id);
    g_sql.close(db.handle);
    if (db.path.len) free(db.path.ptr);
    free(db);
}

fn void close_sqlite() {
    if (!g_sql_library) return;
    @pool() {
        ulong[] ids = g_sql_databases.keys(tmem);
        foreach (id : ids) sql_close(g_sql_databases.get(id)!!);
    };
    g_sql_statements.free();
    g_sql_databases.free();
    libc::dlclose(g_sql_library);
    g_sql_library = null;
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
        g_rt.request_interrupt();
        return 1;
    }
    return 0;
}

fn void sql_deadline(SqlDatabase* db) {
    db.deadline = g_time_limit_ms > 0 ? now_ns() + (ulong)g_time_limit_ms * 1_000_000 : 0;
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

fn bool sql_access(JsCtx ctx, SqlDatabase* db) {
    if (!db.path.len) return true;
    String[] suffixes = { "", "-journal", "-wal", "-shm" };
    foreach (suffix : suffixes) {
        String target = canonical(string::tformat("%s%s", db.path, suffix));
        if (!check_path(READ, target)) {
            sql_throw(ctx, "PERMISSION_DENIED", denied_path(READ, target));
            return false;
        }
        if (!db.readonly && !check_path(WRITE, target)) {
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
        bool readonly          = ctx.arg(1).as_bool() ?? false;
        String path            = raw == ":memory:" ? raw : canonical(raw);
        SqlDatabase permission = { .path = path == ":memory:" ? "" : path, .readonly = readonly };
        if (!sql_access(ctx, &permission)) return;
        SqlDatabase* db = mem::new(SqlDatabase);
        bool opened;
        defer if (!opened) {
            if (db.handle) g_sql.close(db.handle);
            free(db);
        }
        CInt flags = (readonly ? 1 : 2 | 4) | 0x1000000; // READONLY / READWRITE|CREATE, NOFOLLOW
        if (g_sql.open_v2(path.zstr_tcopy(), &db.handle, flags, null) != 0) {
            if (db.handle) {
                sql_error(ctx, db);
            } else {
                ctx.throw_error(ERROR, "SQLite allocation failed");
            }
            return;
        }
        // Avoid implicit temp files outside the database's permission scope.
        if (g_sql.exec(
            db.handle,
            "PRAGMA temp_store=MEMORY",
            null,
            null,
            null
        ) != 0 || g_sql.set_authorizer(db.handle, &sql_authorize, db) != 0) return sql_error(ctx, db);
        db.id = g_sql_next_id++;
        db.readonly = readonly;
        if (path != ":memory:") db.path = path.copy(mem);
        g_sql.progress_handler(db.handle, 10000, &sql_progress, db);
        g_sql_databases.set(db.id, db);
        opened = true;
        ctx.ret_number((double)db.id);
    };
}

fn void js_sqlite_close(JsCtx ctx, void* user) {
    @pool() {
        if (try db = g_sql_databases.get(sql_id(ctx.arg(0)))) sql_close(db);
    };
}

fn void js_sqlite_exec(JsCtx ctx, void* user) {
    @pool() {
        SqlDatabase* db = sql_database(ctx);
        if (!db) return;
        String? sql = sql_string(ctx, 1);
        if (catch sql) return;
        sql_deadline(db);
        if (g_sql.exec(db.handle, sql.zstr_tcopy(), null, null, null) != 0) sql_error(ctx, db);
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
            if (stmt.handle) g_sql.finalize(stmt.handle);
            free(stmt);
        }
        char* tail;
        sql_deadline(db);
        if (g_sql.prepare_v2(db.handle, sql.ptr, (CInt)sql.len, &stmt.handle, &tail) != 0) return sql_error(ctx, db);
        if (!stmt.handle) return ctx.throw_error(TYPE, "expected one SQL statement");
        // Parse the tail to accept comments/semicolons but reject a second statement.
        sz remaining = sql.len - (tail - sql.ptr);
        if (remaining > 0) {
            void* extra;
            char* rest;
            CInt rc = g_sql.prepare_v2(db.handle, tail, (CInt)remaining, &extra, &rest);
            if (extra) g_sql.finalize(extra);
            if (rc != 0) return sql_error(ctx, db);
            if (extra) return ctx.throw_error(
                TYPE,
                "prepare accepts one SQL statement; use exec for multiple statements"
            );
        }
        stmt.db = db;
        stmt.id = g_sql_next_id++;
        stmt.next = db.statements;
        if (stmt.next) stmt.next.prev = stmt;
        db.statements = stmt;
        g_sql_statements.set(stmt.id, stmt);
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
    if (value >= -9007199254740991 && value <= 9007199254740991) return ctx.number((double)value);
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
        CInt count = g_sql.bind_parameter_count(stmt.handle);
        *names.array_len_ptr() = (uint)count;
        for (CInt i = 0; i < count; i++) {
            ZString name = g_sql.bind_parameter_name(stmt.handle, i + 1);
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
        rc = g_sql.bind_null(stmt.handle, position);
    } else if (value.is_boolean()) {
        rc = g_sql.bind_int64(stmt.handle, position, value.get_boolean() ? 1 : 0);
    } else if (value.is_numeric()) {
        double n = value.get_number_or_fastint();
        if (n != n || n > double::max || n < -double::max) {
            ctx.throw_error(RANGE, "SQLite numbers must be finite");
            return false;
        }
        if (n >= -9007199254740991.0 && n <= 9007199254740991.0 && (double)(long)n == n) {
            rc = g_sql.bind_int64(stmt.handle, position, (long)n);
        } else {
            rc = g_sql.bind_double(stmt.handle, position, n);
        }
    } else if (value.is_bigint()) {
        HBigInt* b = value.get_heapptr();
        if (!b.fits_int128() || b.to_int128() < (int128)long::min || b.to_int128() > (int128)long::max) {
            ctx.throw_error(RANGE, "SQLite BigInts must fit signed 64 bits");
            return false;
        }
        rc = g_sql.bind_int64(stmt.handle, position, (long)b.to_int128());
    } else if (value.is_string()) {
        String text = (JsArg) { .tv = value }.as_string() ?? "";
        if (text.len > int::max) {
            ctx.throw_error(RANGE, "SQLite text is too long");
            return false;
        }
        rc = g_sql.bind_text(stmt.handle, position, text.ptr, (CInt)text.len, (void*)usz::max);
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
        rc = g_sql.bind_blob(stmt.handle, position, bytes.len ? bytes.ptr : "", (CInt)bytes.len, (void*)usz::max);
    }
    if (rc != 0) {
        sql_error(ctx, stmt.db);
        return false;
    }
    return true;
}

fn JsArg? sql_column(JsCtx ctx, SqlStatement* stmt, CInt column) {
    switch (g_sql.column_type(stmt.handle, column)) {
        case 1: return sql_integer(ctx, g_sql.column_int64(stmt.handle, column));
        case 2: return ctx.number(g_sql.column_double(stmt.handle, column));
        case 3:
            char* text = g_sql.column_text(stmt.handle, column);
            CInt len = g_sql.column_bytes(stmt.handle, column);
            if (!text && len) return boomkat::OUT_OF_MEMORY~;
            return ctx.string((String)text[:len]);
        case 4:
            char* data = g_sql.column_blob(stmt.handle, column);
            CInt len = g_sql.column_bytes(stmt.handle, column);
            if (!data && len) return boomkat::OUT_OF_MEMORY~;
            return ctx.bytes(copy_bytes(data[:len]));
        default: return ctx.null_value();
    }
}

fn void js_sqlite_query(JsCtx ctx, void* user) {
    @pool() {
        SqlStatement* stmt = sql_statement(ctx);
        if (!stmt) return;
        JsArg params = ctx.arg(1);
        if (!params.tv.is_object() || ((HObject*)params.tv.get_heapptr()).get_class() != ARRAY) {
            return ctx.throw_error(TYPE, "SQLite bindings must be an array");
        }
        HObject* bindings = params.tv.get_heapptr();
        uint count        = *bindings.array_len_ptr();
        if (count != (uint)g_sql.bind_parameter_count(
            stmt.handle
        )) return ctx.throw_error(RANGE, "incorrect SQLite parameter count");
        g_sql.reset(stmt.handle);
        g_sql.clear_bindings(stmt.handle);
        defer {
            g_sql.reset(stmt.handle);
            g_sql.clear_bindings(stmt.handle);
        }
        for (uint i = 0; i < count; i++) {
            TVal value = bindings.get_array_idx(i) ?? (TVal) { };
            if (!sql_bind(ctx, stmt, i, value)) return;
        }
        int mode         = ctx.arg(2).as_int(); // 0 all, 1 get, 2 run
        HObject*? output = sql_object(ctx, ARRAY);
        if (catch output) return ctx.throw_error(ERROR, "SQLite allocation failed");
        uint row_index;
        sql_deadline(stmt.db);
        while (true) {
            CInt rc = g_sql.step(stmt.handle);
            if (rc == 101) break;
            if (rc != 100) return sql_error(ctx, stmt.db);
            if (mode == 2) continue;
            HObject*? row = sql_object(ctx);
            if (catch row) return ctx.throw_error(ERROR, "SQLite allocation failed");
            CInt columns = g_sql.column_count(stmt.handle);
            for (CInt i = 0; i < columns; i++) {
                JsArg? value = sql_column(ctx, stmt, i);
                if (catch value) return ctx.throw_error(ERROR, "SQLite allocation failed");
                if (!sql_put(ctx, row, g_sql.column_name(stmt.handle, i).str_view(), value.tv)) {
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
            JsArg? rowid = sql_integer(ctx, g_sql.last_insert_rowid(stmt.db.handle));
            if (catch rowid) return ctx.throw_error(ERROR, "SQLite allocation failed");
            if (!sql_put(ctx, stats, "changes", ctx.number(g_sql.changes(stmt.db.handle))
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

fn void js_sqlite_finalize(JsCtx ctx, void* user) {
    @pool() {
        if (try stmt = g_sql_statements.get(sql_id(ctx.arg(0)))) sql_finalize(stmt);
    };
}
fn void js_sqlite_version(JsCtx ctx, void* user) => ctx.ret_string(g_sql.libversion().str_view());

const Native[] SQLITE_NATIVES = {
    { "sqliteOpen", &js_sqlite_open, 2 },
    { "sqliteClose", &js_sqlite_close, 1 },
    { "sqliteExec", &js_sqlite_exec, 2 },
    { "sqlitePrepare", &js_sqlite_prepare, 2 },
    { "sqliteParams", &js_sqlite_params, 1 },
    { "sqliteQuery", &js_sqlite_query, 3 },
    { "sqliteFinalize", &js_sqlite_finalize, 1 },
    { "sqliteVersion", &js_sqlite_version, 0 },
};