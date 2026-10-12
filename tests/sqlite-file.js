import { Database } from "sqlite";
import { args } from "process";
import { revoke } from "permissions";
const [path, mode] = args;
const assert = (ok, message) => { if (!ok) throw new Error(message); };
if (mode === "deny") {
    let error;
    try { new Database(path); } catch (e) { error = e; }
    assert(error && error.code === "PERMISSION_DENIED", "database permission bypassed");
} else if (mode === "readonly") {
    const db = new Database(path, { readonly: true });
    assert(db.query("SELECT v FROM t").get().v === "persisted", "readonly read failed");
    let error;
    try { db.exec("INSERT INTO t VALUES ('wrong')"); } catch (e) { error = e; }
    assert(error && error.code.startsWith("SQLITE_"), "readonly database allowed writes");
    db.close();
} else {
    const db = new Database(path);
    db.exec("CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('persisted')");
    assert(db.query("SELECT v FROM t").get().v === "persisted", "persistent query failed");
    if (mode === "revoke") {
        const stmt = db.query("SELECT v FROM t");
        await revoke("read");
        let error;
        try { stmt.all(); } catch (e) { error = e; }
        assert(error && error.code === "PERMISSION_DENIED", "revoked permission ignored");
    }
    db.close();
}
console.log("sqlite-file: passed " + mode);
