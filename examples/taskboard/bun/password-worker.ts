// OpenSSL permits the same 16-byte salt as Boomkat. Bun.password.hash fixes
// its salt at 32 bytes, which would make new accounts incompatible with BKR.
import { dlopen, ptr } from "bun:ffi";
import { randomBytes, timingSafeEqual } from "node:crypto";

const library =
	process.env.TASKBOARD_LIBCRYPTO ||
	(process.platform === "darwin"
		? "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
		: "libcrypto.so.3");
const { symbols: ssl } = dlopen(library, {
	EVP_KDF_fetch: { args: ["ptr", "ptr", "ptr"], returns: "ptr" },
	EVP_KDF_CTX_new: { args: ["ptr"], returns: "ptr" },
	EVP_KDF_derive: { args: ["ptr", "ptr", "u64", "ptr"], returns: "int" },
	EVP_KDF_CTX_free: { args: ["ptr"], returns: "void" },
	EVP_KDF_free: { args: ["ptr"], returns: "void" },
});
const name = Buffer.from("ARGON2ID\0");
const prefix = "$argon2id$v=19$m=19456,t=2,p=1$";

function derive(password: Buffer, salt: Buffer) {
	// OSSL_PARAM's 64-bit ABI: key pointer, type, padding, data pointer,
	// data_size and return_size. Retain all backing buffers through the call.
	const fields: [string, number, Buffer][] = [
		["pass", 5, password],
		["salt", 5, salt],
		...[
			["iter", 2],
			["lanes", 1],
			["memcost", 19456],
			["version", 19],
		].map(([key, value]) => {
			const data = Buffer.alloc(4);
			data.writeUInt32LE(Number(value));
			return [String(key), 2, data] as [string, number, Buffer];
		}),
	];
	const keys = fields.map(([key]) => Buffer.from(key + "\0"));
	const params = Buffer.alloc((fields.length + 1) * 40);
	fields.forEach(([, type, data], i) => {
		const offset = i * 40;
		params.writeBigUInt64LE(BigInt(ptr(keys[i])), offset);
		params.writeUInt32LE(type, offset + 8);
		params.writeBigUInt64LE(BigInt(ptr(data)), offset + 16);
		params.writeBigUInt64LE(BigInt(data.length), offset + 24);
		params.writeBigUInt64LE(0xffffffffffffffffn, offset + 32);
	});
	const kdf = ssl.EVP_KDF_fetch(null, ptr(name), null);
	if (!kdf) throw new Error("OpenSSL 3.2+ with Argon2id is required");
	const ctx = ssl.EVP_KDF_CTX_new(kdf);
	try {
		if (!ctx) throw new Error("Could not allocate Argon2 context");
		const digest = Buffer.alloc(32);
		if (ssl.EVP_KDF_derive(ctx, ptr(digest), 32, ptr(params)) !== 1)
			throw new Error("Argon2 derivation failed");
		return digest;
	} finally {
		if (ctx) ssl.EVP_KDF_CTX_free(ctx);
		ssl.EVP_KDF_free(kdf);
		password.fill(0);
	}
}

self.onmessage = ({ data: { password, encoded } }) => {
	try {
		const salt = encoded
			? Buffer.from(encoded.split("$")[4], "base64")
			: randomBytes(16);
		const digest = derive(Buffer.from(password), salt);
		const result = encoded
			? timingSafeEqual(digest, Buffer.from(encoded.split("$")[5], "base64"))
			: prefix +
				salt.toString("base64").replace(/=+$/, "") +
				"$" +
				digest.toString("base64").replace(/=+$/, "");
		digest.fill(0);
		self.postMessage({ result });
	} catch (error) {
		self.postMessage({ error: String(error) });
	}
};
