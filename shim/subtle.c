// The primitives behind crypto.subtle: digests, HMAC, PBKDF2, HKDF and AES
// (GCM, CBC, CTR) over OpenSSL's EVP interface. Each call takes flat byte
// buffers and no JavaScript, so the runtime can run it on the thread pool.
// The caller checks that OpenSSL loaded (bkr_openssl_available) first.
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <stddef.h>
#include <stdint.h>

enum { BKR_OK = 0, BKR_FAIL = 1, BKR_BAD = 2 };
enum { MODE_GCM = 1, MODE_CBC = 2, MODE_CTR = 3 };

static const EVP_MD *hash_of(int h) {
    switch (h) {
    case 1: return EVP_sha1();
    case 2: return EVP_sha256();
    case 3: return EVP_sha384();
    case 4: return EVP_sha512();
    }
    return NULL;
}

// Empty inputs may arrive as NULL; OpenSSL wants a valid pointer.
static const uint8_t *nz(const uint8_t *p) { return p ? p : (const uint8_t *)""; }

// out holds 64 bytes.
int bkr_subtle_digest(int h, const uint8_t *in, size_t n, uint8_t *out, size_t *outlen) {
    const EVP_MD *md = hash_of(h);
    if (!md) return BKR_BAD;
    unsigned int len = 0;
    if (!EVP_Digest(nz(in), n, out, &len, md, NULL)) return BKR_FAIL;
    *outlen = len;
    return BKR_OK;
}

int bkr_subtle_hmac(int h, const uint8_t *key, size_t klen, const uint8_t *in, size_t n,
                    uint8_t *out, size_t *outlen) {
    const EVP_MD *md = hash_of(h);
    if (!md) return BKR_BAD;
    unsigned int len = 0;
    if (!HMAC(md, nz(key), (int)klen, nz(in), n, out, &len)) return BKR_FAIL;
    *outlen = len;
    return BKR_OK;
}

int bkr_subtle_pbkdf2(int h, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen,
                      uint32_t iterations, uint8_t *out, size_t outlen) {
    const EVP_MD *md = hash_of(h);
    if (!md) return BKR_BAD;
    if (!PKCS5_PBKDF2_HMAC((const char *)nz(pw), (int)pwlen, nz(salt), (int)saltlen, (int)iterations,
                           md, (int)outlen, out)) return BKR_FAIL;
    return BKR_OK;
}

int bkr_subtle_hkdf(int h, const uint8_t *ikm, size_t ikmlen, const uint8_t *salt, size_t saltlen,
                    const uint8_t *info, size_t infolen, uint8_t *out, size_t outlen) {
    const EVP_MD *md = hash_of(h);
    if (!md) return BKR_BAD;
    EVP_KDF *kdf = EVP_KDF_fetch(NULL, "HKDF", NULL);
    if (!kdf) return BKR_FAIL;
    EVP_KDF_CTX *ctx = EVP_KDF_CTX_new(kdf);
    EVP_KDF_free(kdf);
    if (!ctx) return BKR_FAIL;
    OSSL_PARAM params[6];
    int i = 0;
    params[i++] = OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST, (char *)EVP_MD_get0_name(md), 0);
    params[i++] = OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_KEY, (void *)nz(ikm), ikmlen);
    if (saltlen) params[i++] = OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, (void *)salt, saltlen);
    if (infolen) params[i++] = OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_INFO, (void *)info, infolen);
    params[i] = OSSL_PARAM_construct_end();
    int ok = EVP_KDF_derive(ctx, out, outlen, params) > 0;
    EVP_KDF_CTX_free(ctx);
    return ok ? BKR_OK : BKR_FAIL;
}

static const EVP_CIPHER *cipher_of(int mode, size_t klen) {
    switch (mode) {
    case MODE_GCM:
        return klen == 16 ? EVP_aes_128_gcm() : klen == 24 ? EVP_aes_192_gcm() : klen == 32 ? EVP_aes_256_gcm() : NULL;
    case MODE_CBC:
        return klen == 16 ? EVP_aes_128_cbc() : klen == 24 ? EVP_aes_192_cbc() : klen == 32 ? EVP_aes_256_cbc() : NULL;
    case MODE_CTR:
        return klen == 16 ? EVP_aes_128_ctr() : klen == 24 ? EVP_aes_192_ctr() : klen == 32 ? EVP_aes_256_ctr() : NULL;
    }
    return NULL;
}

static int gcm(int enc, const EVP_CIPHER *c, const uint8_t *key, const uint8_t *iv, size_t ivlen,
               const uint8_t *aad, size_t aadlen, const uint8_t *in, size_t n,
               uint8_t *out, size_t *outlen, int taglen) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return BKR_FAIL;
    int rc = BKR_FAIL, l = 0;
    size_t total = 0;
    if (!EVP_CipherInit_ex(ctx, c, NULL, NULL, NULL, enc)) goto done;
    if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)ivlen, NULL)) goto done;
    if (!EVP_CipherInit_ex(ctx, NULL, NULL, key, iv, enc)) goto done;
    if (!enc) {
        if (n < (size_t)taglen) goto done;
        n -= taglen;
        // The tag is the last taglen bytes of the input.
        if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, taglen, (void *)(in + n))) goto done;
    }
    if (aadlen && !EVP_CipherUpdate(ctx, NULL, &l, aad, (int)aadlen)) goto done;
    if (n && !EVP_CipherUpdate(ctx, out, &l, in, (int)n)) goto done;
    total = n ? (size_t)l : 0;
    if (!EVP_CipherFinal_ex(ctx, out + total, &l)) goto done;
    total += l;
    if (enc) {
        if (!EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, taglen, out + total)) goto done;
        total += taglen;
    }
    *outlen = total;
    rc = BKR_OK;
done:
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

static int cbc(int enc, const EVP_CIPHER *c, const uint8_t *key, const uint8_t *iv, const uint8_t *in,
               size_t n, uint8_t *out, size_t *outlen) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return BKR_FAIL;
    int rc = BKR_FAIL, l = 0;
    size_t total = 0;
    if (!EVP_CipherInit_ex(ctx, c, NULL, key, iv, enc)) goto done;
    if (n && !EVP_CipherUpdate(ctx, out, &l, in, (int)n)) goto done;
    total = n ? (size_t)l : 0;
    if (!EVP_CipherFinal_ex(ctx, out + total, &l)) goto done;
    *outlen = total + l;
    rc = BKR_OK;
done:
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

typedef unsigned __int128 u128;

static u128 load_be(const uint8_t *p) {
    u128 v = 0;
    for (int i = 0; i < 16; i++) v = (v << 8) | p[i];
    return v;
}

static void store_be(u128 v, uint8_t *p) {
    for (int i = 15; i >= 0; i--) { p[i] = (uint8_t)v; v >>= 8; }
}

// WebCrypto's counter is only the low ctrbits of the block and wraps there,
// where OpenSSL carries through all 128 bits. Run up to each wrap point and
// restart with the low bits cleared.
static int ctr(const EVP_CIPHER *c, const uint8_t *key, const uint8_t *iv, int ctrbits,
               const uint8_t *in, size_t n, uint8_t *out, size_t *outlen) {
    if (ctrbits < 1 || ctrbits > 128) return BKR_BAD;
    u128 mask = ctrbits == 128 ? ~(u128)0 : (((u128)1 << ctrbits) - 1);
    u128 block = load_be(iv);
    size_t blocks = (n + 15) / 16;
    if (ctrbits < 64 && (u128)blocks > ((u128)1 << ctrbits)) return BKR_FAIL;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return BKR_FAIL;
    int rc = BKR_FAIL;
    size_t done = 0;
    while (done < n) {
        u128 left = (mask - (block & mask)) + 1; // blocks before the counter wraps; 0 means all 2^128
        size_t chunk = n - done;
        if (left != 0 && left < (u128)((chunk + 15) / 16)) chunk = (size_t)left * 16;
        uint8_t cur[16];
        store_be(block, cur);
        int l = 0, l2 = 0;
        if (!EVP_EncryptInit_ex(ctx, c, NULL, key, cur)) goto fail;
        if (!EVP_EncryptUpdate(ctx, out + done, &l, in + done, (int)chunk)) goto fail;
        if (!EVP_EncryptFinal_ex(ctx, out + done + l, &l2)) goto fail;
        done += chunk;
        block = block & ~mask;
    }
    *outlen = n;
    rc = BKR_OK;
fail:
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

// out needs n + 32 bytes. For CTR, ivlen is 16 and ctrbits the counter width;
// for GCM, taglen is in bytes.
int bkr_subtle_aes(int mode, int enc, const uint8_t *key, size_t klen, const uint8_t *iv, size_t ivlen,
                   const uint8_t *aad, size_t aadlen, const uint8_t *in, size_t n,
                   uint8_t *out, size_t *outlen, int taglen, int ctrbits) {
    const EVP_CIPHER *c = cipher_of(mode, klen);
    if (!c) return BKR_BAD;
    in = nz(in);
    switch (mode) {
    case MODE_GCM:
        if (!ivlen || taglen < 4 || taglen > 16) return BKR_BAD;
        return gcm(enc, c, key, iv, ivlen, aad, aadlen, in, n, out, outlen, taglen);
    case MODE_CBC:
        if (ivlen != 16) return BKR_BAD;
        return cbc(enc, c, key, iv, in, n, out, outlen);
    case MODE_CTR:
        if (ivlen != 16) return BKR_BAD;
        return ctr(c, key, iv, ctrbits, in, n, out, outlen);
    }
    return BKR_BAD;
}
