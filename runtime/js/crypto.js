const bk = __bk;
const iteratorKey = Symbol.iterator;
const byteIterator = Uint8Array.prototype[iteratorKey];

export const randomBytes = (size) => bk.cryptoRandom(size);
export const sha256 = (data) => bk.cryptoSha256(data);
export const subtle = globalThis.crypto.subtle;
export const timingSafeEqual = (a, b) => bk.cryptoEqual(a, b);
export const hashPassword = (password) => bk.op(bk.cryptoPassword, password, null);
export const verifyPassword = (password, encoded) => bk.op(bk.cryptoPassword, password, encoded);
export function hex(bytes) {
    const native = bk.cryptoHex(bytes, byteIterator, iteratorKey);
    if (native !== undefined) return native;
    let out = "";
    for (const b of bytes) out += b.toString(16).padStart(2, "0");
    return out;
}
