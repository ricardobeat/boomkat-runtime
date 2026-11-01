// crypto.subtle against vectors produced by Node's WebCrypto, plus the
// validation rules that make it behave like the spec.
import { test, assertEquals, assert } from "test";
import { subtle } from "crypto";

const enc = new TextEncoder();
const hex = (b) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
const bytes = (n, f) => new Uint8Array(n).map((_, i) => f(i));
const s = subtle;

async function rejects(name, fn) {
    try { await fn(); } catch (e) {
        assertEquals(e.name, name, `expected ${name}, got ${e.name}: ${e.message}`);
        return;
    }
    throw new Error(`expected ${name}, but it resolved`);
}

const VECTORS = {
    "digest SHA-1": "a9993e364706816aba3e25717850c26c9cd0d89d",
    "hmac SHA-1": "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
    "pbkdf2 SHA-1": "e39dc7df5689329b19200521e6e92e544293034b2b489bd7",
    "hkdf SHA-1": "10c930c5fbafc20c78e0da8b877b6bf4c943a4514b1388bad45cddbb606c4a519696ef36c8e4afb6b0be",
    "digest SHA-256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "hmac SHA-256": "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    "pbkdf2 SHA-256": "926891811ee18e4539b150e9c3888a1afb0eb6fb827ad0c0",
    "hkdf SHA-256": "799808b8ce5b4d33deb80d0d25444d0d3b7183fa8be5509335acb366f1ed0dafb166b52933b3362bc5a3",
    "digest SHA-384": "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
    "hmac SHA-384": "af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649",
    "pbkdf2 SHA-384": "0062f6933352efe0f97badd3fdd810cfdbbc60a81487abc8",
    "hkdf SHA-384": "bc7dca9ae52b7f54b0781a47b730d97f2dda4c9e233446c45e4dd4ef1a0134dd4e473297c5d496cf7de8",
    "digest SHA-512": "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    "hmac SHA-512": "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
    "pbkdf2 SHA-512": "0872259b55ef1e4baed06e960abdc6bd0cbf2b9e6aae84a5",
    "hkdf SHA-512": "f2fcf7c5c08479351749eb125e9febb6ead03efddc210067de2932bdcc4cbdbc018e19be9bb34989ee35",
    "hkdf nosalt": "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
    "gcm 16": "e89e531f8f7e10f282954128a49309430a0df95c68da63bf2e3a16963d0d26178d0dc331560c84bac051405b5ec6808c6231b9c9fdec54c1ff4463",
    "cbc 16": "64aacef0b1a075680f052c7c780b017ed42f4ac30ebc71572c7d02c3eefea5fc6e5dc82da73f8f784bb84f7448b14256",
    "ctr 16": "b9a40107d9ecb3e0be6ad2716090b387868a2c8ee44ddb083c81f6c066229ff4c8c02e3df54e2f5220c071",
    "gcm 24": "085bf176fd24e079c9117b2a03421e062ef243cdc9100ab40b09c739be239d8171d3254a7634131acb5005c86a6828ebd002f3274790d8c3a41fd8",
    "cbc 24": "fe958e1adfaf0338c4afe524b5dec193ac372197ebd17aad50c85b5fc4e298a07d28d2432e3fff92357fb5998b72915d",
    "ctr 24": "d5ab874671b3185c0d4604d0c503cefa6e86aa2821cd556d382a1e166f96a79141fd9186bd96595274f92b",
    "gcm 32": "21d218ef264a82e6da733b336ad3fbf71f1a8d24338acfb55a27a70dbad038a80fbda8d053da7f62a854f51dc76c7930afb7832615e2155a509023",
    "cbc 32": "7167fb9e4737ffed3ab8277c976c4875f848ed00baadfb04356cca3b3af9b0dac5584c06039e39f7fe3e6e925e34561c",
    "ctr 32": "c0547da35b74032dcd2eb0d9425337b892659892ec2742b2fcba48b1cdad98063ed1d062907916e66ab2bb",
    "gcm tag96": "404434e9de5998ba45a955b694b6e35ad47da2493b0412e52a27a5a0d98c281ed0e1ec91eecb27b971b40df1586cca75f39126ce601539",
    "gcm iv16 empty": "0373131b76cd99e6f061e3008e927a66",
    "ctr wrap8": "ea3d90d20afcb46f55119859bdcb0a5116fd6155124b85ddd3be26a9d620e46baeca4259061c32ac1787a222f50fbad7c6b7e6161105f8d4e46a39a7d4aad0902d5bbaa574ee39e9d4ccf7d0bfeeb2c4",
    "ctr wrap128": "1424c235b2749976b879a8629d88727adaf085102fb8101758702aaecef3aa259b7b0718abc39f6d1e2a5d4652d489f2",
};

const HASHES = ["SHA-1", "SHA-256", "SHA-384", "SHA-512"];
const pt = enc.encode("The quick brown fox jumps over the lazy dog");
const aesKey = (name, len) => s.importKey("raw", bytes(len, (i) => i + 1), name, true, ["encrypt", "decrypt"]);

test("digest matches known answers", async () => {
    for (const h of HASHES) assertEquals(hex(await s.digest(h, enc.encode("abc"))), VECTORS["digest " + h]);
    assertEquals(hex(await s.digest({ name: "sha-256" }, new Uint8Array(0))), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
});

test("HMAC signs, verifies and rejects a changed message", async () => {
    for (const h of HASHES) {
        const key = await s.importKey("raw", enc.encode("Jefe"), { name: "HMAC", hash: h }, false, ["sign", "verify"]);
        const msg = enc.encode("what do ya want for nothing?");
        const mac = await s.sign("HMAC", key, msg);
        assertEquals(hex(mac), VECTORS["hmac " + h]);
        assert(await s.verify("HMAC", key, mac, msg));
        assert(!(await s.verify("HMAC", key, mac, enc.encode("other"))));
        assert(!(await s.verify("HMAC", key, new Uint8Array(3), msg)));
    }
});

test("PBKDF2 and HKDF match known answers", async () => {
    const pw = await s.importKey("raw", enc.encode("password"), "PBKDF2", false, ["deriveBits", "deriveKey"]);
    const ikm = await s.importKey("raw", new Uint8Array(22).fill(0x0b), "HKDF", false, ["deriveBits"]);
    for (const h of HASHES) {
        assertEquals(hex(await s.deriveBits({ name: "PBKDF2", hash: h, salt: enc.encode("salt"), iterations: 50 }, pw, 192)), VECTORS["pbkdf2 " + h]);
        const salt = bytes(13, (i) => i), info = new Uint8Array([0xf0, 0xf1, 0xf2]);
        assertEquals(hex(await s.deriveBits({ name: "HKDF", hash: h, salt, info }, ikm, 336)), VECTORS["hkdf " + h]);
    }
    assertEquals(hex(await s.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new Uint8Array(0) }, ikm, 336)), VECTORS["hkdf nosalt"]);
});

test("deriveKey yields a usable AES key", async () => {
    const pw = await s.importKey("raw", enc.encode("password"), "PBKDF2", false, ["deriveKey", "deriveBits"]);
    const key = await s.deriveKey({ name: "PBKDF2", hash: "SHA-256", salt: enc.encode("salt"), iterations: 10 }, pw, { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
    assertEquals(key.algorithm.length, 256);
    assertEquals(hex(await s.exportKey("raw", key)), hex(await s.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: enc.encode("salt"), iterations: 10 }, pw, 256)));
});

test("AES-GCM, CBC and CTR match known answers and round trip", async () => {
    for (const len of [16, 24, 32]) {
        const gcm = { name: "AES-GCM", iv: new Uint8Array(12).fill(9), additionalData: enc.encode("hdr") };
        const cbc = { name: "AES-CBC", iv: new Uint8Array(16).fill(3) };
        const ctr = { name: "AES-CTR", counter: new Uint8Array(16).fill(1), length: 64 };
        for (const [label, alg] of [["gcm", gcm], ["cbc", cbc], ["ctr", ctr]]) {
            const key = await aesKey(alg.name, len);
            const ct = await s.encrypt(alg, key, pt);
            assertEquals(hex(ct), VECTORS[`${label} ${len}`]);
            assertEquals(hex(await s.decrypt(alg, key, ct)), hex(pt));
        }
    }
});

test("AES-GCM tag length, odd IV and empty plaintext", async () => {
    const key = await aesKey("AES-GCM", 16);
    const short = await s.encrypt({ name: "AES-GCM", iv: new Uint8Array(12), tagLength: 96 }, key, pt);
    assertEquals(hex(short), VECTORS["gcm tag96"]);
    assertEquals(hex(await s.decrypt({ name: "AES-GCM", iv: new Uint8Array(12), tagLength: 96 }, key, short)), hex(pt));
    const empty = await s.encrypt({ name: "AES-GCM", iv: new Uint8Array(16).fill(5) }, key, new Uint8Array(0));
    assertEquals(hex(empty), VECTORS["gcm iv16 empty"]);
    assertEquals((await s.decrypt({ name: "AES-GCM", iv: new Uint8Array(16).fill(5) }, key, empty)).byteLength, 0);
});

test("AES-GCM rejects tampering and a wrong key", async () => {
    const key = await aesKey("AES-GCM", 16);
    const alg = { name: "AES-GCM", iv: new Uint8Array(12) };
    const ct = new Uint8Array(await s.encrypt(alg, key, pt));
    ct[0] ^= 1;
    await rejects("OperationError", () => s.decrypt(alg, key, ct));
    ct[0] ^= 1;
    await rejects("OperationError", () => s.decrypt({ ...alg, additionalData: enc.encode("x") }, key, ct));
    const wrong = await s.importKey("raw", new Uint8Array(16), "AES-GCM", false, ["decrypt"]);
    await rejects("OperationError", () => s.decrypt(alg, wrong, ct));
    await rejects("OperationError", () => s.decrypt(alg, key, new Uint8Array(3)));
});

test("AES-CBC pads, and rejects bad padding", async () => {
    const key = await aesKey("AES-CBC", 16);
    const alg = { name: "AES-CBC", iv: new Uint8Array(16) };
    assertEquals((await s.encrypt(alg, key, new Uint8Array(16))).byteLength, 32);
    assertEquals((await s.encrypt(alg, key, new Uint8Array(0))).byteLength, 16);
    await rejects("OperationError", () => s.decrypt(alg, key, new Uint8Array(15)));
    await rejects("OperationError", () => s.decrypt(alg, key, new Uint8Array(16)));
    await rejects("OperationError", () => s.encrypt({ name: "AES-CBC", iv: new Uint8Array(8) }, key, pt));
});

test("AES-CTR counter wraps at its length", async () => {
    const key = await aesKey("AES-CTR", 16);
    const c8 = new Uint8Array(16).fill(0xaa); c8[15] = 0xfe;
    const ct = await s.encrypt({ name: "AES-CTR", counter: c8, length: 8 }, key, new Uint8Array(80).fill(0x55));
    assertEquals(hex(ct), VECTORS["ctr wrap8"]);
    const full = await s.encrypt({ name: "AES-CTR", counter: new Uint8Array(16).fill(0xff), length: 128 }, key, new Uint8Array(48).fill(1));
    assertEquals(hex(full), VECTORS["ctr wrap128"]);
    // 8 counter bits allow 256 blocks; one more would repeat the keystream.
    await rejects("OperationError", () => s.encrypt({ name: "AES-CTR", counter: new Uint8Array(16), length: 8 }, key, new Uint8Array(16 * 257)));
    await rejects("OperationError", () => s.encrypt({ name: "AES-CTR", counter: new Uint8Array(16), length: 0 }, key, pt));
});

test("keys: generate, export and import raw and jwk", async () => {
    const key = await s.generateKey({ name: "AES-GCM", length: 256 }, true, ["decrypt", "encrypt"]);
    assertEquals(String(key), "[object CryptoKey]");
    assertEquals(key.type, "secret");
    assertEquals(key.usages.join(), "encrypt,decrypt");
    const raw = await s.exportKey("raw", key);
    assertEquals(raw.byteLength, 32);
    const jwk = await s.exportKey("jwk", key);
    assertEquals(jwk.kty, "oct");
    assertEquals(jwk.alg, "A256GCM");
    assertEquals(jwk.ext, true);
    const back = await s.importKey("jwk", jwk, "AES-GCM", true, ["encrypt"]);
    assertEquals(hex(await s.exportKey("raw", back)), hex(raw));

    const mac = await s.generateKey({ name: "HMAC", hash: "SHA-384" }, true, ["sign"]);
    assertEquals((await s.exportKey("raw", mac)).byteLength, 128);
    assertEquals(mac.algorithm.hash.name, "SHA-384");
    assertEquals((await s.exportKey("jwk", mac)).alg, "HS384");
    const short = await s.generateKey({ name: "HMAC", hash: "SHA-256", length: 100 }, true, ["sign"]);
    assertEquals((await s.exportKey("raw", short)).byteLength, 13);
});

test("keys: usage, algorithm and extractable checks", async () => {
    const key = await s.importKey("raw", new Uint8Array(16), "AES-GCM", false, ["encrypt"]);
    await rejects("InvalidAccessError", () => s.exportKey("raw", key));
    await rejects("InvalidAccessError", () => s.decrypt({ name: "AES-GCM", iv: new Uint8Array(12) }, key, new Uint8Array(32)));
    await rejects("InvalidAccessError", () => s.encrypt({ name: "AES-CBC", iv: new Uint8Array(16) }, key, pt));
    await rejects("SyntaxError", () => s.importKey("raw", new Uint8Array(16), "AES-GCM", true, []));
    await rejects("SyntaxError", () => s.importKey("raw", new Uint8Array(16), "AES-GCM", true, ["sign"]));
    await rejects("DataError", () => s.importKey("raw", new Uint8Array(15), "AES-GCM", true, ["encrypt"]));
    await rejects("DataError", () => s.importKey("raw", new Uint8Array(0), { name: "HMAC", hash: "SHA-256" }, true, ["sign"]));
    await rejects("SyntaxError", () => s.importKey("raw", new Uint8Array(8), "PBKDF2", true, ["deriveBits"]));
    await rejects("InvalidAccessError", async () => s.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(1), iterations: 1 }, await s.importKey("raw", new Uint8Array(8), "PBKDF2", false, ["deriveKey"]), 8));
    await rejects("DataError", () => s.importKey("jwk", { kty: "oct", k: "AAAAAAAAAAAAAAAAAAAAAA", alg: "A128CBC" }, "AES-GCM", true, ["encrypt"]));
    await rejects("DataError", () => s.importKey("jwk", { kty: "oct", k: "AAAAAAAAAAAAAAAAAAAAAA", ext: false }, "AES-GCM", true, ["encrypt"]));
    await rejects("DataError", () => s.importKey("jwk", { kty: "oct", k: "AAAAAAAAAAAAAAAAAAAAAA", key_ops: ["decrypt"] }, "AES-GCM", true, ["encrypt"]));
    await rejects("DataError", () => s.importKey("jwk", { kty: "RSA", k: "AA" }, "AES-GCM", true, ["encrypt"]));
    assert(new Uint8Array(await s.exportKey("raw", await s.importKey("raw", new Uint8Array(16), "AES-GCM", true, ["encrypt"]))).every((b) => b === 0));
    let threw = false;
    try { new key.constructor(); } catch (e) { threw = e instanceof TypeError; }
    assert(threw, "CryptoKey cannot be constructed");
});

test("unknown and unimplemented algorithms are NotSupportedError", async () => {
    await rejects("NotSupportedError", () => s.digest("MD5", pt));
    await rejects("NotSupportedError", () => s.digest("HMAC", pt));
    await rejects("NotSupportedError", () => s.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]));
    await rejects("NotSupportedError", () => s.generateKey({ name: "RSA-OAEP" }, true, ["encrypt"]));
    await rejects("NotSupportedError", () => s.generateKey("Nope", true, ["sign"]));
    await rejects("NotSupportedError", () => s.importKey("spki", new Uint8Array(4), "AES-GCM", true, ["encrypt"]));
    await rejects("NotSupportedError", () => s.wrapKey("raw", null, null, "AES-KW"));
});

test("arguments are validated with TypeError", async () => {
    await rejects("TypeError", () => s.digest("SHA-256", "text"));
    await rejects("TypeError", () => s.digest("SHA-256"));
    await rejects("TypeError", () => s.sign("HMAC", {}, pt));
    const key = await aesKey("AES-GCM", 16);
    await rejects("TypeError", () => s.encrypt({ name: "AES-GCM" }, key, pt));
});

test("PBKDF2 bounds", async () => {
    const pw = await s.importKey("raw", enc.encode("p"), "PBKDF2", false, ["deriveBits"]);
    const alg = { name: "PBKDF2", hash: "SHA-1", salt: new Uint8Array(1), iterations: 1 };
    assertEquals((await s.deriveBits(alg, pw, 8)).byteLength, 1);
    await rejects("OperationError", () => s.deriveBits({ ...alg, iterations: 0 }, pw, 8));
    await rejects("OperationError", () => s.deriveBits(alg, pw, 7));
    await rejects("OperationError", () => s.deriveBits({ ...alg, iterations: 100000000 }, pw, 8));
});

test("crypto.subtle is also on the global crypto", async () => {
    assert(globalThis.crypto.subtle === subtle);
    assertEquals(hex(await crypto.subtle.digest("SHA-1", enc.encode("abc"))), VECTORS["digest SHA-1"]);
});
