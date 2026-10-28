/* The C side of pond_save.goose: one ECDSA P-256 SHA-256 check through
   libcrypto. The EVP calls here are the same in LibreSSL (OpenBSD base)
   and in OpenSSL. pub_der is a SubjectPublicKeyInfo in DER, as CryptoKit's
   derRepresentation writes it; sig_der is an ECDSA-Sig-Value in DER. A
   Goose bool is a uint8_t in C. */
#include <openssl/evp.h>
#include <openssl/x509.h>

uint8_t pond_verify_p256(sl_u8 pub_der, sl_u8 msg, sl_u8 sig_der) {
    const unsigned char *p = pub_der.data;
    EVP_PKEY *key = d2i_PUBKEY(NULL, &p, (long)pub_der.len);
    if (key == NULL) return 0;
    uint8_t ok = 0;
    if (EVP_PKEY_base_id(key) == EVP_PKEY_EC && EVP_PKEY_bits(key) == 256) {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        ok = ctx != NULL
            && EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, key) == 1
            && EVP_DigestVerify(ctx, sig_der.data, (size_t)sig_der.len, msg.data, (size_t)msg.len) == 1;
        EVP_MD_CTX_free(ctx);
    }
    EVP_PKEY_free(key);
    return ok;
}
