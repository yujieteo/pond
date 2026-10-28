/* The C side of the sync of pond_node.goose: the signature of a sync
   request with the node key, and the SHA-256 of the index hash, through
   libcrypto. The EVP calls are the same in LibreSSL and OpenSSL. A Goose
   bool is a uint8_t in C. */
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>

/* Appends the DER ECDSA P-256 SHA-256 signature of msg to out. key_pem is
   the private node key in PEM. */
uint8_t pond_sign_p256(sl_u8 key_pem, sl_u8 msg, gs_rref out) {
    BIO *bio = BIO_new_mem_buf(key_pem.data, (int)key_pem.len);
    EVP_PKEY *key = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL) : NULL;
    BIO_free(bio);
    if (key == NULL) return 0;
    uint8_t ok = 0;
    unsigned char sig[256];
    size_t n = sizeof sig;
    if (EVP_PKEY_base_id(key) == EVP_PKEY_EC && EVP_PKEY_bits(key) == 256) {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        ok = ctx != NULL
            && EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, key) == 1
            && EVP_DigestSign(ctx, sig, &n, msg.data, (size_t)msg.len) == 1;
        EVP_MD_CTX_free(ctx);
    }
    EVP_PKEY_free(key);
    if (ok) gs_bld_append(out, sig, (int64_t)n);
    return ok;
}

/* Appends the 32 bytes of the SHA-256 of msg to out. */
uint8_t pond_sha256(sl_u8 msg, gs_rref out) {
    unsigned char h[32];
    unsigned int n = 0;
    if (EVP_Digest(msg.data, (size_t)msg.len, h, &n, EVP_sha256(), NULL) != 1 || n != 32) return 0;
    gs_bld_append(out, h, 32);
    return 1;
}
