const bk = __bk;
const enc = new TextEncoder();

const lines = (s) => s.split("\n").filter(Boolean);
const rids = (text) => text.split(" ").map(Number);

export const args = lines(bk.args());
export const main = bk.mainPath();
export const execPath = bk.execPath();
export const pid = bk.pid();
export const exit = (code = 0) => bk.exit(code);

export const env = {
    get: (name) => bk.envGet(name),
    set: (name, value) => bk.envSet(name, String(value)),
    delete: (name) => bk.envDelete(name),
    toObject: () => Object.fromEntries(lines(bk.envAll()).map((l) => {
        const i = l.indexOf("=");
        return [l.slice(0, i), l.slice(i + 1)];
    })),
};

export const stdin = new bk.Handle(0);
export const stdout = new bk.Handle(1);
export const stderr = new bk.Handle(2);

class Child {
    #done;
    constructor(pid, [stdin, stdout, stderr]) {
        this.pid = pid;
        this.stdin = stdin < 0 ? null : new bk.Handle(stdin);
        this.stdout = stdout < 0 ? null : new bk.Handle(stdout);
        this.stderr = stderr < 0 ? null : new bk.Handle(stderr);
        this.status = bk.op(bk.wait, pid);
    }
    kill(signal = 15) { bk.kill(this.pid, signal); }
}

export function spawn(command, { args = [], env, cwd = "", stdin = "inherit", stdout = "inherit", stderr = "inherit" } = {}) {
    const mode = (m) => ({ piped: "p", inherit: "i", null: "n" })[m];
    const envText = env ? Object.entries(env).map(([k, v]) => `${k}=${v}`).join("\n") : "";
    const text = bk.spawn(command, args.join("\n"), envText, cwd, mode(stdin) + mode(stdout) + mode(stderr));
    const [pid, ...handles] = rids(text);
    return new Child(pid, handles);
}

export async function run(command, options = {}) {
    const child = spawn(command, { ...options, stdout: "piped", stderr: "piped" });
    const drain = async (h) => {
        const parts = [];
        for (let c; (c = await h.read()) !== null;) parts.push(c);
        h.close();
        return new Blob(parts).bytes();
    };
    const [out, err, code] = await Promise.all([drain(child.stdout), drain(child.stderr), child.status]);
    return { code, stdout: out, stderr: err };
}
