// crypto.subtle over the natives on __bk. This script is evaluated the first
// time crypto.subtle is read and returns the SubtleCrypto instance.
(function (bk) {
"use strict";

const HASH_IDS = { "SHA-1": 1, "SHA-256": 2, "SHA-384": 3, "SHA-512": 4 };
const HASH_BITS = { "SHA-1": 160, "SHA-256": 256, "SHA-384": 384, "SHA-512": 512 };
const BLOCK_BITS = { "SHA-1": 512, "SHA-256": 512, "SHA-384": 1024, "SHA-512": 1024 };
const HMAC_JWK = { "SHA-1": "HS1", "SHA-256": "HS256", "SHA-384": "HS384", "SHA-512": "HS512" };
const AES_MODES = { "AES-GCM": 1, "AES-CBC": 2, "AES-CTR": 3 };
const USAGE_ORDER = ["encrypt", "decrypt", "sign", "verify", "deriveKey", "deriveBits", "wrapKey", "unwrapKey"];
const TAG_LENGTHS = [32, 64, 96, 104, 112, 120, 128];
const MAX_DERIVED_BYTES = 1 << 24;

const KIND_DIGEST = 1, KIND_HMAC = 2, KIND_PBKDF2 = 3, KIND_HKDF = 4, KIND_ENCRYPT = 10, KIND_DECRYPT = 20;

const NAMES = new Map();
for (const n of ["SHA-1", "SHA-256", "SHA-384", "SHA-512", "HMAC", "AES-GCM", "AES-CBC", "AES-CTR", "PBKDF2", "HKDF"]) NAMES.set(n.toUpperCase(), n);
// Recognised, but not implemented yet: asking for them is NotSupportedError.
const UNSUPPORTED = new Map();
for (const n of ["AES-KW", "RSA-OAEP", "RSA-PSS", "RSASSA-PKCS1-v1_5", "ECDSA", "ECDH", "Ed25519", "X25519"]) UNSUPPORTED.set(n.toUpperCase(), n);

const EMPTY = new Uint8Array(0);
const fail = (name, message) => new DOMException(message, name);

function normalize(algorithm) {
    if (typeof algorithm === "string") algorithm = { name: algorithm };
    else if (algorithm === null || typeof algorithm !== "object") throw new TypeError("algorithm must be a string or an object");
    const upper = String(algorithm.name).toUpperCase();
    const name = NAMES.get(upper);
    if (name) return { ...algorithm, name };
    if (UNSUPPORTED.has(upper)) throw fail("NotSupportedError", `${UNSUPPORTED.get(upper)} is not supported yet`);
    throw fail("NotSupportedError", "Unrecognized algorithm name");
}

function hashName(hash) {
    const name = typeof hash === "string" ? hash : hash && typeof hash === "object" ? hash.name : undefined;
    if (name === undefined) throw new TypeError("hash is required");
    const canonical = NAMES.get(String(name).toUpperCase());
    if (!canonical || !(canonical in HASH_IDS)) throw fail("NotSupportedError", "Unrecognized hash name");
    return canonical;
}

function bytesOf(data) {
    if (data instanceof ArrayBuffer || (typeof SharedArrayBuffer !== "undefined" && data instanceof SharedArrayBuffer)) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    throw new TypeError("expected an ArrayBuffer or a view");
}

const copyOf = (data) => new Uint8Array(bytesOf(data)).slice();

function base64url(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text) {
    if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) throw fail("DataError", "invalid base64url key data");
    const s = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
}

async function run(kind, hash, key = EMPTY, data = EMPTY, iv = EMPTY, aad = EMPTY, n1 = 0, n2 = 0) {
    let out;
    try {
        out = await bk.op(bk.cryptoSubtle, kind, hash, key, data, iv, aad, n1, n2);
    } catch (e) {
        if (e && (e.code === "OPERATION_ERROR" || e.code === "BAD_PARAMS")) throw fail("OperationError", "The operation failed for an operation-specific reason");
        if (e && e.code === "UNAVAILABLE") throw fail("NotSupportedError", e.message);
        throw e;
    }
    return out.byteOffset === 0 && out.byteLength === out.buffer.byteLength ? out.buffer : out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
}

// ---- keys ----

const KEYS = new WeakMap();
const TOKEN = Symbol("CryptoKey");

class CryptoKey {
    constructor(token, state) {
        if (token !== TOKEN) throw new TypeError("Illegal constructor");
        KEYS.set(this, state);
    }
    get type() { return KEYS.get(this).type; }
    get extractable() { return KEYS.get(this).extractable; }
    get algorithm() { return KEYS.get(this).algorithm; }
    get usages() { return KEYS.get(this).usages; }
}
Object.defineProperty(CryptoKey.prototype, Symbol.toStringTag, { value: "CryptoKey", configurable: true });

function makeKey(algorithm, extractable, usages, bytes) {
    return new CryptoKey(TOKEN, { type: "secret", extractable: !!extractable, algorithm: Object.freeze(algorithm), usages: Object.freeze(usages), bytes });
}

function checkUsages(usages, allowed) {
    if (usages === null || typeof usages !== "object" || typeof usages[Symbol.iterator] !== "function") throw new TypeError("usages must be a sequence");
    const given = new Set();
    for (const u of usages) {
        if (!USAGE_ORDER.includes(u) || !allowed.includes(u)) throw fail("SyntaxError", `Unsupported key usage: ${u}`);
        given.add(u);
    }
    if (given.size === 0) throw fail("SyntaxError", "Usages cannot be empty when creating a secret key");
    return USAGE_ORDER.filter((u) => given.has(u));
}

function keyOf(key, algorithmName, usage) {
    const state = key instanceof CryptoKey ? KEYS.get(key) : undefined;
    if (!state) throw new TypeError("key must be a CryptoKey");
    if (state.algorithm.name !== algorithmName) throw fail("InvalidAccessError", "key algorithm does not match the requested algorithm");
    if (!state.usages.includes(usage)) throw fail("InvalidAccessError", `key does not support the ${usage} operation`);
    return state;
}

const AES_USAGES = ["encrypt", "decrypt", "wrapKey", "unwrapKey"];
const HMAC_USAGES = ["sign", "verify"];
const KDF_USAGES = ["deriveKey", "deriveBits"];

const aesJwkName = (name, bits) => `A${bits}${name.slice(4)}`;

function importSecret(alg, bytes, extractable, usages, jwk) {
    const name = alg.name;
    if (name in AES_MODES) {
        usages = checkUsages(usages, AES_USAGES);
        if (![16, 24, 32].includes(bytes.length)) throw fail("DataError", "Invalid AES key length");
        if (jwk && jwk.alg !== undefined && jwk.alg !== aesJwkName(name, bytes.length * 8)) throw fail("DataError", "JWK alg does not match the algorithm");
        return makeKey({ name, length: bytes.length * 8 }, extractable, usages, bytes);
    }
    if (name === "HMAC") {
        const hash = hashName(alg.hash);
        usages = checkUsages(usages, HMAC_USAGES);
        if (bytes.length === 0) throw fail("DataError", "HMAC keys cannot be empty");
        if (alg.length !== undefined && (alg.length > bytes.length * 8 || alg.length <= (bytes.length - 1) * 8)) throw fail("DataError", "HMAC key length does not match the key data");
        if (jwk && jwk.alg !== undefined && jwk.alg !== HMAC_JWK[hash]) throw fail("DataError", "JWK alg does not match the hash");
        return makeKey({ name, hash: { name: hash }, length: alg.length ?? bytes.length * 8 }, extractable, usages, bytes);
    }
    throw fail("NotSupportedError", `Importing ${name} keys is not supported`);
}

function importJwk(alg, jwk, extractable, usages) {
    if (jwk === null || typeof jwk !== "object") throw new TypeError("keyData must be a JSON Web Key object");
    if (jwk.kty !== "oct") throw fail("DataError", "Invalid JWK key type");
    const bytes = fromBase64url(jwk.k);
    if (usages.length && jwk.use !== undefined && jwk.use !== "enc" && jwk.use !== "sig") throw fail("DataError", "Invalid JWK use");
    if (jwk.key_ops !== undefined) {
        if (!Array.isArray(jwk.key_ops) || new Set(jwk.key_ops).size !== jwk.key_ops.length) throw fail("DataError", "Invalid JWK key_ops");
        for (const u of usages) if (!jwk.key_ops.includes(u)) throw fail("DataError", "Requested usages exceed the JWK key_ops");
    }
    if (jwk.ext === false && extractable) throw fail("DataError", "JWK ext is false but the key was requested extractable");
    return importSecret(alg, bytes, extractable, usages, jwk);
}

function importKeyData(format, keyData, algorithm, extractable, usages) {
    const alg = normalize(algorithm);
    if (alg.name in HASH_IDS) throw fail("NotSupportedError", `${alg.name} is not a key algorithm`);
    if (alg.name === "PBKDF2" || alg.name === "HKDF") {
        if (format !== "raw") throw fail("NotSupportedError", `${alg.name} keys can only be imported as raw`);
        if (extractable) throw fail("SyntaxError", `${alg.name} keys cannot be extractable`);
        usages = checkUsages(usages, KDF_USAGES);
        return makeKey({ name: alg.name }, false, usages, copyOf(keyData));
    }
    if (format === "raw") return importSecret(alg, copyOf(keyData), extractable, usages);
    if (format === "jwk") return importJwk(alg, keyData, extractable, usages);
    if (format === "spki" || format === "pkcs8") throw fail("NotSupportedError", `${format} is not supported for ${alg.name}`);
    throw new TypeError(`Invalid key format: ${format}`);
}

// ---- operations ----

function aesParams(alg) {
    const mode = AES_MODES[alg.name];
    const iv = mode === 3 ? alg.counter : alg.iv;
    if (iv === undefined) throw new TypeError(`${mode === 3 ? "counter" : "iv"} is required`);
    const ivBytes = bytesOf(iv);
    let tag = 0, bits = 0, aad = EMPTY;
    if (mode === 1) {
        if (ivBytes.length === 0) throw fail("OperationError", "iv must not be empty");
        const tagBits = alg.tagLength ?? 128;
        if (!TAG_LENGTHS.includes(tagBits)) throw fail("OperationError", "Invalid tagLength");
        tag = tagBits / 8;
        if (alg.additionalData !== undefined) aad = bytesOf(alg.additionalData);
    } else if (ivBytes.length !== 16) {
        throw fail("OperationError", mode === 2 ? "iv must be 16 bytes" : "counter must be 16 bytes");
    }
    if (mode === 3) {
        bits = alg.length;
        if (!Number.isInteger(bits) || bits < 1 || bits > 128) throw fail("OperationError", "length must be between 1 and 128");
    }
    return { mode, iv: ivBytes, aad, tag, bits };
}

async function crypt(algorithm, key, data, decrypt) {
    const alg = normalize(algorithm);
    if (!(alg.name in AES_MODES)) throw fail("NotSupportedError", `${alg.name} does not support ${decrypt ? "decrypt" : "encrypt"}`);
    const input = bytesOf(data);
    const state = keyOf(key, alg.name, decrypt ? "decrypt" : "encrypt");
    const p = aesParams(alg);
    return run((decrypt ? KIND_DECRYPT : KIND_ENCRYPT) + p.mode, 0, state.bytes, input, p.iv, p.aad, p.tag, p.bits);
}

function deriveParams(alg, baseKey, usage, length) {
    const state = keyOf(baseKey, alg.name, usage);
    const bits = length;
    if (bits === null || bits === undefined || !Number.isInteger(bits) || bits <= 0 || bits % 8 !== 0) throw fail("OperationError", "length must be a positive multiple of 8");
    const bytes = bits / 8;
    if (bytes > MAX_DERIVED_BYTES) throw fail("OperationError", "length is too large");
    const hash = hashName(alg.hash);
    if (alg.salt === undefined) throw new TypeError("salt is required");
    const salt = bytesOf(alg.salt);
    if (alg.name === "PBKDF2") {
        const iterations = alg.iterations;
        if (!Number.isInteger(iterations) || iterations < 1) throw fail("OperationError", "iterations must be a positive integer");
        return run(KIND_PBKDF2, HASH_IDS[hash], state.bytes, EMPTY, salt, EMPTY, bytes, iterations);
    }
    if (alg.info === undefined) throw new TypeError("info is required");
    if (bytes > 255 * (HASH_BITS[hash] / 8)) throw fail("OperationError", "length is too large for HKDF with this hash");
    return run(KIND_HKDF, HASH_IDS[hash], state.bytes, EMPTY, salt, bytesOf(alg.info), bytes, 0);
}

function derivedKeyLength(type) {
    const alg = normalize(type);
    if (alg.name in AES_MODES) {
        if (![128, 192, 256].includes(alg.length)) throw fail("OperationError", "Invalid AES key length");
        return alg.length;
    }
    if (alg.name === "HMAC") {
        const hash = hashName(alg.hash);
        const length = alg.length ?? BLOCK_BITS[hash];
        if (!Number.isInteger(length) || length <= 0) throw fail("OperationError", "Invalid HMAC key length");
        return length;
    }
    throw fail("NotSupportedError", `${alg.name} cannot be a derived key type`);
}

class SubtleCrypto {
    async digest(algorithm, data) {
        const hash = hashName(algorithm);
        return run(KIND_DIGEST, HASH_IDS[hash], EMPTY, bytesOf(data));
    }

    async generateKey(algorithm, extractable, usages) {
        const alg = normalize(algorithm);
        if (alg.name in AES_MODES) {
            if (![128, 192, 256].includes(alg.length)) throw fail("OperationError", "Invalid AES key length");
            usages = checkUsages(usages, AES_USAGES);
            return makeKey({ name: alg.name, length: alg.length }, extractable, usages, bk.cryptoRandom(alg.length / 8));
        }
        if (alg.name === "HMAC") {
            const hash = hashName(alg.hash);
            const length = alg.length ?? BLOCK_BITS[hash];
            if (!Number.isInteger(length) || length <= 0) throw fail("OperationError", "Invalid HMAC key length");
            usages = checkUsages(usages, HMAC_USAGES);
            const bytes = bk.cryptoRandom(Math.ceil(length / 8));
            if (length % 8) bytes[bytes.length - 1] &= 0xff << (8 - (length % 8));
            return makeKey({ name: "HMAC", hash: { name: hash }, length }, extractable, usages, bytes);
        }
        throw fail("NotSupportedError", `${alg.name} keys cannot be generated`);
    }

    async importKey(format, keyData, algorithm, extractable, usages) {
        return importKeyData(format, keyData, algorithm, extractable, usages);
    }

    async exportKey(format, key) {
        const state = key instanceof CryptoKey ? KEYS.get(key) : undefined;
        if (!state) throw new TypeError("key must be a CryptoKey");
        if (!state.extractable) throw fail("InvalidAccessError", "key is not extractable");
        if (format === "raw") return state.bytes.slice().buffer;
        if (format === "jwk") {
            const name = state.algorithm.name;
            const alg = name === "HMAC" ? HMAC_JWK[state.algorithm.hash.name] : aesJwkName(name, state.algorithm.length);
            return { key_ops: [...state.usages], ext: true, kty: "oct", k: base64url(state.bytes), alg };
        }
        if (format === "spki" || format === "pkcs8") throw fail("NotSupportedError", `${format} is not supported for ${state.algorithm.name}`);
        throw new TypeError(`Invalid key format: ${format}`);
    }

    async encrypt(algorithm, key, data) { return crypt(algorithm, key, data, false); }
    async decrypt(algorithm, key, data) { return crypt(algorithm, key, data, true); }

    async sign(algorithm, key, data) {
        const alg = normalize(algorithm);
        if (alg.name !== "HMAC") throw fail("NotSupportedError", `${alg.name} does not support sign`);
        const input = bytesOf(data);
        const state = keyOf(key, "HMAC", "sign");
        return run(KIND_HMAC, HASH_IDS[state.algorithm.hash.name], state.bytes, input);
    }

    async verify(algorithm, key, signature, data) {
        const alg = normalize(algorithm);
        if (alg.name !== "HMAC") throw fail("NotSupportedError", `${alg.name} does not support verify`);
        const sig = bytesOf(signature);
        const input = bytesOf(data);
        const state = keyOf(key, "HMAC", "verify");
        const mac = new Uint8Array(await run(KIND_HMAC, HASH_IDS[state.algorithm.hash.name], state.bytes, input));
        return bk.cryptoEqual(mac, sig);
    }

    async deriveBits(algorithm, baseKey, length) {
        const alg = normalize(algorithm);
        if (alg.name !== "PBKDF2" && alg.name !== "HKDF") throw fail("NotSupportedError", `${alg.name} does not support deriveBits`);
        return deriveParams(alg, baseKey, "deriveBits", length);
    }

    async deriveKey(algorithm, baseKey, derivedKeyType, extractable, usages) {
        const alg = normalize(algorithm);
        if (alg.name !== "PBKDF2" && alg.name !== "HKDF") throw fail("NotSupportedError", `${alg.name} does not support deriveKey`);
        const bits = derivedKeyLength(derivedKeyType);
        const raw = await deriveParams(alg, baseKey, "deriveKey", Math.ceil(bits / 8) * 8);
        let bytes = new Uint8Array(raw);
        const type = normalize(derivedKeyType);
        if (type.name === "HMAC" && bits % 8) bytes[bytes.length - 1] &= 0xff << (8 - (bits % 8));
        return importSecret(type, bytes, extractable, usages);
    }

    async wrapKey() { throw fail("NotSupportedError", "wrapKey is not supported yet"); }
    async unwrapKey() { throw fail("NotSupportedError", "unwrapKey is not supported yet"); }
}
Object.defineProperty(SubtleCrypto.prototype, Symbol.toStringTag, { value: "SubtleCrypto", configurable: true });

return new SubtleCrypto();
})
