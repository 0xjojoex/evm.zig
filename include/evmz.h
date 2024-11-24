#ifndef EVMZ_H
#define EVMZ_H

#ifdef __cplusplus
extern "C" {
#endif

#include "evmc.h"

struct evmc_vm *evmc_create_evmz(void);

#ifdef __cplusplus
}
#endif

#endif /* EVMZ_H */
