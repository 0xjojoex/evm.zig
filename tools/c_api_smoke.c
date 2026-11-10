/*
 * The session ABI as a C host sees it. This file is built as strict C99
 * against the installed header and linked against libevmz, so it fails when
 * the header stops being valid C, when the archive stops linking on its own,
 * or when a struct the two sides share stops meaning the same thing.
 *
 * It sends one transfer to a contract, which takes it through every required
 * callback except `get_storage`, and checks what comes back.
 */

#include <evmz/evmz.h>

#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,    \
                    #condition);                                                \
            return 1;                                                           \
        }                                                                       \
    } while (0)

/* keccak256 of the empty string. */
static const evmz_bytes32 empty_code_hash = {{
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d,
    0xb2, 0xdc, 0xc7, 0x03, 0xc0, 0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82,
    0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
}};

/* A contract that stops at once, and keccak256 of that one byte. */
static const uint8_t stop_code[1] = {0x00};
static const evmz_bytes32 stop_code_hash = {{
    0xbc, 0x36, 0x78, 0x9e, 0x7a, 0x1e, 0x28, 0x14, 0x36, 0x46, 0x42,
    0x29, 0x82, 0x8f, 0x81, 0x7d, 0x66, 0x12, 0xf7, 0xb4, 0x77, 0xd6,
    0x65, 0x91, 0xff, 0x96, 0xa9, 0xe0, 0x64, 0xbc, 0xc9, 0x8a,
}};

enum { SENDER = 0, CONTRACT = 1, ACCOUNT_COUNT = 2 };

typedef struct world {
    evmz_address addresses[ACCOUNT_COUNT];
    evmz_host_account accounts[ACCOUNT_COUNT];
    unsigned account_loads;
    unsigned code_loads;
} world;

static evmz_status load_account(void *context, const evmz_address *address,
                                evmz_host_account *out) {
    world *state = context;
    size_t index;
    state->account_loads += 1;
    memset(out, 0, sizeof *out);
    for (index = 0; index < ACCOUNT_COUNT; index += 1) {
        if (memcmp(address, &state->addresses[index], sizeof *address) == 0) {
            *out = state->accounts[index];
        }
    }
    return EVMZ_OK;
}

static evmz_status load_code(void *context, const evmz_bytes32 *code_hash,
                             evmz_code_sink *sink) {
    world *state = context;
    state->code_loads += 1;
    if (memcmp(code_hash, &stop_code_hash, sizeof *code_hash) != 0) {
        return EVMZ_HOST_FAILURE;
    }
    return evmz_code_sink_set(sink, stop_code, sizeof stop_code);
}

static evmz_status get_storage(void *context, const evmz_address *address,
                               const evmz_bytes32 *key, evmz_bytes32 *out) {
    (void)context;
    (void)address;
    (void)key;
    memset(out, 0, sizeof *out);
    return EVMZ_OK;
}

static const evmz_account_delta *find_account(const evmz_result_data *data,
                                              const evmz_address *address) {
    size_t index;
    for (index = 0; index < data->accounts_len; index += 1) {
        if (memcmp(&data->accounts[index].address, address, sizeof *address) == 0) {
            return &data->accounts[index];
        }
    }
    return NULL;
}

int main(void) {
    world state;
    evmz_host host;
    evmz_env env;
    evmz_transaction transaction;
    evmz_session *session = NULL;
    evmz_result *result = NULL;
    const evmz_result_data *data;
    const evmz_account_delta *sender;
    const evmz_account_delta *contract;

    CHECK(evmz_abi_version() == EVMZ_ABI_VERSION);
    CHECK(evmz_build_optimize() <= EVMZ_OPTIMIZE_RELEASE_SMALL);
    CHECK((evmz_capabilities() & EVMZ_CAPABILITY_SYSTEM_CALL) != 0);
    /* Every fork preset contains Prague. */
    CHECK(evmz_fork_supported(EVMZ_FORK_PRAGUE) == 1);
    CHECK(evmz_fork_supported(UINT32_MAX) == 0);

    memset(&state, 0, sizeof state);
    state.addresses[SENDER].bytes[19] = 0xaa;
    state.accounts[SENDER].exists = 1;
    state.accounts[SENDER].balance.bytes[31] = 100;
    state.accounts[SENDER].code_hash = empty_code_hash;
    state.addresses[CONTRACT].bytes[19] = 0xcc;
    state.accounts[CONTRACT].exists = 1;
    state.accounts[CONTRACT].nonce = 1;
    state.accounts[CONTRACT].code_hash = stop_code_hash;

    memset(&host, 0, sizeof host);
    host.struct_size = sizeof host;
    host.context = &state;
    host.load_account = load_account;
    host.load_code = load_code;
    host.get_storage = get_storage;

    CHECK(evmz_session_create(EVMZ_FORK_AMSTERDAM + 1, &host, &session) ==
          EVMZ_UNSUPPORTED_FORK);
    CHECK(session == NULL);
    CHECK(evmz_session_create(EVMZ_FORK_PRAGUE, &host, &session) == EVMZ_OK);
    CHECK(session != NULL);

    memset(&env, 0, sizeof env);
    env.chain_id.bytes[31] = 1;
    env.number = 1;
    env.gas_limit = 30000000;

    memset(&transaction, 0, sizeof transaction);
    transaction.kind = EVMZ_TX_LEGACY;
    transaction.sender = state.addresses[SENDER];
    transaction.has_nonce = 1;
    transaction.nonce = 0;
    transaction.gas_limit = 100000;
    transaction.has_to = 1;
    transaction.to = state.addresses[CONTRACT];
    transaction.value.bytes[31] = 7;

    CHECK(evmz_session_execute(session, &env, NULL, &transaction, &result) == EVMZ_OK);
    CHECK(result != NULL);
    CHECK(state.account_loads >= 2);
    CHECK(state.code_loads == 1);

    data = evmz_result_get_data(result);
    CHECK(data != NULL);
    CHECK(data->struct_size == sizeof *data);
    CHECK(data->outcome == EVMZ_OUTCOME_EXECUTED);
    CHECK(data->status == EVMZ_EXECUTION_SUCCESS);
    CHECK(data->has_halt == 1);
    CHECK(data->halt == EVMZ_HALT_STOP);
    CHECK(data->gas.used > 0);
    CHECK(data->gas.used + data->gas.refunded == transaction.gas_limit);
    CHECK(data->output_len == 0);
    CHECK(data->storage_len == 0);
    CHECK(data->code_changes_len == 0);

    sender = find_account(data, &state.addresses[SENDER]);
    CHECK(sender != NULL);
    CHECK(sender->original.nonce == 0);
    CHECK(sender->current.nonce == 1);
    CHECK(sender->original.balance.bytes[31] == 100);
    CHECK(sender->current.balance.bytes[31] == 93);
    CHECK((sender->effects & EVMZ_ACCOUNT_NONCE_WRITTEN) != 0);

    contract = find_account(data, &state.addresses[CONTRACT]);
    CHECK(contract != NULL);
    CHECK(contract->original.balance.bytes[31] == 0);
    CHECK(contract->current.balance.bytes[31] == 7);
    CHECK(contract->current.nonce == 1);
    CHECK(memcmp(&contract->current.code_hash, &stop_code_hash, sizeof stop_code_hash) == 0);

    /* The result is pending until the host decides. */
    CHECK(evmz_session_reset(session) == EVMZ_PENDING_RESULT);
    CHECK(evmz_session_accept(session) == EVMZ_OK);
    CHECK(evmz_session_accept(session) == EVMZ_NO_PENDING_RESULT);

    /* The copy outlives the session it came from. */
    evmz_session_destroy(session);
    CHECK(data->gas.used + data->gas.refunded == transaction.gas_limit);
    evmz_result_destroy(result);
    return 0;
}
