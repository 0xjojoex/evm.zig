#ifndef EVMZ_H
#define EVMZ_H

#ifdef __cplusplus
extern "C" {
#endif

#include "evmc.h"

struct evmc_vm *evmc_create_evmz(void);
struct evmc_host_interface *evmz_create_mock_host(struct evmc_tx_context *tx_context);

#ifdef __cplusplus
}
#endif

#endif /* EVMZ_H */
