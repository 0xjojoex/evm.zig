#ifndef EVMZ_PRECOMPILE_BN254_H
#define EVMZ_PRECOMPILE_BN254_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on valid BN254 add input and writes the 64-byte EVM point result.
// Returns -1 when either input point is malformed or not on the curve.
int evmz_bn254_add(const uint8_t* input, size_t input_size, uint8_t output[64]);

// Returns 0 on valid BN254 mul input and writes the 64-byte EVM point result.
// Returns -1 when the input point is malformed or not on the curve.
int evmz_bn254_mul(const uint8_t* input, size_t input_size, uint8_t output[64]);

// Returns 0 on a valid pairing-check input and writes the 32-byte EVM result.
// Returns -1 when the input is malformed or fails group validation.
int evmz_bn254_pairing_check(const uint8_t* input, size_t input_size, uint8_t output[32]);

#ifdef __cplusplus
}
#endif

#endif
