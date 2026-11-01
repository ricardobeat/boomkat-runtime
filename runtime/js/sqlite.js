const bk = __bk;
const markOpaque = bk.workerOpaque;
const databases = new WeakMap();
const statements = new WeakMap();
const internal = Symbol("SQLite statement");
let transactionId = 0;
export const version = bk.sqliteVersion();

function databaseState(db) {
    const state = databases.get(db);
    if (!state || state.closed) throw new TypeError("database is closed or invalid");
    return state;
}
function statementState(stmt) {
    const state = statements.get(stmt);
    if (!state || state.finalized) throw new TypeError("statement is finalized or invalid");
    if (state.database.closed) throw new TypeError("database is closed or invalid");
    return state;
}
function bindings(names, args) {
    const first = args[0];
    const named = args.length === 1 && first !== null && typeof first === "object" &&
        !Array.isArray(first) && !(first instanceof ArrayBuffer) && !ArrayBuffer.isView(first);
    if (!named && !(args.length === 1 && Array.isArray(first))) {
        if (args.length !== names.length) throw new RangeError("incorrect SQLite parameter count");
        return args;
    }
    const out = [];
    if (named) {
        const used = new Set();
        for (const name of names) {
            if (name === null || name[0] === "?") throw new TypeError("named bindings require named SQL parameters");
            const bare = name.slice(1);
            const key = Object.prototype.hasOwnProperty.call(first, name) ? name : bare;
            if (!Object.prototype.hasOwnProperty.call(first, key)) throw new RangeError("missing SQLite parameter: " + name);
            out.push(first[key]);
            used.add(key);
        }
        for (const key of Object.keys(first)) if (!used.has(key)) throw new RangeError("unknown SQLite parameter: " + key);
    } else {
        const values = first;
        for (let i = 0; i < values.length; i++) out.push(values[i]);
        if (out.length !== names.length) throw new RangeError("incorrect SQLite parameter count");
    }
    return out;
}

export class Statement {
    constructor(token, db, id) {
        if (token !== internal) throw new TypeError("use database.prepare() to create a statement");
        let statement;
        try {
            statement = bk.sqliteStatement(id);
            statements.set(statement, { db, database: databaseState(db), id, names: bk.sqliteParams(id), finalized: false });
        }
        catch (error) { bk.sqliteFinalize(id); throw error; }
        return statement;
    }
    all(...args) { const s = statementState(this); return bk.sqliteQuery(s.id, bindings(s.names, args), 0); }
    get(...args) { const s = statementState(this); return bk.sqliteQuery(s.id, bindings(s.names, args), 1); }
    run(...args) { const s = statementState(this); return bk.sqliteQuery(s.id, bindings(s.names, args), 2); }
    [Symbol.dispose]() { this.finalize(); }
    finalize() {
        const s = statements.get(this);
        if (!s || s.finalized) return;
        bk.sqliteFinalize(s.id);
        s.finalized = true;
    }
}

bk.sqliteStatementClass(Statement.prototype, Statement.prototype.all, Statement.prototype.get, Statement.prototype.run);
for (const [name, method] of [["all", bk.sqliteAll], ["get", bk.sqliteGet], ["run", bk.sqliteRun]])
    Object.defineProperty(method, "name", { value: name, configurable: true });
Object.defineProperties(Statement.prototype, {
    all: { value: bk.sqliteAll, writable: true, configurable: true },
    get: { value: bk.sqliteGet, writable: true, configurable: true },
    run: { value: bk.sqliteRun, writable: true, configurable: true },
});

export class Database {
    constructor(path = ":memory:", { readonly = false } = {}) {
        databases.set(this, { id: bk.sqliteOpen(String(path), Boolean(readonly)), closed: false });
        markOpaque(this);
    }
    get inTransaction() { return bk.sqliteInTransaction(databaseState(this).id); }
    exec(sql) { bk.sqliteExec(databaseState(this).id, String(sql)); }
    prepare(sql) { return new Statement(internal, this, bk.sqlitePrepare(databaseState(this).id, String(sql))); }
    query(sql) { return this.prepare(sql); }
    [Symbol.dispose]() { this.close(); }
    close() {
        const s = databases.get(this);
        if (!s || s.closed) return;
        bk.sqliteClose(s.id);
        s.closed = true;
    }
    transaction(fn) {
        databaseState(this);
        if (typeof fn !== "function") throw new TypeError("transaction requires a function");
        const db = this;
        return function (...args) {
            const name = "bkr_sqlite_" + ++transactionId;
            db.exec("SAVEPOINT " + name);
            try {
                const result = fn.apply(this, args);
                if (result !== null && result !== undefined && typeof result.then === "function")
                    throw new TypeError("SQLite transactions require synchronous callbacks");
                db.exec("RELEASE " + name);
                return result;
            } catch (error) {
                try { db.exec("ROLLBACK TO " + name); db.exec("RELEASE " + name); } catch (_) {}
                throw error;
            }
        };
    }
}
