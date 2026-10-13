import { createStore } from "../examples/taskboard/lib/sqlite.ts";
import { createAccess } from "../examples/taskboard/server/domain/access.ts";
import { createBoards } from "../examples/taskboard/server/domain/boards.ts";
const native = typeof Bun === "undefined";
const { Database } = await import(native ? "sqlite" : "bun:sqlite");
const path = native ? (await import("process")).args[0] : process.argv[2];
const db = new Database(path);
const check = (ok, label) => { if (!ok) throw new Error(label); };
try {
    db.exec(`PRAGMA journal_mode=WAL;
        CREATE TABLE team_members(team_id INTEGER,user_id INTEGER);
        CREATE TABLE boards(id INTEGER PRIMARY KEY,team_id INTEGER,name TEXT,created INTEGER);
        CREATE TABLE lists(id INTEGER PRIMARY KEY,board_id INTEGER,name TEXT,position INTEGER);
        CREATE TABLE cards(id INTEGER PRIMARY KEY,list_id INTEGER,title TEXT,description TEXT,color TEXT,created_by INTEGER,created INTEGER,updated INTEGER);
        CREATE TABLE images(id INTEGER PRIMARY KEY,card_id INTEGER,name TEXT,mime TEXT,size INTEGER);
        INSERT INTO team_members VALUES(1,1);
        INSERT INTO boards VALUES(1,1,'First',1),(2,1,'Empty',2);
        INSERT INTO lists VALUES(1,1,'Later',1),(2,1,'Earlier',0);
        INSERT INTO cards VALUES(30,1,'Third','','none',1,1,1),(10,2,'First','','none',1,1,1),(20,1,'Second','','none',1,1,1);
        INSERT INTO images VALUES(7,30,'later.png','image/png',30),(4,10,'earlier.png','image/png',20);`);
    const store = createStore(db);
    let loads = 0;
    const tracked = { db, q(sql) {
        const statement = store.q(sql);
        return sql.includes("AS snapshot") ? { get(...args) { loads++; return statement.get(...args); } } : statement;
    } };
    check(createBoards(tracked, createAccess(store)).getJSON === undefined, "snapshot cache enabled by default");
    const boards = createBoards(tracked, createAccess(store), true);
    const read = () => JSON.parse(boards.getJSON(1,1));
    const equivalent = () => check(JSON.stringify(read()) === JSON.stringify(boards.get(1,1)), "snapshot differs from ordinary rows");
    const content = 'quotes " slash \\ controls\n\t\0 café 😀 漢字';
    store.q('UPDATE cards SET description=? WHERE id=10').run(content);
    equivalent();
    check(read().cards.map(c=>c.id).join() === '10,20,30', 'card ordering');
    check(read().lists.map(l=>l.id).join() === '2,1', 'list ordering');
    check(read().images.map(i=>i.id).join() === '4,7', 'image ordering');
    check(read().cards[0].description === content, 'Unicode and control text');
    const initialLoads = loads; read(); read();
    check(loads === initialLoads, 'unchanged board was rebuilt');
    const empty = JSON.parse(boards.getJSON(2,1));
    check(empty.cards.length === 0 && empty.lists.length === 0 && empty.images.length === 0, 'empty arrays');
    store.q('UPDATE cards SET title=? WHERE id=10').run('Local change');
    check(read().cards[0].title === 'Local change', 'local write invalidation');
    const outside = new Database(path);
    try {
        outside.prepare('UPDATE cards SET title=? WHERE id=10').run('External change');
        check(read().cards[0].title === 'External change', 'external write invalidation');
    } finally { outside.close(); }
    try {
        db.transaction(() => {
            store.q('UPDATE cards SET title=? WHERE id=10').run('Rolled back');
            check(read().cards[0].title === 'Rolled back', 'transaction read');
            throw new Error('rollback probe');
        })();
    } catch (error) { check(error.message === 'rollback probe', 'unexpected transaction error'); }
    check(read().cards[0].title === 'External change', 'rollback leaked cached data');
    db.exec('SAVEPOINT probe');
    store.q('UPDATE cards SET title=? WHERE id=10').run('Savepoint value');
    check(read().cards[0].title === 'Savepoint value', 'savepoint read');
    db.exec('ROLLBACK TO probe; RELEASE probe');
    check(read().cards[0].title === 'External change', 'savepoint rollback leaked cached data');
    equivalent();
    store.q('DELETE FROM team_members WHERE team_id=1 AND user_id=1').run();
    let denied = false;
    try { boards.getJSON(1,1); } catch (error) { denied = error.status === 404; }
    check(denied, 'cached board bypassed membership revocation');
    console.log('Board snapshots: row equivalence, ordering, cache hits, local/external writes, rollback, savepoints and revocation passed');
} finally { db.close(); }
