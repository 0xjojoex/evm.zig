#pragma once

#include <stdint.h>

#define EVMZ_KZG_OK 0
#define EVMZ_KZG_INVALID 1

int evmz_kzg_verify_proof(
    const uint8_t commitment[48],
    const uint8_t z[32],
    const uint8_t y[32],
    const uint8_t proof[48]);
