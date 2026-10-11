const bk = __bk;
const NAMES = ["net", "read", "write", "env", "run", "ffi", "sys", "import"];
const STATES = ["granted", "prompt", "denied"];

function parse(desc) {
    if (typeof desc === "string") desc = { name: desc };
    if (!desc || !NAMES.includes(desc.name)) throw new TypeError("unknown permission: " + (desc && desc.name));
    const item = desc.host ?? desc.path ?? desc.variable ?? desc.command ?? desc.kind ?? "";
    return [desc.name, String(item)];
}

export function query(desc) {
    const [name, item] = parse(desc);
    return Promise.resolve({ state: STATES[bk.permQuery(name, item)] });
}

export function request(desc) {
    const [name, item] = parse(desc);
    return Promise.resolve({ state: STATES[bk.permRequest(name, item)] });
}

export function revoke(desc) {
    const [name, item] = parse(desc);
    bk.permRevoke(name, item);
    return query(desc);
}
