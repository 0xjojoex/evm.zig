//! Fork-configuration schema: the shape of a protocol `Definition`.
//!
//! A `Definition(R)` is a comptime value: a bundle of per-domain policy configs
//! keyed on a revision enum `R`. `eth/config.zig` fills this schema in for
//! mainnet, while its authoring patches are resolved before protocol binding.
//! Every value domain is complete before `Bound`; binding only resolves the
//! engine-owned instruction, transaction, settlement, and precompile APIs.
//!
//! ## Implementer contract
//!
//! This file is the canonical contract for definition implementers—the Zig
//! equivalent of Rust trait declarations and their default methods. Each Config
//! field documents one semantic hook and supplies an intentional neutral
//! default. `protocol/types.zig` owns shared input/output value types;
//! `protocol/validate.zig` owns compile-time shape diagnostics. Neither owns
//! hook semantics. Ethereum implementations and EIP rationale live beside
//! their domain in `eth/`.
//!
//! On Definition-backed Protocols, lowercase `Protocol.transaction`,
//! `.settlement`, `.authorization`, `.block`, `.call`, `.create`, `.storage`,
//! and `.self_destruct` are semantic values. Uppercase `Protocol.Transaction`,
//! `.Settlement`, `.Instruction`, and `.Precompile` are generated APIs that
//! carry engine-owned types; definitions do not replace those representations.
//!
//! This file defines schema and neutral defaults only, never Ethereum rules.
const std = @import("std");

const address = @import("address.zig");
const opcode_info = @import("opcode.zig");
const dispatcher = @import("protocol/dispatcher.zig");
const types = @import("protocol/types.zig");
const instruction_mod = @import("protocol/instruction.zig");
const support = @import("protocol/support.zig");
const tx = @import("transaction/types.zig");
const tx_blob = @import("transaction/blob.zig");
const tx_gas = @import("transaction/gas.zig");

const Address = address.Address;
const Opcode = opcode_info.Opcode;

const NeutralTransactionValidationError = enum { unsupported };

const NeutralTransactionPreparation = struct {
    pub fn For(comptime Protocol: type) type {
        return struct {
            pub fn prepare(_: tx.PrepareInput(Protocol)) !tx.PrepareResult(Protocol) {
                return error.UnsupportedTransactionPreparation;
            }
        };
    }
};

/// The fork-configuration value type over a revision enum `R`.
///
/// A comptime value of this type bundles complete per-domain config values plus
/// the instruction/precompile namespaces.
/// `Bound(value)` turns it into the runtime dispatch namespace.
pub fn Definition(comptime R: type) type {
    return struct {
        pub const Revision = R;

        name: []const u8 = "custom",
        revision: RevisionConfig(R) = .{},
        instruction: type,
        transaction: TransactionConfig(R) = .default,
        settlement: SettlementConfig(R) = .default,
        authorization: AuthorizationConfig(R) = .default,
        block: BlockConfig(R) = .default,
        call: CallConfig(R) = .default,
        create: CreateConfig(R) = .default,
        storage: StorageConfig(R) = .default,
        self_destruct: SelfDestructConfig(R) = .default,
        precompile: type,
    };
}

pub fn TransactionConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Pre-execution validation and normalization into an executable request.
        Preparation: type = NeutralTransactionPreparation,
        /// Protocol-owned rejection reason returned by `Preparation`.
        ValidationError: type = NeutralTransactionValidationError,
        /// Whether an engine transaction kind is valid at `revision`.
        kindActive: *const fn (R, tx.TxKind) bool = neverTransactionKind,
        /// Whether `kind` may target contract creation rather than a call.
        allowsContractCreation: *const fn (R, tx.TxKind) bool = neverTransactionKind,
        /// Whether `kind` requires a non-empty authorization list.
        requiresAuthorizationList: *const fn (R, tx.TxKind) bool = neverTransactionKind,
        /// Whether non-delegation sender code invalidates the transaction.
        rejectsNonDelegatingSenderCode: *const fn (R, tx.TxKind) bool = neverTransactionKind,
        /// Classifies code accepted as a delegation designator for sender checks.
        isDelegationCode: *const fn (R, []const u8) bool = neverDelegationCode,
        /// Returns the active blob market schedule, or null when blobs are inactive.
        blobSchedule: *const fn (R) ?tx_blob.BlobSchedule = noBlobSchedule,
        /// Whether a version byte is valid for blob versioned hashes.
        blobVersionedHashActive: *const fn (R, u8) bool = noBlobVersion,
        /// Maximum transaction initcode bytes; the neutral default is unbounded.
        maxInitcodeSize: *const fn (R) usize = unlimitedInitcodeSize,
        /// Base intrinsic regular gas, or null when it cannot be represented.
        intrinsicBaseGas: *const fn (R, tx_gas.IntrinsicGasOptions) ?u64 = noIntrinsicGas,
        /// Additional intrinsic regular gas for contract-creation transactions.
        createIntrinsicGas: *const fn (R) ?u64 = noCreateIntrinsicGas,
        /// Intrinsic regular gas charged for one calldata byte.
        dataByteGas: *const fn (R, u8) u64 = noDataByteGas,
        /// Intrinsic regular gas charged per access-list address.
        accessListAddressGas: *const fn (R) u64 = noRevisionGas,
        /// Intrinsic regular gas charged per access-list storage key.
        storageKeyGas: *const fn (R) u64 = noRevisionGas,
        /// Additional intrinsic data gas for access-list encoding.
        accessListDataGas: *const fn (R, tx_gas.AccessListCounts) ?u64 = noAccessListDataGas,
        /// Intrinsic regular gas charged per initcode word.
        initCodeWordGas: *const fn (R) u64 = noRevisionGas,
        /// Intrinsic regular gas charged per authorization tuple.
        authorizationIntrinsicGas: *const fn (R) u64 = noRevisionGas,
        /// Intrinsic state gas for the transaction, when dimensional gas is active.
        intrinsicStateGas: *const fn (R, tx_gas.IntrinsicGasOptions) ?u64 = noIntrinsicGas,
        /// Transaction floor gas derived from input and intrinsic options.
        floorGas: *const fn (R, tx_gas.FloorGasInput) ?u64 = noFloorGas,
        /// Regular execution-gas allowance derived from the declared gas limit.
        regularGasLimit: *const fn (R, u64) u64 = unchangedRegularGasLimit,
        /// Optional protocol cap on intrinsic regular gas.
        intrinsicRegularGasLimit: *const fn (R) ?u64 = noRevisionOptionalGas,
        /// Optional protocol cap on the transaction's total declared gas.
        totalGasLimit: *const fn (R) ?u64 = noRevisionOptionalGas,

        fn neverTransactionKind(_: R, _: tx.TxKind) bool {
            return false;
        }
        fn neverDelegationCode(_: R, _: []const u8) bool {
            return false;
        }
        fn noBlobSchedule(_: R) ?tx_blob.BlobSchedule {
            return null;
        }
        fn noBlobVersion(_: R, _: u8) bool {
            return false;
        }
        fn unlimitedInitcodeSize(_: R) usize {
            return std.math.maxInt(usize);
        }
        fn noIntrinsicGas(_: R, _: tx_gas.IntrinsicGasOptions) ?u64 {
            return 0;
        }
        fn noCreateIntrinsicGas(_: R) ?u64 {
            return 0;
        }
        fn noDataByteGas(_: R, _: u8) u64 {
            return 0;
        }
        fn noRevisionGas(_: R) u64 {
            return 0;
        }
        fn noAccessListDataGas(_: R, _: tx_gas.AccessListCounts) ?u64 {
            return 0;
        }
        fn noFloorGas(_: R, _: tx_gas.FloorGasInput) ?u64 {
            return null;
        }
        fn unchangedRegularGasLimit(_: R, gas_limit: u64) u64 {
            return gas_limit;
        }
        fn noRevisionOptionalGas(_: R) ?u64 {
            return null;
        }
    };
}

pub fn SettlementConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Whether base-fee validation and priority-fee derivation are active.
        baseFeeActive: *const fn (R) bool = inactive,
        /// Divisor limiting the execution gas refund applied at settlement.
        gasRefundCapDivisor: *const fn (R) u64 = legacyRefundCapDivisor,
        /// Whether settlement accounts for separate regular and state gas pools.
        usesStateGasAccounting: *const fn (R) bool = inactive,

        fn inactive(_: R) bool {
            return false;
        }
        fn legacyRefundCapDivisor(_: R) u64 {
            return 2;
        }
    };
}

pub fn AuthorizationConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Whether authorization tuples are processed at this revision.
        active: *const fn (R) bool = inactive,
        /// Whether a delegation target is added to the initial warm set.
        warmsDelegatedTarget: *const fn (R) bool = inactive,
        /// Refund adjustments after one authorization tuple succeeds.
        successGasAdjustment: *const fn (R, types.AuthorizationSuccessInput) types.AuthorizationGasAdjustment = noSuccessGasAdjustment,
        /// Refund adjustments when an authorization tuple is invalid.
        invalidGasAdjustment: *const fn (R) types.AuthorizationGasAdjustment = noGasAdjustment,
        /// Refund adjustments for authorization entries missing from input.
        malformedGasAdjustment: *const fn (R, usize) types.AuthorizationGasAdjustment = noMalformedGasAdjustment,

        fn inactive(_: R) bool {
            return false;
        }
        fn noSuccessGasAdjustment(_: R, _: types.AuthorizationSuccessInput) types.AuthorizationGasAdjustment {
            return .{};
        }
        fn noGasAdjustment(_: R) types.AuthorizationGasAdjustment {
            return .{};
        }
        fn noMalformedGasAdjustment(_: R, _: usize) types.AuthorizationGasAdjustment {
            return .{};
        }
    };
}

pub fn BlockConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Optional protocol log emitted for a nonzero value transfer.
        valueTransferLog: *const fn (R, types.ValueTransferInput) ?types.ValueTransferLog = noValueTransferLog,
        /// System calls executed before payload transactions begin.
        beforeBlock: *const fn (R, types.BeforeBlockContext) types.BlockSystemCalls = noBeforeBlock,
        /// System calls executed after validation and inside transaction rollback.
        beforeTransaction: *const fn (R, types.BeforeTransactionContext) types.BlockSystemCalls = noBeforeTransaction,
        /// System calls executed after the caller consumes transaction logs.
        afterTransaction: *const fn (R, types.AfterTransactionContext) types.BlockSystemCalls = noAfterTransaction,
        /// Final system calls whose outputs are returned to the family STF.
        finalizeBlock: *const fn (R, types.FinalizeBlockContext) types.FinalizeSystemCalls = noFinalizeBlock,
        /// Whether the transaction scope initially warms the fee recipient.
        transactionWarmsCoinbase: *const fn (R) bool = doesNotWarmCoinbase,

        fn noValueTransferLog(_: R, _: types.ValueTransferInput) ?types.ValueTransferLog {
            return null;
        }

        fn noBeforeBlock(_: R, _: types.BeforeBlockContext) types.BlockSystemCalls {
            return .{};
        }

        fn noBeforeTransaction(_: R, _: types.BeforeTransactionContext) types.BlockSystemCalls {
            return .{};
        }

        fn noAfterTransaction(_: R, _: types.AfterTransactionContext) types.BlockSystemCalls {
            return .{};
        }

        fn noFinalizeBlock(_: R, _: types.FinalizeBlockContext) types.FinalizeSystemCalls {
            return .{};
        }

        fn doesNotWarmCoinbase(_: R) bool {
            return false;
        }
    };
}

/// Enforces that a hand-written patch remains a null-defaulted optional mirror
/// of its complete config type.
pub fn assertPatchMirrors(comptime Config: type, comptime Patch: type) void {
    const config_fields = std.meta.fields(Config);
    const patch_fields = std.meta.fields(Patch);

    const empty_patch: Patch = .{};
    inline for (config_fields) |field| {
        if (!@hasField(Patch, field.name)) {
            @compileError("patch is missing config field: " ++ field.name);
        }
        if (@FieldType(Patch, field.name) != ?field.type) {
            @compileError("patch field must be optional config field type: " ++ field.name);
        }
        if (@field(empty_patch, field.name) != null) {
            @compileError("patch field must default to null: " ++ field.name);
        }
    }

    inline for (patch_fields) |field| {
        if (!@hasField(Config, field.name)) {
            @compileError("patch has no matching config field: " ++ field.name);
        }
    }
}

pub fn CallConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Base dynamic gas charged by CALL-family instructions.
        callBaseGas: *const fn (R) i64 = noRevisionGas,
        /// Additional gas for a cold target account, or null when not modeled.
        callColdAccountAccessGas: *const fn (R) ?i64 = noOptionalRevisionGas,
        /// Regular gas charged when a CALL transfers nonzero value.
        callValueTransferGas: *const fn (R) i64 = noRevisionGas,
        /// Gas stipend added to a value-transferring child call.
        callValueStipend: *const fn (R) i64 = noRevisionGas,
        /// Regular/state gas charged when CALL creates a recipient account.
        callNewAccountGas: *const fn (R, types.CallNewAccountInput) types.CallNewAccountGas = noNewAccountGas,
        /// State gas charged by top-frame value transfer account creation.
        topFrameValueTransferStateGas: *const fn (R, types.TopFrameValueTransferInput) i64 = noTopFrameStateGas,
        /// Gas charged to access an account through delegation code.
        delegatedAccountAccessGas: *const fn (R, bool) i64 = noDelegatedAccessGas,
        /// Optional top-level delegated account access and warm/cold status.
        topLevelDelegatedAccountAccess: *const fn (R, types.TopLevelDelegatedAccountAccessInput) ?types.DelegatedAccountAccess = noTopLevelDelegatedAccess,
        /// Whether a zero-value CALL touches an empty recipient account.
        touchesEmptyCallRecipient: *const fn (R) bool = neverTouchesEmptyRecipient,
        /// Child gas grant and out-of-gas decision for a requested allowance.
        childGas: *const fn (R, types.ChildGasInput) types.ChildGas = allAvailableChildGas,

        fn noRevisionGas(_: R) i64 {
            return 0;
        }
        fn noOptionalRevisionGas(_: R) ?i64 {
            return null;
        }
        fn noNewAccountGas(_: R, _: types.CallNewAccountInput) types.CallNewAccountGas {
            return .{};
        }
        fn noTopFrameStateGas(_: R, _: types.TopFrameValueTransferInput) i64 {
            return 0;
        }
        fn noDelegatedAccessGas(_: R, _: bool) i64 {
            return 0;
        }
        fn noTopLevelDelegatedAccess(_: R, _: types.TopLevelDelegatedAccountAccessInput) ?types.DelegatedAccountAccess {
            return null;
        }
        fn neverTouchesEmptyRecipient(_: R) bool {
            return false;
        }
        fn allAvailableChildGas(_: R, input: types.ChildGasInput) types.ChildGas {
            return .{ .gas = @min(input.requested, input.available) };
        }
    };
}

pub fn CreateConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Maximum deployed runtime-code bytes, or null when unbounded.
        createCodeSizeLimit: *const fn (R) ?usize = noSizeLimit,
        /// Whether the deployed runtime bytes are rejected by code-prefix rules.
        rejectsCreateCode: *const fn (R, []const u8) bool = neverRejectsCode,
        /// Regular gas charged to deposit `runtime_size` bytes.
        createDepositRegularGas: *const fn (R, i64) ?i64 = noDepositGas,
        /// State gas charged to deposit `runtime_size` bytes.
        createDepositStateGas: *const fn (R, i64) ?i64 = noDepositGas,
        /// Whether regular deposit OOG still commits the successful child call.
        createDepositRegularGasOogCommits: *const fn (R) bool = falseForRevision,
        /// State-gas refund when creation reuses an existing account.
        createAccountStateGasRefund: *const fn (R, bool) i64 = noAccountStateGasRefund,
        /// State-gas refund when a create transaction rolls back.
        createTransactionRollbackStateGasRefund: *const fn (R) i64 = noRevisionGas,
        /// Whether CREATE immediately warms the derived address.
        createWarmsCreatedAddress: *const fn (R) bool = falseForRevision,
        /// Initial nonce assigned to a newly created account.
        createInitialNonce: *const fn (R) u64 = zeroNonce,
        /// Maximum CREATE/CREATE2 initcode bytes, or null when unbounded.
        createInitCodeSizeLimit: *const fn (R) ?usize = noSizeLimit,
        /// Per-word initcode/hash gas for CREATE or CREATE2.
        createInitCodeWordGas: *const fn (R, bool) i64 = noInitCodeWordGas,
        /// State gas charged to materialize a newly created account.
        createAccountStateGas: *const fn (R) i64 = noRevisionGas,

        fn noSizeLimit(_: R) ?usize {
            return null;
        }
        fn neverRejectsCode(_: R, _: []const u8) bool {
            return false;
        }
        fn noDepositGas(_: R, _: i64) ?i64 {
            return 0;
        }
        fn falseForRevision(_: R) bool {
            return false;
        }
        fn noAccountStateGasRefund(_: R, _: bool) i64 {
            return 0;
        }
        fn noRevisionGas(_: R) i64 {
            return 0;
        }
        fn zeroNonce(_: R) u64 {
            return 0;
        }
        fn noInitCodeWordGas(_: R, _: bool) i64 {
            return 0;
        }
    };
}

pub fn StorageConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Additional SLOAD gas for a cold storage key.
        sloadColdStorageAccessGas: *const fn (R) ?i64 = noOptionalRevisionGas,
        /// Minimum gas required before SSTORE may execute.
        sstoreMinimumGas: *const fn (R) ?i64 = noOptionalRevisionGas,
        /// SSTORE account/key access gas for the supplied warm status.
        sstoreStorageAccessGas: *const fn (R, types.AccountAccessStatus) ?i64 = noStorageAccessGas,
        /// Regular SSTORE cost/refund for the storage transition.
        sstoreGas: *const fn (R, types.StorageStatus) types.StorageGas = noStorageGas,
        /// State-gas SSTORE charge/refund for the storage transition.
        sstoreStateGas: *const fn (R, types.StorageStatus) types.StorageStateGas = noStorageStateGas,

        fn noOptionalRevisionGas(_: R) ?i64 {
            return null;
        }
        fn noStorageAccessGas(_: R, _: types.AccountAccessStatus) ?i64 {
            return null;
        }
        fn noStorageGas(_: R, _: types.StorageStatus) types.StorageGas {
            return .{};
        }
        fn noStorageStateGas(_: R, _: types.StorageStatus) types.StorageStateGas {
            return .{};
        }
    };
}

pub fn SelfDestructConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        /// Immediate balance/nonce/self-destruct marker policy.
        selfDestructPolicy: *const fn (R, types.SelfDestructPolicyInput) types.SelfDestructPolicy = noPolicy,
        /// Transaction-end account/storage deletion policy.
        selfDestructFinalization: *const fn (R, bool) types.SelfDestructFinalization = noFinalization,
        /// Regular/state gas charged when the beneficiary account is created.
        selfDestructNewAccountGas: *const fn (R, types.SelfDestructNewAccountInput) types.CallNewAccountGas = noNewAccountGas,
        /// Additional gas for a cold beneficiary account.
        selfDestructColdAccountAccessGas: *const fn (R) ?i64 = noOptionalRevisionGas,
        /// Legacy SELFDESTRUCT refund credited to the frame.
        selfDestructRefundGas: *const fn (R) i64 = noRevisionGas,

        fn noPolicy(_: R, _: types.SelfDestructPolicyInput) types.SelfDestructPolicy {
            return .{ .clear_balance = false, .reset_nonce = false, .mark_selfdestructed = false };
        }
        fn noFinalization(_: R, _: bool) types.SelfDestructFinalization {
            return .{};
        }
        fn noNewAccountGas(_: R, _: types.SelfDestructNewAccountInput) types.CallNewAccountGas {
            return .{};
        }
        fn noOptionalRevisionGas(_: R) ?i64 {
            return null;
        }
        fn noRevisionGas(_: R) i64 {
            return 0;
        }
    };
}

/// Config block describing a revision enum `R`: its ordering, latest/stable
/// pins, and implication relation. Held as `Definition.revision`.
pub fn RevisionConfig(comptime R: type) type {
    return support.ModelConfig(R);
}

/// Builds the bound revision model (ordering + availability queries) from a
/// `RevisionConfig`. Consumed by `Bound` to resolve per-revision opcode support.
pub fn RevisionModel(comptime R: type, comptime cfg: RevisionConfig(R)) type {
    return support.ModelWithConfig(R, cfg);
}

pub fn Bound(comptime definition: anytype) type {
    const DefinitionValue = @TypeOf(definition);
    if (DefinitionValue == type) {
        @compileError("Bound expects a Definition(R) value; namespace-type definitions are no longer accepted");
    }

    const R = DefinitionValue.Revision;
    const revision_model = RevisionModel(R, definition.revision);
    const InstructionSource = definition.instruction;
    const InstructionBase = instructionDomain(InstructionSource);
    const InstructionDomain = BoundInstruction(InstructionSource, InstructionBase, revision_model.Availability);
    const transaction_config: TransactionConfig(R) = definition.transaction;
    const settlement_config: SettlementConfig(R) = definition.settlement;
    const authorization_config: AuthorizationConfig(R) = definition.authorization;
    const block_config: BlockConfig(R) = definition.block;
    const call_config: CallConfig(R) = definition.call;
    const create_config: CreateConfig(R) = definition.create;
    const storage_config: StorageConfig(R) = definition.storage;
    const self_destruct_config: SelfDestructConfig(R) = definition.self_destruct;

    return struct {
        pub const name = definition.name;
        pub const Revision = R;
        pub const revisions = revision_model.revisions;
        pub const latest = revision_model.latest;
        pub const stable = revision_model.stable;
        pub const order = revision_model.order;
        pub const isImpl = revision_model.isImpl;
        pub const RevisionSemantics = revision_model.RevisionSemantics;
        pub const BaseRevision = revision_model.BaseRevision;
        pub const baseRevision = revision_model.baseRevision;
        pub const Availability = revision_model.Availability;
        pub const Support = revision_model.Support;
        pub const resolveAvailability = revision_model.resolveAvailability;
        pub const StaticGasSource = InstructionSource;

        pub const Instruction = InstructionDomain;
        pub const transaction = transaction_config;
        pub const settlement = settlement_config;
        pub const authorization = authorization_config;
        pub const block = block_config;
        pub const call = call_config;
        pub const create = create_config;
        pub const storage = storage_config;
        pub const self_destruct = self_destruct_config;
        pub const Precompile = definition.precompile;

        pub fn opcodeInfoByte(comptime opcode_byte: u8) opcode_info.OpInfo {
            return Instruction.info(Instruction.fromByte(opcode_byte));
        }

        pub fn opcodeInfo(comptime opcode: Opcode) opcode_info.OpInfo {
            return opcodeInfoByte(@intFromEnum(opcode));
        }

        pub fn opcodeAvailabilityByte(comptime opcode_byte: u8) Availability {
            return Instruction.availability(Instruction.fromByte(opcode_byte));
        }

        pub fn opcodeAvailability(comptime opcode: Opcode) Availability {
            return opcodeAvailabilityByte(@intFromEnum(opcode));
        }

        pub fn opcodeTierByte(comptime opcode_byte: u8) support.OpcodeTier {
            return Instruction.tier(Instruction.fromByte(opcode_byte));
        }

        pub fn opcodeTier(comptime opcode: Opcode) support.OpcodeTier {
            return opcodeTierByte(@intFromEnum(opcode));
        }

        pub fn staticGasForRevisionByte(revision: Revision, comptime opcode_byte: u8) i64 {
            return InstructionSource.staticGasForRevisionByte(revision, opcode_byte);
        }

        pub fn staticGasForRevision(revision: Revision, comptime opcode: Opcode) i64 {
            return staticGasForRevisionByte(revision, @intFromEnum(opcode));
        }

        pub fn staticGasForRevisionInstruction(revision: Revision, comptime value: Instruction.Value) i64 {
            if (comptime std.meta.hasFn(InstructionSource, "staticGasForRevisionInstruction")) {
                return InstructionSource.staticGasForRevisionInstruction(revision, value);
            }
            return switch (comptime Instruction.context(value)) {
                .byte => |opcode_byte| staticGasForRevisionByte(revision, opcode_byte),
                .custom => @compileError("Definition.instruction with custom values must provide staticGasForRevisionInstruction"),
            };
        }
    };
}

fn instructionDomain(comptime InstructionSource: type) type {
    if (@hasDecl(InstructionSource, "Value")) {
        return InstructionSource;
    }
    if (@hasDecl(InstructionSource, "Instruction")) {
        return InstructionSource.Instruction;
    }
    @compileError("Definition.instruction must expose Value or nested Instruction");
}

fn BoundInstruction(comptime InstructionSource: type, comptime Base: type, comptime Availability: type) type {
    _ = InstructionSource;

    return struct {
        pub const Value = Base.Value;

        pub fn fromByte(comptime opcode_byte: u8) Value {
            return Base.fromByte(opcode_byte);
        }

        pub fn context(comptime value: Value) instruction_mod.Context {
            return Base.context(value);
        }

        pub fn info(comptime value: Value) opcode_info.OpInfo {
            return Base.info(value);
        }

        pub fn availability(comptime value: Value) Availability {
            return coerceAvailability(Availability, Base.availability(value));
        }

        pub fn tier(comptime value: Value) support.OpcodeTier {
            return Base.tier(value);
        }

        pub fn executionTarget(comptime value: Value) dispatcher.ExecutionTarget {
            return Base.executionTarget(value);
        }

        pub fn expByteGas(revision: anytype) i64 {
            return Base.expByteGas(revision);
        }

        pub fn accountReadColdAccessGas(revision: anytype) ?i64 {
            return Base.accountReadColdAccessGas(revision);
        }

        pub fn codeAccountAccessGas(revision: anytype, status: types.AccountAccessStatus) ?i64 {
            return Base.codeAccountAccessGas(revision, status);
        }
    };
}

fn coerceAvailability(comptime Availability: type, comptime value: anytype) Availability {
    return switch (value) {
        .never => .never,
        .always => .always,
        .since => |revision| .{ .since = revision },
        .gate => |active| .{ .gate = active },
    };
}

test "revision model accepts custom ordering function" {
    const R = enum(u8) {
        alpha = 10,
        beta = 5,
    };
    const reverse = struct {
        fn order(a: R, b: R) std.math.Order {
            return std.math.order(@intFromEnum(b), @intFromEnum(a));
        }
    };
    const model = RevisionModel(R, .{
        .revisions = &.{ .alpha, .beta },
        .latest = .beta,
        .order = reverse.order,
    });

    comptime {
        if (reverse.order(.beta, .alpha) != .gt) @compileError("reverse order check is broken");
        if (!model.isImpl(.beta, .alpha)) @compileError("custom isImpl override was not applied");
    }

    try std.testing.expectEqual(R.beta, model.latest);
    try std.testing.expect(model.isImpl(.beta, .alpha));
    try std.testing.expect(!model.isImpl(.alpha, .beta));

    const full = comptime model.Support.range(.alpha, .beta);
    full.assertValid();
    try std.testing.expect(full.contains(.beta));
    try std.testing.expectEqual(support.Resolution.runtime, model.resolveAvailability(.{ .since = .beta }, full));
}

test "block config carries complete neutral policy" {
    const R = enum { one };
    const block = BlockConfig(R).default;
    const zero_address = std.mem.zeroes(Address);

    try std.testing.expectEqual(@as(?types.ValueTransferLog, null), block.valueTransferLog(.one, .{
        .from = zero_address,
        .to = zero_address,
        .amount = 0,
    }));
    try std.testing.expectEqual(@as(usize, 0), block.beforeBlock(.one, .{
        .number = 0,
        .timestamp = 0,
    }).slice().len);
    try std.testing.expectEqual(@as(usize, 0), block.beforeTransaction(.one, .{
        .number = 0,
        .timestamp = 0,
        .transaction_index = 0,
    }).slice().len);
    try std.testing.expect(!block.transactionWarmsCoinbase(.one));
}

test "definition value domains default to complete neutral configs" {
    const R = enum { one };
    const value: Definition(R) = .{
        .instruction = void,
        .precompile = void,
    };

    try std.testing.expect(!value.transaction.kindActive(.one, .legacy));
    try std.testing.expect(!value.authorization.active(.one));
    try std.testing.expectEqual(@as(i64, 0), value.call.callBaseGas(.one));
    try std.testing.expectEqual(@as(?usize, null), value.create.createCodeSizeLimit(.one));
    try std.testing.expectEqual(@as(?i64, null), value.storage.sstoreMinimumGas(.one));
}
