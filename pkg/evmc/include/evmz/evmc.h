#ifndef EVMZ_EVMC_H
#define EVMZ_EVMC_H

#include <evmc/evmc.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Create an EVMZ instance. The VM is compatible with the EVMC ABI.
 *
 * @see <evmc/evmc.h>
 */
struct evmc_vm *evmc_create_evmz(void);

#ifdef __cplusplus
}
#endif

#endif /* EVMZ_EVMC_H */
