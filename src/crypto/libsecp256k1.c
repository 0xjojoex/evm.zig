#include <stddef.h>
#include <string.h>

#include "secp256k1.h"
#include "secp256k1_recovery.h"

#if defined(__GNUC__)
__attribute__((visibility("default")))
#endif
int evmz_libsecp256k1_ecrecover(
    const unsigned char message_hash[32],
    const unsigned char r[32],
    const unsigned char s[32],
    int recovery_id,
    unsigned char output[64]
) {
    unsigned char compact_signature[64];
    secp256k1_ecdsa_recoverable_signature signature;
    secp256k1_pubkey public_key;
    unsigned char serialized[65];
    size_t serialized_len = sizeof(serialized);

    if (recovery_id < 0 || recovery_id > 1) return 0;

    memcpy(compact_signature, r, 32);
    memcpy(compact_signature + 32, s, 32);

    secp256k1_selftest();
    if (!secp256k1_ecdsa_recoverable_signature_parse_compact(
            secp256k1_context_static,
            &signature,
            compact_signature,
            recovery_id)) {
        return 0;
    }
    if (!secp256k1_ecdsa_recover(
            secp256k1_context_static,
            &public_key,
            &signature,
            message_hash)) {
        return 0;
    }
    if (!secp256k1_ec_pubkey_serialize(
            secp256k1_context_static,
            serialized,
            &serialized_len,
            &public_key,
            SECP256K1_EC_UNCOMPRESSED)) {
        return 0;
    }
    if (serialized_len != sizeof(serialized) || serialized[0] != 0x04) return 0;

    memcpy(output, serialized + 1, 64);
    return 1;
}
