#include <evmc/evmc.h>

_Static_assert(EVMC_ABI_VERSION == 18, "EVMC ABI 18 required");

int evmz_evmc_abi18_smoke(const struct evmc_host_interface* host,
                          struct evmc_host_context* context,
                          const evmc_address* account,
                          const evmc_address* beneficiary)
{
    if (host == NULL || account == NULL || beneficiary == NULL)
        return 1;
    if (host->get_nonce == NULL || host->account_exists == NULL ||
        host->get_code_size == NULL || host->selfdestruct == NULL)
        return 2;
    if (host->get_nonce(context, account) != 7)
        return 3;
    if (!host->account_exists(context, account))
        return 4;
    if (host->get_code_size(context, account) != 0)
        return 5;
    if (!host->selfdestruct(context, account, beneficiary))
        return 6;
    return 0;
}
