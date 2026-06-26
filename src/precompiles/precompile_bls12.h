#pragma once

#include <stddef.h>
#include <stdint.h>

#define EVMZ_BLS12_OK 0
#define EVMZ_BLS12_INVALID 1
#define EVMZ_BLS12_OOM 2

int evmz_bls12_g1_add(const uint8_t *input, uint8_t output[128]);
int evmz_bls12_g1_msm(const uint8_t *input, size_t input_len, uint8_t output[128]);
int evmz_bls12_g2_add(const uint8_t *input, uint8_t output[256]);
int evmz_bls12_g2_msm(const uint8_t *input, size_t input_len, uint8_t output[256]);
int evmz_bls12_pairing_check(const uint8_t *input, size_t input_len, uint8_t output[32]);
int evmz_bls12_map_fp_to_g1(const uint8_t input[64], uint8_t output[128]);
int evmz_bls12_map_fp2_to_g2(const uint8_t input[128], uint8_t output[256]);
