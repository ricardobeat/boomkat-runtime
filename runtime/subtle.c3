// crypto.subtle: the primitives run on the thread pool over OpenSSL (shim/subtle.c);
// runtime/js/subtle.js builds the Web Crypto surface on top. The JS source is
// evaluated on first use of crypto.subtle, so scripts that never touch it do
// not pay for parsing it.
module bkr;

import boomkat;

const String SUBTLE_SOURCE = $embed("js/subtle.js");

// Past this a single PBKDF2 call would hold a pool thread for many seconds.
const ulong MAX_PBKDF2_ITERATIONS = 20000000;

extern fn CInt bkr_subtle_digest(CInt h, char* data, usz n, char* out, usz* outlen);
extern fn CInt bkr_subtle_hmac(CInt h, char* key, usz klen, char* data, usz n, char* out, usz* outlen);
extern fn CInt bkr_subtle_pbkdf2(CInt h, char* pw, usz pwlen, char* salt, usz saltlen, uint iterations, char* out, usz outlen);
extern fn CInt bkr_subtle_hkdf(CInt h, char* ikm, usz ikmlen, char* salt, usz saltlen, char* info, usz infolen, char* out, usz outlen);
extern fn CInt bkr_subtle_aes(
    CInt mode, CInt enc, char* key, usz klen, char* iv, usz ivlen, char* aad, usz aadlen,
    char* data, usz n, char* out, usz* outlen, CInt taglen, CInt ctrbits
);

const int KIND_DIGEST = 1;
const int KIND_HMAC   = 2;
const int KIND_PBKDF2 = 3;
const int KIND_HKDF   = 4;
// 10 + mode encrypts and 20 + mode decrypts; mode is 1 GCM, 2 CBC, 3 CTR.
const int KIND_ENCRYPT = 10;
const int KIND_DECRYPT = 20;

struct SubtleTask {
    inline Task task;
    uint op;
    int kind;
    CInt hash;
    char[] key;
    char[] data;
    char[] iv;
    char[] aad;
    ulong n1;
    ulong n2;
    char[] result;
    usz result_len;
    CInt rc;
}

fn char* ptr_of(char[] b) => b.len ? b.ptr : null;

fn void subtle_work(Task* t) {
    SubtleTask* s = (SubtleTask*)t;
    usz out_len;
    switch {
        case s.kind == KIND_DIGEST:
            s.result = mem::alloc_array(char, 64);
            s.rc = bkr_subtle_digest(s.hash, ptr_of(s.data), s.data.len, s.result.ptr, &out_len);
        case s.kind == KIND_HMAC:
            s.result = mem::alloc_array(char, 64);
            s.rc = bkr_subtle_hmac(s.hash, ptr_of(s.key), s.key.len, ptr_of(s.data), s.data.len, s.result.ptr, &out_len);
        case s.kind == KIND_PBKDF2:
            out_len = (usz)s.n1;
            s.result = mem::alloc_array(char, (sz)out_len);
            s.rc = bkr_subtle_pbkdf2(
                s.hash, ptr_of(s.key), s.key.len, ptr_of(s.iv), s.iv.len, (uint)s.n2, s.result.ptr, out_len
            );
        case s.kind == KIND_HKDF:
            out_len = (usz)s.n1;
            s.result = mem::alloc_array(char, (sz)out_len);
            s.rc = bkr_subtle_hkdf(
                s.hash, ptr_of(s.key), s.key.len, ptr_of(s.iv), s.iv.len, ptr_of(s.aad), s.aad.len, s.result.ptr, out_len
            );
        case (s.kind / 10 == 1 || s.kind / 10 == 2) && s.kind % 10 >= 1 && s.kind % 10 <= 3:
            bool enc = s.kind < KIND_DECRYPT;
            CInt mode = s.kind % 10;
            s.result = mem::alloc_array(char, s.data.len + 32);
            s.rc = bkr_subtle_aes(
                mode, enc ? 1 : 0, ptr_of(s.key), s.key.len, ptr_of(s.iv), s.iv.len, ptr_of(s.aad), s.aad.len,
                ptr_of(s.data), s.data.len, s.result.ptr, &out_len, (CInt)s.n1, (CInt)s.n2
            );
        default:
            s.rc = 2;
    }
    s.result_len = out_len;
}

fn void subtle_done(Task* t) {
    SubtleTask* s = (SubtleTask*)t;
    mem::zero_volatile(s.key);
    free(s.key.ptr);
    free(s.data.ptr);
    free(s.iv.ptr);
    free(s.aad.ptr);
    defer free(s);
    if (s.rc != 0) {
        mem::zero_volatile(s.result);
        free(s.result.ptr);
        reject(s.op, s.rc == 2 ? "BAD_PARAMS" : "OPERATION_ERROR", "the cryptographic operation failed");
        return;
    }
    if (s.result_len == 0) {
        free(s.result.ptr);
        resolve_bytes(s.op, { });
        return;
    }
    resolve_bytes(s.op, s.result[:s.result_len]);
}

// cryptoSubtle(op, kind, hash, key, data, iv, aad, n1, n2) -> Uint8Array
fn void js_crypto_subtle(JsCtx ctx, void* udata) {
    @pool() {
        uint op = ctx.arg(0).id();
        if (!tls_available()) {
            reject(
                op,
                "UNAVAILABLE",
                string::tformat("crypto.subtle needs OpenSSL 3; install it with: %s", OPENSSL_HINT)
            );
            return;
        }
        SubtleTask* s = mem::new(SubtleTask);
        s.task = { .work = &subtle_work, .done = &subtle_done };
        s.op = op;
        s.kind = ctx.arg(1).as_int(0);
        s.hash = ctx.arg(2).as_int(0);
        s.key = copy_bytes(ctx.arg(3).bytes());
        s.data = copy_bytes(ctx.arg(4).bytes());
        s.iv = copy_bytes(ctx.arg(5).bytes());
        s.aad = copy_bytes(ctx.arg(6).bytes());
        s.n1 = (ulong)(ctx.arg(7).as_number() ?? 0);
        s.n2 = (ulong)(ctx.arg(8).as_number() ?? 0);
        if (s.kind == KIND_PBKDF2 && s.n2 > MAX_PBKDF2_ITERATIONS) {
            s.rc = 2;
            subtle_done(&s.task);
            return;
        }
        submit(s);
    };
}

// internal(name) -> the value of an embedded script, evaluated once per call
fn void js_internal(JsCtx ctx, void* udata) {
    String name = ctx.arg(0).as_string() ?? "";
    if (name != "subtle") {
        ctx.throw_error(TYPE, "unknown internal script");
        return;
    }
    g_runtime.rt.@scope() {
        JsValue? value = g_runtime.rt.eval(SUBTLE_SOURCE, "<subtle>");
        if (catch value) {
            ctx.throw_error(TYPE, g_runtime.rt.last_error());
            return;
        }
        JsArg result;
        g_runtime.rt.load(value, &result.tv);
        ctx.ret(result);
    };
}

const Native[] SUBTLE_NATIVES = {
    { "cryptoSubtle", &js_crypto_subtle, 9 },
    { "internal", &js_internal, 1 },
};
