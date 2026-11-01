// Reports whether OpenSSL is usable. The dylibs are weak-linked, so when they
// are missing at launch these symbols resolve to null instead of stopping the
// process, and TLS callers check this before creating any SSL context.
#include <stddef.h>

#if defined(__APPLE__)
#define BKR_WEAK __attribute__((weak_import))
#else
#define BKR_WEAK __attribute__((weak))
#endif

void *SSL_CTX_new(const void *method) BKR_WEAK;
void *CRYPTO_get_ex_new_index(int class_index, long argl, void *argp, void *new_func, void *dup_func, void *free_func) BKR_WEAK;

int bkr_openssl_available(void) {
    return SSL_CTX_new != NULL && CRYPTO_get_ex_new_index != NULL;
}
