#ifndef EVMZ_BENCH_EVMC_BINDINGS_H
#define EVMZ_BENCH_EVMC_BINDINGS_H

/* Zig's C translator does not yet accept C23 enums backed by bool. */
#include <stdbool.h>
#undef bool
#define bool unsigned char
#include <evmc/evmc.h>
#undef bool

#endif
