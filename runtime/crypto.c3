// Password hashing uses C3's Argon2id on the pool. Limit expensive jobs so
// untrusted requests cannot allocate an unbounded number of 19 MiB arenas.
module bkr;

import boomkat;
import std::crypto::argon2;
import std::hash::sha256;

extern fn CInt crypto_memcmp(void* a, void* b, usz len) @cname("CRYPTO_memcmp");

const String PASSWORD_PREFIX = "$argon2id$v=19$m=19456,t=2,p=1$";
const uint MAX_PASSWORD_JOBS = 2;
uint g_password_jobs;

struct PasswordTask {
    inline Task task;
    uint op;
    char[] password;
    String encoded;
    String result;
    bool verify;
    bool valid;
}

fn bool password_format(String encoded) {
    usz salt_chars;
    if (encoded.len == PASSWORD_PREFIX.len + 22 + 1 + 43) { salt_chars = 22; }
    else if (encoded.len == PASSWORD_PREFIX.len + 43 + 1 + 43) { salt_chars = 43; }
    else { return false; }
    if (!encoded.starts_with(PASSWORD_PREFIX) || encoded[PASSWORD_PREFIX.len + salt_chars] != '$') return false;
    for (usz i = PASSWORD_PREFIX.len; i < encoded.len; i++) {
        if (i == PASSWORD_PREFIX.len + salt_chars) continue;
        char c = encoded[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+'
            || c == '/')) return false;
    }
    return true;
}

// Give Argon2 a private arena, destroyed after this job. Otherwise its
// large scratch allocation could linger in each of the pool's 16 workers.
fn void password_work(Task* task) {
    Allocator old_temp     = tmem;
    TempAllocator* old_top = allocators::top_temp;
    TempAllocator* arena   = allocators::new_temp_allocator(mem, 64 * 1024)!!;
    allocators::current_temp = arena;
    allocators::top_temp = arena;
    defer {
        allocators::current_temp = old_temp;
        allocators::top_temp = old_top;
        arena.free();
    }
    PasswordTask* p = (PasswordTask*)task;
    defer mem::zero_volatile(p.password);
    char[32] digest;
    defer mem::zero_volatile(digest[..]);
    if (p.verify) {
        if (try decoded = argon2::decode(mem, p.encoded)) {
            defer decoded.free();
            if (decoded.version != 19 || decoded.algorithm != Argon2Algorithm.ARGON2_ID || decoded.mem_size != 19456
                || decoded.iterations != 2
                || decoded.lanes != 1
                || (decoded.salt.len != 16 && decoded.salt.len != 32)
                || decoded.hash.len != 32
                || decoded.key.len
                || decoded.assoc.len
                || decoded.key_id.len) return;
            argon2::hash_raw(digest[..], p.password, decoded.opts);
            p.valid = crypto_memcmp(&digest, decoded.hash.ptr, digest.len) == 0;
        }
        return;
    }
    char[32] salt;
    arc4random_buf(&salt, salt.len);
    Argon2Options opts = {
        .algorithm = Argon2Algorithm.ARGON2_ID,
        .salt = salt[..],
        .lanes = 1,
        .mem_size = 19456,
        .iterations = 2
    };
    argon2::hash_raw(digest[..], p.password, opts);
    p.result = argon2::encode(mem, digest[..], opts);
}

fn void password_done(Task* task) {
    PasswordTask* p = (PasswordTask*)task;
    g_password_jobs--;
    defer {
        free(p.password.ptr);
        free(p.encoded.ptr);
        free(p.result.ptr);
        free(p);
    }
    if (p.verify) {
        g_rt.@scope() {
            resolve(p.op, g_rt.boolean(p.valid) ?? { });
        };
    } else {
        resolve_string(p.op, p.result);
    }
}

fn void js_crypto_password(JsCtx ctx, void* udata) {
    @pool() {
        uint op = ctx.arg(0).id();
        if (!ctx.arg(1).tv.is_string()) {
            reject(op, "TYPE_ERROR", "password must be a string");
            return;
        }
        char[] password = ctx.arg(1).bytes();
        if (password.len > 4096) {
            reject(op, "RANGE_ERROR", "password exceeds 4096 UTF-8 bytes");
            return;
        }
        bool verify = !ctx.arg(2).tv.is_null();
        String encoded;
        if (verify) {
            if (!ctx.arg(2).tv.is_string()) {
                reject(op, "TYPE_ERROR", "encoded hash must be a string");
                return;
            }
            encoded = (String)ctx.arg(2).bytes();
            if (!password_format(encoded)) {
                g_rt.@scope() {
                    resolve(op, g_rt.boolean(false) ?? { });
                };
                return;
            }
        }
        if (g_password_jobs >= MAX_PASSWORD_JOBS) {
            reject(op, "BUSY", "password hashing workers are busy");
            return;
        }
        PasswordTask* p = mem::new(PasswordTask);
        p.task = { .work = &password_work, .done = &password_done };
        p.op = op;
        p.password = copy_bytes(password);
        p.encoded = (String)copy_bytes(encoded);
        p.verify = verify;
        g_password_jobs++;
        submit(p);
    };
}

fn void js_crypto_random(JsCtx ctx, void* udata) {
    double size = ctx.arg(0).as_number() ?? -1;
    if (!(size >= 0 && size <= 65536) || size != (double)(uint)size) {
        ctx.throw_error(RANGE, "size must be an integer from 0 to 65536");
        return;
    }
    char[] bytes = size ? mem::alloc_array(char, (sz)size) : (char[]) { };
    if (bytes.len) arc4random_buf(bytes.ptr, bytes.len);
    ctx.ret_bytes(bytes);
}

fn void js_crypto_sha256(JsCtx ctx, void* udata) {
    @pool() {
        if (!ctx.arg(0).tv.is_string() && !ctx.arg(0).is_bytes()) {
            ctx.throw_error(TYPE, "sha256 expects a string or bytes");
            return;
        }
        char[32] digest = sha256::hash(ctx.arg(0).bytes());
        ctx.ret_bytes(copy_bytes(digest[..]));
    };
}

fn void js_crypto_equal(JsCtx ctx, void* udata) {
    if (!ctx.arg(0).is_bytes() || !ctx.arg(1).is_bytes()) {
        ctx.throw_error(TYPE, "timingSafeEqual expects byte buffers");
        return;
    }
    char[] a = ctx.arg(0).bytes();
    char[] b = ctx.arg(1).bytes();
    ctx.ret_bool(a.len == b.len && (!a.len || crypto_memcmp(a.ptr, b.ptr, a.len) == 0));
}

fn void js_crypto_hex(JsCtx ctx, void* udata) {
    JsArg bytes = ctx.arg(0);
    if (!bytes.is_bytes() || ((HObject*)bytes.tv.get_heapptr()).get_class() != UINT8ARRAY) {
        return;
    }
    HObject* view = bytes.tv.get_heapptr();
    if (!builtins::is_symbol_val(ctx.arg(2).tv)) return;
    void* iterator = ctx.arg(2).tv.get_heapptr();
    HObject* owner = view;
    bool found;
    for (uint depth = 0; owner && depth < 32; depth++, owner = owner.prototype) {
        if (owner.flags.exotic_proxyobj) return;
        int slot = owner.find_prop_idx(iterator, ctx.ctx.heap);
        if (slot < 0) continue;
        if (owner.get_prop_flags((uint)slot, ctx.ctx.heap)
            .is_accessor || owner.prop_values()[slot].get().get_raw_bits() != ctx.arg(1).tv.get_raw_bits()) return;
        found = true;
        break;
    }
    if (!found) return;
    if (builtins::view_is_out_of_bounds(view)) {
        return ctx.throw_error(TYPE, "cannot encode a detached or out-of-bounds byte buffer");
    }
    @pool() {
        char[] data = bytes.bytes();
        if (data.len > int::max / 2) return ctx.throw_error(RANGE, "hex output is too large");
        const String DIGITS = "0123456789abcdef";
        char[] out          = mem::temp_array(char, data.len * 2);
        foreach (i, byte : data) {
            out[2 * i] = DIGITS[(uint)byte >> 4];
            out[2 * i + 1] = DIGITS[(uint)byte & 15];
        }
        ctx.ret_string((String)out);
    };
}

const Native[] CRYPTO_NATIVES = {
    { "cryptoRandom", &js_crypto_random, 1 },
    { "cryptoSha256", &js_crypto_sha256, 1 },
    { "cryptoEqual", &js_crypto_equal, 2 },
    { "cryptoHex", &js_crypto_hex, 3 },
    { "cryptoPassword", &js_crypto_password, 3 },
};