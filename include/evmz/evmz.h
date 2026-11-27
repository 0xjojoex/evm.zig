#ifndef EVMZ_EVMZ_H
#define EVMZ_EVMZ_H

/*
 * evmz C API: the interactive session ABI.
 *
 * A session executes transactions for one revision against state the host owns.
 * The host answers reads through callbacks; evmz keeps the speculative overlay
 * and hands every transaction back as an owned result the host accepts or
 * discards.
 *
 * Rules that hold for every function:
 *
 * - Words (`evmz_bytes32`) are 32-byte big-endian integers.
 * - A `has_*` field is 0 or 1; the field it guards is ignored when 0.
 * - A pointer paired with a `_len` may be NULL only when the length is 0.
 * - evmz checks every value it is given. A NULL where one is not allowed, an
 *   out-of-range enum or flag, an inconsistent count, a field its transaction
 *   kind does not have or a gas amount its field refuses returns
 *   `EVMZ_INVALID_ARGUMENT` and changes nothing. evmz cannot check where a
 *   pointer leads; see below.
 * - One session is used by one thread at a time. Sessions are independent of
 *   each other. Callbacks run synchronously on the calling thread, only inside
 *   `evmz_session_execute` and `evmz_session_execute_system_call`.
 * - A callback must not call a function that takes the session it serves. Such
 *   a call returns `EVMZ_REENTRANT_CALL` and does nothing, and
 *   `evmz_session_destroy` does nothing. Other sessions and results are free
 *   to use.
 * - Until evmz 1.0 a binding must match `evmz_abi_version()` exactly.
 *
 * Pointers and lifetimes. Where one of these binds the caller, breaking it is
 * undefined behaviour, not an error evmz reports:
 *
 * - A non-NULL pointer refers to a whole object of its type, aligned for it.
 *   A pointer with a `_len` refers to that many elements.
 * - Input is borrowed for the call. Everything a call reads, including what
 *   its structs point at, stays valid and unchanged until the call returns.
 *   evmz keeps none of it afterwards, so the caller may free it at once.
 * - An `out` parameter is writable. `*out` is NULL after every status but
 *   `EVMZ_OK`.
 * - A handle (`evmz_session *`, `evmz_result *`) is one evmz returned and has
 *   not destroyed. No other pointer is a handle, and a destroyed one is never
 *   used again.
 * - Neither handle belongs to a thread: either may move to another thread
 *   between calls.
 * - What `evmz_result_get_data` returns, and everything it points at, is
 *   read-only and lives until `evmz_result_destroy`. An array of length 0 has
 *   a NULL pointer.
 *
 * Linking: `zig build c-api` installs this header, `libevmz.a` and `libblst.a`.
 * Link both archives and LLVM's C++ runtime: `-levmz -lblst -lc++`. GNU
 * libstdc++ is not a substitute; the archive refers to libc++'s `std::__1`.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EVMZ_ABI_VERSION 3

/* ---- Status ------------------------------------------------------------ */

typedef uint32_t evmz_status;
enum {
    EVMZ_OK = 0,
    /*
     * A NULL pointer where one is not allowed, an out-of-range enum or flag,
     * an inconsistent count, a field the transaction kind does not have, or a
     * gas amount its field refuses.
     */
    EVMZ_INVALID_ARGUMENT = 1,
    /* The revision number is unknown or was not compiled into this library. */
    EVMZ_UNSUPPORTED_REVISION = 2,
    /* The session holds a pending result; accept or discard it first. */
    EVMZ_PENDING_RESULT = 3,
    /* Accept or discard was called with no pending result. */
    EVMZ_NO_PENDING_RESULT = 4,
    /* A host callback failed, or returned data that contradicts itself. */
    EVMZ_HOST_FAILURE = 5,
    EVMZ_OUT_OF_MEMORY = 6,
    /* The engine failed for a reason the host did not cause. */
    EVMZ_INTERNAL_ERROR = 7,
    /* A callback called a function of the session it is serving. */
    EVMZ_REENTRANT_CALL = 8
};

/* ---- Build identity ---------------------------------------------------- */

/* Append-only numbering. Usable only if `evmz_revision_supported`. */
enum {
    EVMZ_REVISION_FRONTIER = 0,
    EVMZ_REVISION_FRONTIER_THAWING = 1,
    EVMZ_REVISION_HOMESTEAD = 2,
    EVMZ_REVISION_DAO_FORK = 3,
    EVMZ_REVISION_TANGERINE_WHISTLE = 4,
    EVMZ_REVISION_SPURIOUS_DRAGON = 5,
    EVMZ_REVISION_BYZANTIUM = 6,
    EVMZ_REVISION_CONSTANTINOPLE = 7,
    EVMZ_REVISION_PETERSBURG = 8,
    EVMZ_REVISION_ISTANBUL = 9,
    EVMZ_REVISION_MUIR_GLACIER = 10,
    EVMZ_REVISION_BERLIN = 11,
    EVMZ_REVISION_LONDON = 12,
    EVMZ_REVISION_ARROW_GLACIER = 13,
    EVMZ_REVISION_GRAY_GLACIER = 14,
    EVMZ_REVISION_MERGE = 15,
    EVMZ_REVISION_SHANGHAI = 16,
    EVMZ_REVISION_CANCUN = 17,
    EVMZ_REVISION_PRAGUE = 18,
    EVMZ_REVISION_OSAKA = 19,
    EVMZ_REVISION_AMSTERDAM = 20
};

enum {
    EVMZ_OPTIMIZE_DEBUG = 0,
    EVMZ_OPTIMIZE_RELEASE_SAFE = 1,
    EVMZ_OPTIMIZE_RELEASE_FAST = 2,
    EVMZ_OPTIMIZE_RELEASE_SMALL = 3
};

/* What this build contains, not what the ABI version defines. */
enum {
    EVMZ_CAPABILITY_SYSTEM_CALL = 1 << 0,
    /* Reserved; never set by ABI version 3. */
    EVMZ_CAPABILITY_PRECOMPILE_OVERRIDES = 1 << 1,
    EVMZ_CAPABILITY_TRACING = 1 << 2,
    EVMZ_CAPABILITY_READ_SET = 1 << 3,
    EVMZ_CAPABILITY_STATELESS = 1 << 4
};

uint32_t evmz_abi_version(void);
uint64_t evmz_capabilities(void);
/* The optimize mode this library was built in: one of EVMZ_OPTIMIZE_*. */
uint32_t evmz_build_optimize(void);
/* 1 when `revision` was compiled into this library, otherwise 0. */
int evmz_revision_supported(uint32_t revision);

/* ---- Values ------------------------------------------------------------ */

typedef struct evmz_address {
    uint8_t bytes[20];
} evmz_address;

typedef struct evmz_bytes32 {
    uint8_t bytes[32];
} evmz_bytes32;

/*
 * An account without its code and storage. `exists` = 0 means the account is
 * absent and the other fields are ignored. `code_hash` is keccak256 of the
 * code, which for an account without code is keccak256 of the empty string.
 */
typedef struct evmz_host_account {
    uint8_t exists;
    uint64_t nonce;
    evmz_bytes32 balance;
    evmz_bytes32 code_hash;
} evmz_host_account;

/* ---- Host -------------------------------------------------------------- */

/*
 * Valid only inside the `load_code` call that received it. The host does not
 * keep it: using it after that call returns is undefined.
 */
typedef struct evmz_code_sink evmz_code_sink;

/*
 * Hand over the code for one `load_code` call. evmz copies `len` bytes before
 * it returns, so the host may free them at once. A second call inside the same
 * `load_code` returns EVMZ_INVALID_ARGUMENT and keeps the first call's bytes.
 */
evmz_status evmz_code_sink_set(evmz_code_sink *sink, const uint8_t *ptr, size_t len);

/*
 * State the host owns, as it stood when the session was created or last reset.
 *
 * Every callback returns EVMZ_OK on success. Any other status aborts the
 * running execute with EVMZ_HOST_FAILURE and leaves the session as it was
 * before that execute.
 *
 * Snapshot rule: while a session is live the host must not change state the
 * session may have read, except by applying an accepted result. Out-of-band
 * writes such as withdrawals happen after the last transaction; then the host
 * destroys the session or calls `evmz_session_reset`.
 *
 * Every pointer a callback receives other than `context` is valid only until
 * that callback returns. `out` and `found` arrive zeroed, so a callback that
 * writes nothing reports an absent account, a zero slot or a missing hash.
 */
typedef struct evmz_host {
    /*
     * sizeof(evmz_host) as the caller compiled it. A value below the library's
     * own sizeof(evmz_host) returns EVMZ_INVALID_ARGUMENT.
     */
    uint32_t struct_size;
    /* Passed to every callback as is; evmz never reads through it. */
    void *context;
    /* Set `out->exists` to 0 for an absent account. */
    evmz_status (*load_account)(void *context, const evmz_address *address,
                                evmz_host_account *out);
    /*
     * Call `evmz_code_sink_set` exactly once before returning. evmz checks the
     * bytes against `code_hash`. Never asked for the empty code hash.
     */
    evmz_status (*load_code)(void *context, const evmz_bytes32 *code_hash,
                             evmz_code_sink *sink);
    /* A slot the host does not have reads as zero. */
    evmz_status (*get_storage)(void *context, const evmz_address *address,
                               const evmz_bytes32 *key, evmz_bytes32 *out);
    /*
     * Optional; NULL makes every hash unavailable. Set `*found` to 0 when the
     * host has no hash for `number`. evmz applies the BLOCKHASH window itself
     * and asks only for numbers inside it.
     */
    evmz_status (*get_block_hash)(void *context, uint64_t number, evmz_bytes32 *out,
                                  uint8_t *found);
} evmz_host;

/* ---- Execution input --------------------------------------------------- */

typedef struct evmz_blob_params {
    uint64_t target;
    uint64_t max;
    evmz_bytes32 base_fee_update_fraction;
} evmz_blob_params;

typedef struct evmz_env {
    evmz_bytes32 chain_id;
    evmz_address coinbase;
    uint64_t number;
    uint64_t slot_number;
    uint64_t timestamp;
    /*
     * The block gas limit, at most INT64_MAX. Zero means the block has no
     * limit.
     */
    uint64_t gas_limit;
    /*
     * The header's two fields as they are. Opcode 0x44 returns `difficulty`
     * on a fork before the Merge and `prev_randao` from the Merge on; evmz
     * never reads the other one.
     */
    evmz_bytes32 difficulty;
    evmz_bytes32 prev_randao;
    evmz_bytes32 base_fee;
    evmz_bytes32 blob_base_fee;
    /* EIP-7892 override of the fork's blob schedule. */
    uint8_t has_blob_params;
    evmz_blob_params blob_params;
} evmz_env;

/*
 * Block gas in the two dimensions EIP-8037 counts. Before Amsterdam `regular`
 * is the receipt gas and `state` is zero.
 *
 * The gas a block used, which its header carries, is
 * max(sum of `regular`, sum of `state`) over its transactions. That is not the
 * sum of a per-transaction maximum, so no total is reported to add up.
 */
typedef struct evmz_block_gas {
    uint64_t regular;
    uint64_t state;
} evmz_block_gas;

/*
 * What the block has consumed before this transaction. The session does not
 * track blocks: the host sums `receipt_gas_used` from `evmz_gas.used`, and
 * each field of `block_gas` from the same field of `evmz_gas.block`, over the
 * results it accepted.
 */
typedef struct evmz_block_progress {
    uint64_t receipt_gas_used;
    evmz_block_gas block_gas;
} evmz_block_progress;

enum {
    EVMZ_TX_LEGACY = 0,
    EVMZ_TX_ACCESS_LIST = 1,
    EVMZ_TX_DYNAMIC_FEE = 2,
    EVMZ_TX_BLOB = 3,
    EVMZ_TX_SET_CODE = 4
};

typedef struct evmz_access_list_entry {
    evmz_address address;
    const evmz_bytes32 *storage_keys;
    size_t storage_keys_len;
} evmz_access_list_entry;

/*
 * One EIP-7702 authorization whose signature the host already checked and
 * recovered; `signer` is the authority. A tuple that fails recovery is left
 * out of the list and still counted in `evmz_transaction.authorization_count`.
 */
typedef struct evmz_recovered_authorization {
    evmz_bytes32 chain_id;
    evmz_address target;
    evmz_address signer;
    uint64_t nonce;
} evmz_recovered_authorization;

/*
 * A field its `kind` does not have must be absent: the `has_*` flag 0, the
 * list length 0. Anything else returns EVMZ_INVALID_ARGUMENT.
 *
 *                              LEGACY  ACCESS_LIST  DYNAMIC_FEE  BLOB  SET_CODE
 *   access_list                  -          x            x        x       x
 *   max_fee_per_gas              -          -            x        x       x
 *   max_priority_fee_per_gas     -          -            x        x       x
 *   max_fee_per_blob_gas         -          -            -        x       -
 *   blob_hashes                  -          -            -        x       -
 *   authorization_list           -          -            -        -       x
 *   authorization_count          -          -            -        -       x
 *
 * LEGACY and ACCESS_LIST pay `gas_price`. The other kinds pay by
 * `max_fee_per_gas` and are rejected without it.
 */
typedef struct evmz_transaction {
    /* One of EVMZ_TX_*. */
    uint32_t kind;
    evmz_address sender;
    /*
     * Absent only for an unprotected legacy transaction. Every other kind
     * without it returns EVMZ_INVALID_ARGUMENT.
     */
    uint8_t has_chain_id;
    evmz_bytes32 chain_id;
    /* Absent skips the nonce check. */
    uint8_t has_nonce;
    uint64_t nonce;
    /*
     * Above INT64_MAX the transaction is rejected, since no block gas limit
     * is that high. In a block without a limit it returns
     * EVMZ_INVALID_ARGUMENT instead.
     */
    uint64_t gas_limit;
    /* Absent creates a contract. */
    uint8_t has_to;
    evmz_address to;
    evmz_bytes32 value;
    const uint8_t *input;
    size_t input_len;
    evmz_bytes32 gas_price;
    uint8_t has_max_fee_per_gas;
    evmz_bytes32 max_fee_per_gas;
    uint8_t has_max_priority_fee_per_gas;
    evmz_bytes32 max_priority_fee_per_gas;
    uint8_t has_max_fee_per_blob_gas;
    evmz_bytes32 max_fee_per_blob_gas;
    const evmz_bytes32 *blob_hashes;
    size_t blob_hashes_len;
    const evmz_access_list_entry *access_list;
    size_t access_list_len;
    const evmz_recovered_authorization *authorization_list;
    size_t authorization_list_len;
    /*
     * Tuples in the signed transaction, including those dropped at recovery.
     * Absent means `authorization_list_len`; never less than it.
     */
    uint8_t has_authorization_count;
    uint64_t authorization_count;
} evmz_transaction;

/*
 * A protocol call such as the EIP-4788 beacon root update. It pays no fees and
 * moves no value. The host supplies the gas: `gas_limit` is the regular budget
 * and `state_gas` the EIP-8037 state-gas reservoir, zero before Amsterdam.
 * Each is at most INT64_MAX.
 */
typedef struct evmz_system_call {
    evmz_address sender;
    evmz_address recipient;
    const uint8_t *input;
    size_t input_len;
    uint64_t gas_limit;
    uint64_t state_gas;
} evmz_system_call;

/* ---- Result ------------------------------------------------------------ */

enum {
    /* Validation refused the transaction; nothing ran and nothing is pending. */
    EVMZ_OUTCOME_REJECTED = 0,
    EVMZ_OUTCOME_EXECUTED = 1
};

/* evmz_result_data.rejection, valid when the outcome is REJECTED. */
enum {
    EVMZ_REJECTION_NONE = 0,
    EVMZ_REJECTION_INTRINSIC_GAS_TOO_LOW = 1,
    EVMZ_REJECTION_INTRINSIC_GAS_BELOW_FLOOR_GAS_COST = 2,
    EVMZ_REJECTION_INSUFFICIENT_ACCOUNT_FUNDS = 3,
    EVMZ_REJECTION_INSUFFICIENT_MAX_FEE_PER_GAS = 4,
    EVMZ_REJECTION_PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS = 5,
    EVMZ_REJECTION_INSUFFICIENT_MAX_FEE_PER_BLOB_GAS = 6,
    EVMZ_REJECTION_GAS_LIMIT_EXCEEDS_MAXIMUM = 7,
    EVMZ_REJECTION_GAS_ALLOWANCE_EXCEEDED = 8,
    EVMZ_REJECTION_NONCE_IS_MAX = 9,
    EVMZ_REJECTION_NONCE_TOO_LOW = 10,
    EVMZ_REJECTION_NONCE_TOO_HIGH = 11,
    EVMZ_REJECTION_TYPE_1_TX_PRE_FORK = 12,
    EVMZ_REJECTION_TYPE_2_TX_PRE_FORK = 13,
    EVMZ_REJECTION_TYPE_3_TX_PRE_FORK = 14,
    EVMZ_REJECTION_TYPE_4_TX_PRE_FORK = 15,
    EVMZ_REJECTION_TYPE_3_TX_CONTRACT_CREATION = 16,
    EVMZ_REJECTION_TYPE_3_TX_ZERO_BLOBS = 17,
    EVMZ_REJECTION_TYPE_3_TX_BLOB_COUNT_EXCEEDED = 18,
    EVMZ_REJECTION_TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED = 19,
    EVMZ_REJECTION_TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH = 20,
    EVMZ_REJECTION_INITCODE_SIZE_EXCEEDED = 21,
    EVMZ_REJECTION_SENDER_NOT_EOA = 22,
    EVMZ_REJECTION_TYPE_4_EMPTY_AUTHORIZATION_LIST = 23,
    EVMZ_REJECTION_TYPE_4_TX_CONTRACT_CREATION = 24,
    EVMZ_REJECTION_INVALID_CHAIN_ID = 25
};

/* evmz_result_data.status, valid when the outcome is EXECUTED. */
enum {
    EVMZ_EXECUTION_SUCCESS = 0,
    EVMZ_EXECUTION_REVERT = 1,
    EVMZ_EXECUTION_INVALID = 2,
    EVMZ_EXECUTION_OUT_OF_GAS = 3
};

/*
 * evmz_result_data.halt: how the root bytecode frame stopped. Valid when
 * `has_halt` is 1. No frame runs for a precompile target, so there is none to
 * report. Create finalization can fail after the frame returned, so a failed
 * status may carry a successful halt; `cause` says why it failed.
 */
enum {
    EVMZ_HALT_STOP = 0,
    EVMZ_HALT_RETURN = 1,
    EVMZ_HALT_SELFDESTRUCT = 2,
    EVMZ_HALT_REVERT = 3,
    EVMZ_HALT_OUT_OF_GAS = 4,
    EVMZ_HALT_INVALID_OPCODE = 5,
    EVMZ_HALT_STACK_UNDERFLOW = 6,
    EVMZ_HALT_STACK_OVERFLOW = 7,
    EVMZ_HALT_INVALID_JUMP = 8,
    EVMZ_HALT_WRITE_PROTECTION = 9,
    EVMZ_HALT_RETURN_DATA_OUT_OF_BOUNDS = 10
};

/*
 * evmz_result_data.cause: why the execution ended with its status, counting
 * what happens outside the root frame. Valid when the outcome is EXECUTED.
 * EVMZ_CAUSE_NONE on success, except that a Frontier create that cannot pay
 * for its code succeeds without code and reports CODE_STORE_OUT_OF_GAS.
 */
enum {
    EVMZ_CAUSE_NONE = 0,
    EVMZ_CAUSE_REVERT = 1,
    EVMZ_CAUSE_OUT_OF_GAS = 2,
    /* A failure with no more precise cause, such as a failed precompile. */
    EVMZ_CAUSE_INVALID = 3,
    EVMZ_CAUSE_CALL_DEPTH_EXCEEDED = 4,
    EVMZ_CAUSE_INSUFFICIENT_BALANCE = 5,
    EVMZ_CAUSE_NONCE_OVERFLOW = 6,
    EVMZ_CAUSE_INVALID_OPCODE = 7,
    EVMZ_CAUSE_STACK_UNDERFLOW = 8,
    EVMZ_CAUSE_STACK_OVERFLOW = 9,
    EVMZ_CAUSE_INVALID_JUMP = 10,
    EVMZ_CAUSE_WRITE_PROTECTION = 11,
    EVMZ_CAUSE_RETURN_DATA_OUT_OF_BOUNDS = 12,
    /* The create address already holds a contract. */
    EVMZ_CAUSE_CONTRACT_ADDRESS_COLLISION = 13,
    /* The created code is longer than the fork allows. */
    EVMZ_CAUSE_MAX_CODE_SIZE_EXCEEDED = 14,
    /* The created code starts with 0xEF (EIP-3541). */
    EVMZ_CAUSE_INVALID_CODE = 15,
    /* The create could not pay to store its code. */
    EVMZ_CAUSE_CODE_STORE_OUT_OF_GAS = 16
};

typedef struct evmz_gas {
    /*
     * Gas spent before refunds and floor rules: the gas limit minus what
     * execution left.
     */
    uint64_t spent;
    /*
     * Receipt gas after refunds and floor rules:
     * max(spent - execution_refund, the calldata floor).
     */
    uint64_t used;
    /*
     * The EVM refund counter after the fork's refund cap. The calldata floor
     * does not zero it, so `used + execution_refund` can exceed `spent`.
     */
    uint64_t execution_refund;
    /* Unused gas returned to the payer: the gas limit minus `used`. */
    uint64_t returned;
    /* This transaction's contribution to `evmz_block_progress.block_gas`. */
    evmz_block_gas block;
} evmz_gas;

typedef struct evmz_log {
    evmz_address address;
    const evmz_bytes32 *topics;
    size_t topics_len;
    const uint8_t *data;
    size_t data_len;
} evmz_log;

/* evmz_account_delta.effects */
enum {
    EVMZ_ACCOUNT_BALANCE_WRITTEN = 1 << 0,
    EVMZ_ACCOUNT_NONCE_WRITTEN = 1 << 1,
    EVMZ_ACCOUNT_CODE_WRITTEN = 1 << 2,
    EVMZ_ACCOUNT_DELETED = 1 << 3,
    EVMZ_ACCOUNT_CREATED_CONTRACT = 1 << 4,
    EVMZ_ACCOUNT_SELFDESTRUCT = 1 << 5,
    /*
     * Self-destruct cleared the account's storage when the execution ended.
     * Not set for a contract that is only listed in `storage_wipes` because
     * this execution created it.
     */
    EVMZ_ACCOUNT_STORAGE_WIPED = 1 << 6
};

/*
 * One account this execution wrote. `original` is the account before this
 * execution, including results accepted earlier in the session; `current` is
 * the account after it. Either or both may be absent, and the two may be
 * equal: a write that ends at the earlier value is still listed.
 */
typedef struct evmz_account_delta {
    evmz_address address;
    uint32_t effects;
    evmz_host_account original;
    evmz_host_account current;
} evmz_account_delta;

/*
 * One slot this execution wrote. `original` is the slot before this execution,
 * even when `storage_wipes` lists the account. `current` may equal `original`.
 */
typedef struct evmz_storage_delta {
    evmz_address address;
    evmz_bytes32 key;
    evmz_bytes32 original;
    evmz_bytes32 current;
} evmz_storage_delta;

/* Code some account in `accounts` now points at. */
typedef struct evmz_code_change {
    evmz_bytes32 code_hash;
    const uint8_t *code;
    size_t code_len;
} evmz_code_change;

/*
 * Everything one execution produced. Arrays are in no particular order.
 *
 * To apply an accepted result: clear all storage of every address in
 * `storage_wipes`, then write `storage`, `accounts` and `code_changes`.
 *
 * `storage_wipes` lists every account whose storage this execution emptied:
 * each contract it created and each account a self-destruct cleared. `storage`
 * holds only the writes that survive those wipes. A wiped slot that was not
 * written again is not listed anywhere; the wipe is its only record.
 *
 * `code_changes` holds the code of every account in `accounts` whose code hash
 * changed to a non-empty hash, once per hash, whether or not the host already
 * stores that code.
 */
typedef struct evmz_result_data {
    /* sizeof(evmz_result_data) as the library compiled it. */
    uint32_t struct_size;
    /* One of EVMZ_OUTCOME_*. */
    uint32_t outcome;
    uint32_t rejection;
    uint32_t status;
    uint8_t has_halt;
    uint32_t halt;
    /* One of EVMZ_CAUSE_*. */
    uint32_t cause;
    evmz_gas gas;
    const uint8_t *output;
    size_t output_len;
    uint8_t has_created_address;
    evmz_address created_address;
    const evmz_log *logs;
    size_t logs_len;
    const evmz_account_delta *accounts;
    size_t accounts_len;
    const evmz_storage_delta *storage;
    size_t storage_len;
    const evmz_address *storage_wipes;
    size_t storage_wipes_len;
    const evmz_code_change *code_changes;
    size_t code_changes_len;
} evmz_result_data;

/*
 * An owned copy that shares nothing with its session. It stays valid across
 * accept, discard, reset and `evmz_session_destroy`, until it is destroyed.
 */
typedef struct evmz_result evmz_result;

/* Borrowed from `result` until it is destroyed. NULL when `result` is NULL. */
const evmz_result_data *evmz_result_get_data(const evmz_result *result);
/* Frees the copy. It does not accept or discard anything. NULL is a no-op. */
void evmz_result_destroy(evmz_result *result);

/* ---- Session ----------------------------------------------------------- */

typedef struct evmz_session evmz_session;

/*
 * Copies `*host`, which the caller may free once this returns. The callbacks
 * and whatever `host->context` points at stay valid until
 * `evmz_session_destroy` returns.
 */
evmz_status evmz_session_create(uint32_t revision, const evmz_host *host, evmz_session **out);
/*
 * Discards a pending result. NULL is a no-op, and so is a call from one of the
 * session's own callbacks.
 */
void evmz_session_destroy(evmz_session *session);

/*
 * Execute one transaction on top of everything accepted so far.
 *
 * `progress` may be NULL at the start of a block. On EVMZ_OK `*out` holds a
 * result the caller destroys. An EXECUTED result is pending: the session
 * refuses to execute again until `evmz_session_accept` or
 * `evmz_session_discard`. A REJECTED result changed nothing and is not pending.
 */
evmz_status evmz_session_execute(evmz_session *session, const evmz_env *env,
                                 const evmz_block_progress *progress,
                                 const evmz_transaction *transaction, evmz_result **out);

/*
 * Execute one protocol call and accept it at once: a system call is part of
 * the block, not a candidate, so its result is never pending. A call that
 * fails reports its status and changes no state.
 *
 * The call runs from `call->sender` with a zero origin and no value, pays no
 * fee and no intrinsic gas. In the result `gas.spent` and `gas.used` are both
 * `gas_limit` minus the gas the frame left, and the rest of `gas` is zero. A
 * `recipient` that is a precompile or another contract evmz implements
 * natively returns EVMZ_INVALID_ARGUMENT.
 */
evmz_status evmz_session_execute_system_call(evmz_session *session, const evmz_env *env,
                                             const evmz_system_call *call,
                                             evmz_result **out);

/* Keep the pending result in the overlay; the next execute sees it. */
evmz_status evmz_session_accept(evmz_session *session);
/* Roll the pending result back. */
evmz_status evmz_session_discard(evmz_session *session);
/*
 * Drop the overlay and every account and storage slot read from the host, so
 * the next execute reads them afresh. Code stays cached by its hash, which
 * names one byte string for good. Refused with EVMZ_PENDING_RESULT while a
 * result is pending.
 */
evmz_status evmz_session_reset(evmz_session *session);

#ifdef __cplusplus
}
#endif

#endif /* EVMZ_EVMZ_H */
