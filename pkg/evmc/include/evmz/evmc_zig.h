#ifndef EVMZ_EVMC_ZIG_H
#define EVMZ_EVMC_ZIG_H

/*
 * Zig 0.16's C translator rejects C23 enums with `_Bool` as their explicit
 * underlying type. EVMC ABI 18 uses `enum evmc_access_status : bool`, so expose
 * the ABI-equivalent unsigned-byte spelling only while importing the header.
 */
#include <stdbool.h>
#undef bool
#define bool unsigned char
#include <evmc/evmc.h>
#undef bool

#endif
