//! EVM specification contract.
//!
//! The engine owns this shape. Ethereum fork catalogs fill it with named
//! comptime values; runtime revision selection stays outside `Vm(spec)`.
//!
//! Field naming states the kind of value: snake_case fields are resolved
//! scalars, camelCase fields are resolved semantic functions consuming
//! runtime input only.
//!
//! Every section derives forward with `extend(patch)`. Patch fields default
//! to inheriting the base value; optional spec fields patch through
//! `OptionalPatch`, whose `.replace` can also override the base to `null`.

const std = @import("std");

const block_program = @import("block_program.zig");
const execution = @import("execution.zig");
const instruction_table = @import("instruction/table.zig");
const authorization = @import("transaction/authorization.zig");
const tx = @import("transaction/types.zig");
const tx_blob = @import("transaction/blob.zig");
const tx_gas = @import("transaction/gas.zig");

/// Transaction validation and intrinsic-gas rules.
pub const TransactionSpec = struct {
    /// EIP-2718 transaction kinds this specification accepts.
    active_kinds: std.EnumSet(tx.TxKind),
    /// Whether a kind may create a contract (`to == null`).
    allowsContractCreation: *const fn (tx.TxKind) bool,
    /// Whether a kind must carry an EIP-7702 authorization list.
    requiresAuthorizationList: *const fn (tx.TxKind) bool,
    /// EIP-3607 sender-code rejection for a kind; EIP-7702 delegation
    /// designations are exempted separately via `isDelegationCode`.
    rejectsNonDelegatingSenderCode: *const fn (tx.TxKind) bool,
    /// Recognizes an EIP-7702 delegation designation in account code.
    isDelegationCode: *const fn ([]const u8) bool,
    /// EIP-4844 blob gas accounting; null while blobs do not exist.
    blob_schedule: ?tx_blob.BlobSchedule,
    /// EIP-3860 initcode ceiling for create transactions; maxInt is uncapped.
    max_initcode_size: usize,
    /// Base intrinsic gas for the transaction shape; null on overflow.
    intrinsicBaseGas: *const fn (tx_gas.IntrinsicGasOptions) ?u64,
    /// Additional intrinsic gas for create transactions (EIP-2).
    create_intrinsic_gas: u64,
    /// Intrinsic calldata pricing; null on overflow.
    calldataGas: *const fn ([]const u8) ?u64,
    /// Per-address access-list intrinsic gas (EIP-2930).
    access_list_address_gas: u64,
    /// Per-storage-key access-list intrinsic gas (EIP-2930).
    storage_key_gas: u64,
    /// Access-list data pricing beyond the per-entry charges; null on
    /// overflow.
    accessListDataGas: *const fn (tx_gas.AccessListCounts) ?u64,
    /// Per-word intrinsic initcode charge for create transactions (EIP-3860).
    initcode_word_gas: u64,
    /// Per-authorization intrinsic gas (EIP-7702).
    authorization_intrinsic_gas: u64,
    /// Calldata floor on gas used (EIP-7623); null when no floor applies.
    floorGas: *const fn (tx_gas.FloorGasInput) ?u64,
    /// Cap on the regular-gas budget derived from the transaction gas limit
    /// (EIP-7825); null is uncapped.
    regular_gas_cap: ?u64,
    /// Rejection cap on the intrinsic-plus-floor gas requirement; null is
    /// uncapped.
    intrinsic_regular_gas_limit: ?u64,
    /// Per-transaction gas-limit ceiling (EIP-7825); null is uncapped.
    total_gas_limit: ?u64,
    /// Pre-warm the fee recipient for execution (EIP-3651).
    warms_coinbase: bool,

    pub const Patch = struct {
        active_kinds: ?@FieldType(TransactionSpec, "active_kinds") = null,
        allowsContractCreation: ?@FieldType(TransactionSpec, "allowsContractCreation") = null,
        requiresAuthorizationList: ?@FieldType(TransactionSpec, "requiresAuthorizationList") = null,
        rejectsNonDelegatingSenderCode: ?@FieldType(TransactionSpec, "rejectsNonDelegatingSenderCode") = null,
        isDelegationCode: ?@FieldType(TransactionSpec, "isDelegationCode") = null,
        blob_schedule: OptionalPatch(tx_blob.BlobSchedule) = .inherit,
        max_initcode_size: ?usize = null,
        intrinsicBaseGas: ?@FieldType(TransactionSpec, "intrinsicBaseGas") = null,
        create_intrinsic_gas: ?u64 = null,
        calldataGas: ?@FieldType(TransactionSpec, "calldataGas") = null,
        access_list_address_gas: ?u64 = null,
        storage_key_gas: ?u64 = null,
        accessListDataGas: ?@FieldType(TransactionSpec, "accessListDataGas") = null,
        initcode_word_gas: ?u64 = null,
        authorization_intrinsic_gas: ?u64 = null,
        floorGas: ?@FieldType(TransactionSpec, "floorGas") = null,
        regular_gas_cap: OptionalPatch(u64) = .inherit,
        intrinsic_regular_gas_limit: OptionalPatch(u64) = .inherit,
        total_gas_limit: OptionalPatch(u64) = .inherit,
        warms_coinbase: ?bool = null,
    };

    fn extend(comptime self: TransactionSpec, comptime patch: Patch) TransactionSpec {
        return merge(self, patch);
    }
};

/// Fee settlement and post-execution gas accounting.
pub const SettlementSpec = struct {
    /// EIP-1559 base-fee validation and effective-price settlement.
    base_fee_active: bool,
    /// Refund cap is gas used divided by this (EIP-3529 tightened 2 to 5).
    gas_refund_cap_divisor: u64,
    /// Amsterdam split regular/state gas settlement.
    uses_state_gas_accounting: bool,
    /// Whether the EIP-7623 floor also feeds block regular-gas accounting.
    applies_calldata_floor_to_block_regular_gas: bool,
    /// Pre-Spurious-Dragon touch of the fee recipient on a zero payment.
    touches_fee_recipient_on_zero_payment: bool,

    pub const Patch = struct {
        base_fee_active: ?bool = null,
        gas_refund_cap_divisor: ?u64 = null,
        uses_state_gas_accounting: ?bool = null,
        applies_calldata_floor_to_block_regular_gas: ?bool = null,
        touches_fee_recipient_on_zero_payment: ?bool = null,
    };

    fn extend(comptime self: SettlementSpec, comptime patch: Patch) SettlementSpec {
        return merge(self, patch);
    }
};

/// EIP-7702 authorization-list processing.
pub const AuthorizationSpec = struct {
    /// Whether authorization lists are processed at all.
    active: bool,
    /// Whether processing warms the delegation target.
    warms_delegated_target: bool,
    /// Gas adjustment for an applied authorization.
    successGasAdjustment: *const fn (authorization.SuccessInput) authorization.GasAdjustment,
    /// Gas adjustment for an authorization rejected during processing.
    invalid_gas_adjustment: authorization.GasAdjustment,
    /// Gas adjustment for a malformed authorization entry.
    malformedGasAdjustment: *const fn (usize) authorization.GasAdjustment,

    pub const Patch = struct {
        active: ?bool = null,
        warms_delegated_target: ?bool = null,
        successGasAdjustment: ?@FieldType(AuthorizationSpec, "successGasAdjustment") = null,
        invalid_gas_adjustment: ?authorization.GasAdjustment = null,
        malformedGasAdjustment: ?@FieldType(AuthorizationSpec, "malformedGasAdjustment") = null,
    };

    fn extend(comptime self: AuthorizationSpec, comptime patch: Patch) AuthorizationSpec {
        return merge(self, patch);
    }
};

/// Block-lifecycle system calls.
pub const BlockSpec = struct {
    /// System calls before the first transaction (EIP-4788 beacon root,
    /// EIP-2935 history).
    beforeBlock: *const fn (block_program.BeforeBlockContext) block_program.BlockSystemCalls,
    /// System calls before each transaction.
    beforeTransaction: *const fn (block_program.BeforeTransactionContext) block_program.BlockSystemCalls,
    /// System calls after each transaction.
    afterTransaction: *const fn (block_program.AfterTransactionContext) block_program.BlockSystemCalls,
    /// End-of-block system calls (EIP-7002 withdrawal and EIP-7251
    /// consolidation requests).
    finalizeBlock: *const fn (block_program.FinalizeBlockContext) block_program.FinalizeSystemCalls,

    pub const Patch = struct {
        beforeBlock: ?@FieldType(BlockSpec, "beforeBlock") = null,
        beforeTransaction: ?@FieldType(BlockSpec, "beforeTransaction") = null,
        afterTransaction: ?@FieldType(BlockSpec, "afterTransaction") = null,
        finalizeBlock: ?@FieldType(BlockSpec, "finalizeBlock") = null,
    };

    fn extend(comptime self: BlockSpec, comptime patch: Patch) BlockSpec {
        return merge(self, patch);
    }
};

/// CALL-family pricing and account-touch policy.
pub const CallSpec = struct {
    /// Static base cost of the CALL family.
    base_gas: i64,
    /// Cold-target surcharge over `base_gas` (EIP-2929); null means no
    /// warm/cold distinction exists.
    cold_account_access_gas: ?i64,
    /// Surcharge for a nonzero value transfer.
    value_transfer_gas: i64,
    /// Gas stipend forwarded to the callee on a value transfer.
    value_stipend: i64,
    /// Charge when the call must create the recipient account.
    newAccountGas: *const fn (execution.CallNewAccountInput) execution.CallNewAccountGas,
    /// State gas for a top-frame value transfer creating the recipient
    /// (Amsterdam).
    topFrameValueTransferStateGas: *const fn (execution.TopFrameValueTransferInput) i64,
    /// Access charge for resolving an EIP-7702 delegated target, by coldness.
    delegatedAccountAccessGas: *const fn (bool) i64,
    /// Top-level delegated-target access resolution; null means no special
    /// top-level rule.
    topLevelDelegatedAccountAccess: *const fn (execution.TopLevelDelegatedAccountAccessInput) ?execution.DelegatedAccountAccess,
    /// Pre-Spurious-Dragon touch of empty recipients.
    touches_empty_recipient: bool,
    /// Child-call gas forwarding rule (all requested gas vs EIP-150 63/64).
    childGas: *const fn (execution.ChildGasInput) execution.ChildGas,

    pub const Patch = struct {
        base_gas: ?i64 = null,
        cold_account_access_gas: OptionalPatch(i64) = .inherit,
        value_transfer_gas: ?i64 = null,
        value_stipend: ?i64 = null,
        newAccountGas: ?@FieldType(CallSpec, "newAccountGas") = null,
        topFrameValueTransferStateGas: ?@FieldType(CallSpec, "topFrameValueTransferStateGas") = null,
        delegatedAccountAccessGas: ?@FieldType(CallSpec, "delegatedAccountAccessGas") = null,
        topLevelDelegatedAccountAccess: ?@FieldType(CallSpec, "topLevelDelegatedAccountAccess") = null,
        touches_empty_recipient: ?bool = null,
        childGas: ?@FieldType(CallSpec, "childGas") = null,
    };

    fn extend(comptime self: CallSpec, comptime patch: Patch) CallSpec {
        return merge(self, patch);
    }
};

/// CREATE/CREATE2 and create-transaction deployment rules.
pub const CreateSpec = struct {
    /// EIP-170 runtime-code ceiling; null is unlimited.
    code_size_limit: ?usize,
    /// Rejects runtime code by content (EIP-3541 leading 0xEF).
    rejectsCode: *const fn ([]const u8) bool,
    /// Code-deposit charge from runtime size; null on overflow.
    depositRegularGas: *const fn (i64) ?i64,
    /// Code-deposit state-gas charge (Amsterdam); null on overflow.
    depositStateGas: *const fn (i64) ?i64,
    /// Frontier quirk: deposit out-of-gas keeps the account with empty code
    /// instead of failing the create.
    deposit_regular_gas_oog_commits: bool,
    /// Pre-warm the created address (EIP-2929).
    warms_created_address: bool,
    /// Nonce assigned to fresh contracts (EIP-161 sets 1).
    initial_nonce: u64,
    /// EIP-3860 initcode ceiling for CREATE/CREATE2; null is unlimited.
    initcode_size_limit: ?usize,
    /// Per-word initcode charge, by is_create2 (EIP-3860 plus hashing).
    initcodeWordGas: *const fn (bool) i64,
    /// State gas for materializing the created account (Amsterdam).
    accountStateGas: *const fn (execution.CreateAccountStateGasInput) i64,

    pub const Patch = struct {
        code_size_limit: OptionalPatch(usize) = .inherit,
        rejectsCode: ?@FieldType(CreateSpec, "rejectsCode") = null,
        depositRegularGas: ?@FieldType(CreateSpec, "depositRegularGas") = null,
        depositStateGas: ?@FieldType(CreateSpec, "depositStateGas") = null,
        deposit_regular_gas_oog_commits: ?bool = null,
        warms_created_address: ?bool = null,
        initial_nonce: ?u64 = null,
        initcode_size_limit: OptionalPatch(usize) = .inherit,
        initcodeWordGas: ?@FieldType(CreateSpec, "initcodeWordGas") = null,
        accountStateGas: ?@FieldType(CreateSpec, "accountStateGas") = null,
    };

    fn extend(comptime self: CreateSpec, comptime patch: Patch) CreateSpec {
        return merge(self, patch);
    }
};

/// SLOAD/SSTORE pricing.
pub const StorageSpec = struct {
    /// Cold-SLOAD surcharge over the static gas (EIP-2929); null means no
    /// warm/cold distinction exists.
    sload_cold_access_gas: ?i64,
    /// EIP-2200 sentry: SSTORE fails below this remaining gas; null disables.
    sstore_minimum_gas: ?i64,
    /// SSTORE access charge by warm/cold before the write schedule
    /// (EIP-2929); null means access accounting is inactive.
    sstoreAccessGas: *const fn (execution.AccountAccessStatus) ?i64,
    /// Write cost and refund by storage transition (net-metering schedules).
    sstoreGas: *const fn (execution.StorageStatus) execution.StorageGas,
    /// State-gas charge and refund by storage transition (Amsterdam).
    sstoreStateGas: *const fn (execution.StorageStatus) execution.StorageStateGas,

    pub const Patch = struct {
        sload_cold_access_gas: OptionalPatch(i64) = .inherit,
        sstore_minimum_gas: OptionalPatch(i64) = .inherit,
        sstoreAccessGas: ?@FieldType(StorageSpec, "sstoreAccessGas") = null,
        sstoreGas: ?@FieldType(StorageSpec, "sstoreGas") = null,
        sstoreStateGas: ?@FieldType(StorageSpec, "sstoreStateGas") = null,
    };

    fn extend(comptime self: StorageSpec, comptime patch: Patch) StorageSpec {
        return merge(self, patch);
    }
};

/// SELFDESTRUCT behavior.
pub const SelfDestructSpec = struct {
    /// Balance, nonce, and marking policy at execution time (EIP-6780 shape).
    policy: *const fn (execution.SelfDestructPolicyInput) execution.SelfDestructPolicy,
    /// End-of-transaction account cleanup, by created-in-transaction.
    finalization: *const fn (bool) execution.SelfDestructFinalization,
    /// Pre-Spurious-Dragon touch of the beneficiary on a zero transfer.
    touches_beneficiary_on_zero_transfer: bool,
    /// Charge when the beneficiary account must be created.
    newAccountGas: *const fn (execution.SelfDestructNewAccountInput) execution.CallNewAccountGas,
    /// Cold-beneficiary surcharge (EIP-2929); null means no warm/cold
    /// distinction exists.
    cold_account_access_gas: ?i64,
    /// Refund granted per selfdestruct (24_000 before London removed it).
    refund_gas: i64,

    pub const Patch = struct {
        policy: ?@FieldType(SelfDestructSpec, "policy") = null,
        finalization: ?@FieldType(SelfDestructSpec, "finalization") = null,
        touches_beneficiary_on_zero_transfer: ?bool = null,
        newAccountGas: ?@FieldType(SelfDestructSpec, "newAccountGas") = null,
        cold_account_access_gas: OptionalPatch(i64) = .inherit,
        refund_gas: ?i64 = null,
    };

    fn extend(comptime self: SelfDestructSpec, comptime patch: Patch) SelfDestructSpec {
        return merge(self, patch);
    }
};

/// One complete exact EVM specification: every semantic the engine consults,
/// as a single comptime value.
pub const Spec = struct {
    transaction: TransactionSpec,
    settlement: SettlementSpec,
    authorization: AuthorizationSpec,
    block: BlockSpec,
    call: CallSpec,
    create: CreateSpec,
    storage: StorageSpec,
    self_destruct: SelfDestructSpec,
    /// Log emission for value transfers (EIP-7708 shape); null emits none.
    valueTransferLog: *const fn (execution.ValueTransferInput) ?execution.ValueTransferLog,
    /// Exact instruction table: activation, static gas, dispatch targets.
    instruction: instruction_table.Spec,
    /// Precompile set: any type declaring `Entry`, `resolve`, `active`, and
    /// `execute`.
    precompile: type,

    pub const Patch = struct {
        transaction: TransactionSpec.Patch = .{},
        settlement: SettlementSpec.Patch = .{},
        authorization: AuthorizationSpec.Patch = .{},
        block: BlockSpec.Patch = .{},
        call: CallSpec.Patch = .{},
        create: CreateSpec.Patch = .{},
        storage: StorageSpec.Patch = .{},
        self_destruct: SelfDestructSpec.Patch = .{},
        valueTransferLog: ?@FieldType(Spec, "valueTransferLog") = null,
        instruction: ?instruction_table.Spec = null,
        precompile: ?type = null,
    };

    /// Derive a complete specification from this one; unpatched fields
    /// inherit.
    pub fn extend(comptime self: Spec, comptime patch: Patch) Spec {
        return .{
            .transaction = self.transaction.extend(patch.transaction),
            .settlement = self.settlement.extend(patch.settlement),
            .authorization = self.authorization.extend(patch.authorization),
            .block = self.block.extend(patch.block),
            .call = self.call.extend(patch.call),
            .create = self.create.extend(patch.create),
            .storage = self.storage.extend(patch.storage),
            .self_destruct = self.self_destruct.extend(patch.self_destruct),
            .valueTransferLog = patch.valueTransferLog orelse self.valueTransferLog,
            .instruction = patch.instruction orelse self.instruction,
            .precompile = patch.precompile orelse self.precompile,
        };
    }
};

/// Tri-state patch for optional spec fields: inherit the base, replace with
/// a value, or replace with null to remove the rule. A plain `?T` cannot
/// express the third state because `null` already means inherit.
// Q: generate the Patch structs from their spec structs (the mapping is
// mechanical: T -> ?T, ?T -> OptionalPatch(T)) vs keep them hand-written.
pub fn OptionalPatch(comptime T: type) type {
    return union(enum) {
        inherit,
        replace: ?T,

        fn apply(self: @This(), inherited: ?T) ?T {
            return switch (self) {
                .inherit => inherited,
                .replace => |value| value,
            };
        }
    };
}

fn merge(comptime base: anytype, comptime patch: anytype) @TypeOf(base) {
    var result = base;
    inline for (std.meta.fields(@TypeOf(patch))) |field| {
        switch (@typeInfo(field.type)) {
            .@"union" => {
                if (!@hasDecl(field.type, "apply")) @compileError("unsupported patch union");
                @field(result, field.name) = @field(patch, field.name).apply(@field(base, field.name));
            },
            .optional => if (@field(patch, field.name)) |value| {
                @field(result, field.name) = value;
            },
            else => @compileError("patch fields must be optional or OptionalPatch"),
        }
    }
    return result;
}
