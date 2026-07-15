#include <stdint.h>
#include <string.h>

#include "KeccakSponge.h"

enum {
    KECCAK256_RATE_BITS = 1088,
    KECCAK256_CAPACITY_BITS = 512,
    KECCAK256_RATE_BYTES = KECCAK256_RATE_BITS / 8,
    KECCAK256_DIGEST_BYTES = 32,
};

int evmz_xkcp_keccak256(const unsigned char *input, size_t input_len,
                        unsigned char output[KECCAK256_DIGEST_BYTES]) {
    if (((uintptr_t)input % sizeof(uint64_t)) == 0 ||
        input_len < KECCAK256_RATE_BYTES) {
        return KeccakWidth1600_Sponge(
            KECCAK256_RATE_BITS, KECCAK256_CAPACITY_BITS, input, input_len,
            0x01, output, KECCAK256_DIGEST_BYTES);
    }

    /* XKCP fast absorb lanes read uint64_t values. Preserve that fast path for
       arbitrary byte slices by copying only full, misaligned rate blocks. */
    KeccakWidth1600_SpongeInstance instance;
    ALIGN(8) unsigned char block[KECCAK256_RATE_BYTES];
    int rc = KeccakWidth1600_SpongeInitialize(
        &instance, KECCAK256_RATE_BITS, KECCAK256_CAPACITY_BITS);
    if (rc != 0)
        return rc;

    while (input_len >= KECCAK256_RATE_BYTES) {
        memcpy(block, input, sizeof(block));
        rc = KeccakWidth1600_SpongeAbsorb(&instance, block, sizeof(block));
        if (rc != 0)
            return rc;
        input += sizeof(block);
        input_len -= sizeof(block);
    }
    rc = KeccakWidth1600_SpongeAbsorb(&instance, input, input_len);
    if (rc != 0)
        return rc;
    rc = KeccakWidth1600_SpongeAbsorbLastFewBits(&instance, 0x01);
    if (rc != 0)
        return rc;
    return KeccakWidth1600_SpongeSqueeze(
        &instance, output, KECCAK256_DIGEST_BYTES);
}
