#ifndef EVMZ_H
#define EVMZ_H

#ifdef __cplusplus
extern "C" {
#endif

#include "evmc.h"

/*
 * Create an EVMZ instance. The VM is compatible with EVMC ABI
 * @see <evmc.h>
 */
struct evmc_vm *evmc_create_evmz(void);

/* Mock helper */
/**
 * Create a mock host context.
 *
 * @param tx_context  The transaction context.
 * @return            The mock host context.
 */
struct evmc_host_context *
evmz_create_mock_host_context(struct evmc_tx_context *tx_context);

/**
 * Destroy a mock host context.
 *
 * @param context  The mock host context.
 */
void evmz_destroy_mock_host_context(struct evmc_host_context *context);

/**
 * Create a mock host interface.
 *
 * @return  The mock host interface.
 */
const struct evmc_host_interface evmz_mock_host_interace(void);

#ifdef __cplusplus
}
#endif

#endif /* EVMZ_H */
