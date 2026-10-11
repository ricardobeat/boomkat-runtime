const bk = __bk;

class Conn extends bk.Handle {
    constructor(rid) {
        super(rid);
        const [local, remote, port] = bk.addr(rid).split(" ");
        this.localPort = Number(local);
        this.remoteAddress = remote;
        this.remotePort = Number(port);
    }
    closeWrite() { bk.closeWrite(this.rid); }
}

export async function connect({ hostname, port, tls = false }) {
    return new Conn(await bk.op(bk.connect, String(hostname), port, tls));
}

export function listen({ hostname = "0.0.0.0", port = 0 }) {
    const lid = bk.listen(hostname, port);
    const [local] = bk.addr(lid).split(" ");
    let closed = false;
    return {
        hostname,
        port: Number(local),
        async accept() {
            const rid = await bk.op(bk.accept, lid);
            return rid === null ? null : new Conn(rid);
        },
        async *[Symbol.asyncIterator]() {
            for (let c; (c = await this.accept()) !== null;) yield c;
        },
        close() {
            if (closed) return;
            closed = true;
            bk.close(lid);
        },
    };
}

export const resolve = (hostname) => bk.op(bk.resolve, String(hostname));
