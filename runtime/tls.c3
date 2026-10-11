// Client TLS on uSockets' OpenSSL contexts. uSockets sets neither SNI nor
// hostname checks for clients, so both are added here per connection.
module bkr;

extern fn CInt ssl_ctx_set_default_verify_paths(void* ctx) @cname("SSL_CTX_set_default_verify_paths");
extern fn void ssl_ctx_set_verify(void* ctx, CInt mode, void* cb) @cname("SSL_CTX_set_verify");
extern fn long ssl_ctrl(void* ssl, CInt cmd, long larg, void* parg) @cname("SSL_ctrl");
extern fn CInt ssl_set1_host(void* ssl, ZString host) @cname("SSL_set1_host");
extern fn CInt ssl_set_ex_data(void* ssl, CInt idx, void* data) @cname("SSL_set_ex_data");
extern fn void* ssl_get_ex_data(void* ssl, CInt idx) @cname("SSL_get_ex_data");
extern fn CInt ssl_get_ex_data_x509_store_ctx_idx() @cname("SSL_get_ex_data_X509_STORE_CTX_idx");
extern fn void* x509_store_ctx_get_ex_data(void* store, CInt idx) @cname("X509_STORE_CTX_get_ex_data");
extern fn CInt crypto_get_ex_new_index(
    CInt class_index,
    long argl,
    void* argp,
    void* new_fn,
    void* dup_fn,
    void* free_fn
) @cname("CRYPTO_get_ex_new_index");

const CInt SSL_VERIFY_PEER              = 1;
const CInt SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
const CInt CRYPTO_EX_INDEX_SSL          = 0;

CInt g_res_index = -1;

fn CInt verify_cb(CInt ok, void* store) {
    if (ok) return ok;
    void* ssl = x509_store_ctx_get_ex_data(store, ssl_get_ex_data_x509_store_ctx_idx());
    Res* r    = ssl_get_ex_data(ssl, g_res_index);
    if (r) r.cert_failed = true;
    return ok;
}

fn void tls_client_init(UsContext* ctx) {
    void* sctx = us_socket_context_get_native_handle(1, ctx);
    ssl_ctx_set_default_verify_paths(sctx);
    ssl_ctx_set_verify(sctx, SSL_VERIFY_PEER, &verify_cb);
    if (g_res_index < 0) g_res_index = crypto_get_ex_new_index(CRYPTO_EX_INDEX_SSL, 0, null, null, null, null);
}

fn void tls_client_setup(Res* r) {
    void* ssl    = us_socket_get_native_handle(1, r.sock);
    ZString host = r.host.zstr_tcopy();
    ssl_set_ex_data(ssl, g_res_index, r);
    ssl_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, host);
    ssl_set1_host(ssl, host);
}