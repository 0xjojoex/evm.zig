//! Fork-configuration schema: the shape of a protocol `Definition`.
//!
//! A `Definition(R)` is a comptime *value* — a bundle of per-domain config
//! structs (transaction, settlement, call, storage, …) whose fields are
//! optional `*const fn` hooks keyed on a revision enum `R`. A null hook means
//! "use the engine default"; a set hook overrides that one rule. `eth/config.zig`
//! fills this schema in for mainnet; `protocol.zig`'s `Bound`/`Rules` turn a
//! definition value into the bound namespace the runtime dispatches through.
//!
//! This file defines only the schema and its defaults, no Ethereum rules. To
//! add a variation point: add a field here, implement it in `eth/<domain>.zig`,
//! and forward it from the matching `Bound*` type.
const std = @import("std");

const address = @import("address.zig");
const opcode_info = @import("opcode.zig");
const dispatcher = @import("protocol/dispatcher.zig");
const interface = @import("protocol/interface.zig");
const instruction_mod = @import("protocol/instruction.zig");
const support = @import("protocol/support.zig");
const tx = @import("transaction/types.zig");
const tx_blob = @import("transaction/blob.zig");
const tx_gas = @import("transaction/gas.zig");
const tx_settlement = @import("transaction/settlement.zig");

const Address = address.Address;
const Opcode = opcode_info.Opcode;

/// The fork-configuration value type over a revision enum `R`.
///
/// A comptime value of this type bundles the per-domain config structs (each a
/// set of optional `*const fn` hooks) plus the instruction/precompile namespaces.
/// `Bound(value)` turns it into the runtime dispatch namespace.
pub fn Definition(comptime R: type) type {
    return struct {
        pub const Revision = R;

        name: []const u8 = "custom",
        revision: RevisionConfig(R) = .{},
        instruction: type,
        transaction: TransactionConfig(R),
        settlement: SettlementConfig(R),
        authorization: AuthorizationConfig(R),
        block: BlockConfig(R),
        call: CallConfig(R),
        create: CreateConfig(R),
        storage: StorageConfig(R),
        self_destruct: SelfDestructConfig(R),
        precompile: type,
    };
}

pub fn TransactionConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        kindActive: ?*const fn (R, tx.TxKind) bool = null,
        allowsContractCreation: ?*const fn (R, tx.TxKind) bool = null,
        requiresAuthorizationList: ?*const fn (R, tx.TxKind) bool = null,
        rejectsNonDelegatingSenderCode: ?*const fn (R, tx.TxKind) bool = null,
        blobSchedule: ?*const fn (R) ?tx_blob.BlobSchedule = null,
        blobVersionedHashActive: ?*const fn (R, u8) bool = null,
        maxInitcodeSize: ?*const fn (R) usize = null,
        intrinsicBaseGas: ?*const fn (R, tx_gas.IntrinsicGasOptions) ?u64 = null,
        createIntrinsicGas: ?*const fn (R) ?u64 = null,
        dataByteGas: ?*const fn (R, u8) u64 = null,
        accessListAddressGas: ?*const fn (R) u64 = null,
        storageKeyGas: ?*const fn (R) u64 = null,
        accessListDataGas: ?*const fn (R, tx_gas.AccessListCounts) ?u64 = null,
        initCodeWordGas: ?*const fn (R) u64 = null,
        authorizationIntrinsicGas: ?*const fn (R) u64 = null,
        intrinsicStateGas: ?*const fn (R, tx_gas.IntrinsicGasOptions) ?u64 = null,
        floorGas: ?*const fn (R, []const u8, tx_gas.IntrinsicGasOptions) ?u64 = null,
        regularGasLimit: ?*const fn (R, u64) u64 = null,
        intrinsicRegularGasLimit: ?*const fn (R) ?u64 = null,
        totalGasLimit: ?*const fn (R) ?u64 = null,
    };
}

pub fn SettlementConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        baseFeeActive: ?*const fn (R) bool = null,
        gasRefundCapDivisor: ?*const fn (R) u64 = null,
        usesStateGasAccounting: ?*const fn (R) bool = null,
    };
}

pub fn AuthorizationConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        active: ?*const fn (R) bool = null,
        warmsDelegatedTarget: ?*const fn (R) bool = null,
        successGasAdjustment: ?*const fn (R, bool, bool, bool, bool) interface.AuthorizationGasAdjustment = null,
        invalidGasAdjustment: ?*const fn (R) interface.AuthorizationGasAdjustment = null,
        malformedGasAdjustment: ?*const fn (R, usize) interface.AuthorizationGasAdjustment = null,
    };
}

pub fn BlockConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        valueTransferLog: ?*const fn (R, Address, Address, u256) ?interface.ValueTransferLog = null,
        blockStartSystemCalls: ?*const fn (R, interface.BlockStartContext) interface.BlockStartSystemCalls = null,
        transactionWarmsCoinbase: ?*const fn (R) bool = null,
    };
}

pub fn CallConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        callBaseGas: ?*const fn (R) i64 = null,
        callColdAccountAccessGas: ?*const fn (R) ?i64 = null,
        callValueTransferGas: ?*const fn (R) i64 = null,
        callValueStipend: ?*const fn (R) i64 = null,
        callNewAccountGas: ?*const fn (R, u256, bool) interface.CallNewAccountGas = null,
        topFrameValueTransferStateGas: ?*const fn (R, u256, bool, bool) i64 = null,
        delegatedAccountAccessGas: ?*const fn (R, bool) i64 = null,
        topLevelDelegatedAccountAccess: ?*const fn (R, bool, bool) ?interface.DelegatedAccountAccess = null,
        touchesEmptyCallRecipient: ?*const fn (R) bool = null,
        childGas: ?*const fn (R, i64, i64) interface.ChildGas = null,
    };
}

pub fn CreateConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        createCodeSizeLimit: ?*const fn (R) ?usize = null,
        rejectsCreateCode: ?*const fn (R, []const u8) bool = null,
        createDepositRegularGas: ?*const fn (R, i64) ?i64 = null,
        createDepositStateGas: ?*const fn (R, i64) ?i64 = null,
        createDepositRegularGasOogCommits: ?*const fn (R) bool = null,
        createAccountStateGasRefund: ?*const fn (R, bool) i64 = null,
        createTransactionRollbackStateGasRefund: ?*const fn (R) i64 = null,
        createWarmsCreatedAddress: ?*const fn (R) bool = null,
        createInitialNonce: ?*const fn (R) u64 = null,
        createInitCodeSizeLimit: ?*const fn (R) ?usize = null,
        createInitCodeWordGas: ?*const fn (R, bool) i64 = null,
        createAccountStateGas: ?*const fn (R) i64 = null,
    };
}

pub fn StorageConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        sloadColdStorageAccessGas: ?*const fn (R) ?i64 = null,
        sstoreMinimumGas: ?*const fn (R) ?i64 = null,
        sstoreStorageAccessGas: ?*const fn (R, interface.AccountAccessStatus) ?i64 = null,
        sstoreGas: ?*const fn (R, interface.StorageStatus) interface.StorageGas = null,
        sstoreStateGas: ?*const fn (R, interface.StorageStatus) interface.StorageStateGas = null,
    };
}

pub fn SelfDestructConfig(comptime R: type) type {
    return struct {
        const Self = @This();

        pub const default: Self = .{};

        selfDestructPolicy: ?*const fn (R, bool, bool) interface.SelfDestructPolicy = null,
        selfDestructFinalization: ?*const fn (R, bool) interface.SelfDestructFinalization = null,
        selfDestructNewAccountGas: ?*const fn (R, bool, bool, bool) interface.CallNewAccountGas = null,
        selfDestructColdAccountAccessGas: ?*const fn (R) ?i64 = null,
        selfDestructRefundGas: ?*const fn (R) i64 = null,
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
    assertRequiredConfig("Definition.transaction", TransactionConfig(R), definition.transaction, &.{
        "blobSchedule",
        "blobVersionedHashActive",
    });
    assertRequiredConfig("Definition.settlement", SettlementConfig(R), definition.settlement, &.{
        "baseFeeActive",
        "usesStateGasAccounting",
    });
    assertRequiredConfig("Definition.authorization", AuthorizationConfig(R), definition.authorization, &.{
        "active",
        "warmsDelegatedTarget",
        "successGasAdjustment",
        "invalidGasAdjustment",
        "malformedGasAdjustment",
    });
    assertRequiredConfig("Definition.block", BlockConfig(R), definition.block, &.{
        "valueTransferLog",
        "blockStartSystemCalls",
        "transactionWarmsCoinbase",
    });
    assertRequiredConfig("Definition.call", CallConfig(R), definition.call, &.{
        "callColdAccountAccessGas",
        "topFrameValueTransferStateGas",
        "topLevelDelegatedAccountAccess",
    });
    assertRequiredConfig("Definition.create", CreateConfig(R), definition.create, &.{
        "createCodeSizeLimit",
        "rejectsCreateCode",
        "createDepositStateGas",
        "createDepositRegularGasOogCommits",
        "createAccountStateGasRefund",
        "createTransactionRollbackStateGasRefund",
        "createWarmsCreatedAddress",
        "createInitCodeSizeLimit",
        "createAccountStateGas",
    });
    assertRequiredConfig("Definition.storage", StorageConfig(R), definition.storage, &.{
        "sloadColdStorageAccessGas",
        "sstoreMinimumGas",
        "sstoreStorageAccessGas",
        "sstoreStateGas",
    });
    assertRequiredConfig("Definition.self_destruct", SelfDestructConfig(R), definition.self_destruct, &.{
        "selfDestructColdAccountAccessGas",
    });

    return struct {
        pub const name = definition.name;
        pub const Revision = R;
        pub const revisions = revision_model.revisions;
        pub const latest = revision_model.latest;
        pub const stable = revision_model.stable;
        pub const isImpl = revision_model.isImpl;
        pub const Availability = revision_model.Availability;
        pub const Support = revision_model.Support;
        pub const resolveAvailability = revision_model.resolveAvailability;
        pub const StaticGasSource = InstructionSource;

        pub const Instruction = InstructionDomain;
        pub const Transaction = BoundTransaction(R, definition.transaction);
        pub const Settlement = BoundSettlement(R, definition.settlement);
        pub const Authorization = BoundAuthorization(R, definition.authorization);
        pub const Block = BoundBlock(R, definition.block);
        pub const Call = BoundCall(R, definition.call);
        pub const Create = BoundCreate(R, definition.create);
        pub const Storage = BoundStorage(R, definition.storage);
        pub const SelfDestruct = BoundSelfDestruct(R, definition.self_destruct);
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

fn assertRequiredConfig(comptime label: []const u8, comptime T: type, comptime cfg: T, comptime optional_fields: []const []const u8) void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@field(cfg, field.name) == null and !containsName(optional_fields, field.name)) {
            @compileError(label ++ "." ++ field.name ++ " required");
        }
    }
}

fn containsName(comptime names: []const []const u8, comptime needle: []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn BoundTransaction(comptime R: type, comptime cfg: TransactionConfig(R)) type {
    return struct {
        pub fn kindActive(revision_value: R, kind: tx.TxKind) bool {
            return cfg.kindActive.?(revision_value, kind);
        }

        pub fn allowsContractCreation(revision_value: R, kind: tx.TxKind) bool {
            return cfg.allowsContractCreation.?(revision_value, kind);
        }

        pub fn requiresAuthorizationList(revision_value: R, kind: tx.TxKind) bool {
            return cfg.requiresAuthorizationList.?(revision_value, kind);
        }

        pub fn rejectsNonDelegatingSenderCode(revision_value: R, kind: tx.TxKind) bool {
            return cfg.rejectsNonDelegatingSenderCode.?(revision_value, kind);
        }

        pub fn blobSchedule(revision_value: R) ?tx_blob.BlobSchedule {
            return if (cfg.blobSchedule) |blob_schedule| blob_schedule(revision_value) else null;
        }

        pub fn blobVersionedHashActive(revision_value: R, version: u8) bool {
            return if (cfg.blobVersionedHashActive) |active| active(revision_value, version) else false;
        }

        pub fn maxInitcodeSize(revision_value: R) usize {
            return cfg.maxInitcodeSize.?(revision_value);
        }

        pub fn intrinsicBaseGas(revision_value: R, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return cfg.intrinsicBaseGas.?(revision_value, options);
        }

        pub fn createIntrinsicGas(revision_value: R) ?u64 {
            return cfg.createIntrinsicGas.?(revision_value);
        }

        pub fn dataByteGas(revision_value: R, byte: u8) u64 {
            return cfg.dataByteGas.?(revision_value, byte);
        }

        pub fn accessListAddressGas(revision_value: R) u64 {
            return cfg.accessListAddressGas.?(revision_value);
        }

        pub fn storageKeyGas(revision_value: R) u64 {
            return cfg.storageKeyGas.?(revision_value);
        }

        pub fn accessListDataGas(revision_value: R, counts: tx_gas.AccessListCounts) ?u64 {
            return cfg.accessListDataGas.?(revision_value, counts);
        }

        pub fn initCodeWordGas(revision_value: R) u64 {
            return cfg.initCodeWordGas.?(revision_value);
        }

        pub fn authorizationIntrinsicGas(revision_value: R) u64 {
            return cfg.authorizationIntrinsicGas.?(revision_value);
        }

        pub fn intrinsicStateGas(revision_value: R, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return cfg.intrinsicStateGas.?(revision_value, options);
        }

        pub fn floorGas(revision_value: R, input: []const u8, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return cfg.floorGas.?(revision_value, input, options);
        }

        pub fn regularGasLimit(revision_value: R, gas_limit: u64) u64 {
            return cfg.regularGasLimit.?(revision_value, gas_limit);
        }

        pub fn intrinsicRegularGasLimit(revision_value: R) ?u64 {
            return cfg.intrinsicRegularGasLimit.?(revision_value);
        }

        pub fn totalGasLimit(revision_value: R) ?u64 {
            return cfg.totalGasLimit.?(revision_value);
        }
    };
}

fn BoundSettlement(comptime R: type, comptime cfg: SettlementConfig(R)) type {
    return struct {
        pub const Plan = tx_settlement.Plan;

        pub fn revisionId(plan: Plan) support.RevisionId {
            return plan.revision_id;
        }

        pub fn precharge(plan: Plan) tx_settlement.Precharge {
            return .{
                .payer = plan.payer,
                .upfront_debit = plan.upfront_debit,
                .minimum_balance = plan.minimum_balance,
            };
        }

        pub fn feeRecipient(plan: Plan) ?Address {
            return plan.coinbase;
        }

        pub fn costs(comptime Protocol: type, plan: Plan, result: tx_settlement.ExecutionGasResult) !tx_settlement.SettlementCosts {
            return tx_settlement.For(Protocol).settlementCosts(plan, result);
        }

        pub fn baseFeeActive(revision_value: R) bool {
            return if (cfg.baseFeeActive) |active| active(revision_value) else false;
        }

        pub fn gasRefundCapDivisor(revision_value: R) u64 {
            return cfg.gasRefundCapDivisor.?(revision_value);
        }

        pub fn usesStateGasAccounting(revision_value: R) bool {
            return if (cfg.usesStateGasAccounting) |uses| uses(revision_value) else false;
        }
    };
}

fn BoundAuthorization(comptime R: type, comptime cfg: AuthorizationConfig(R)) type {
    return struct {
        pub fn active(revision_value: R) bool {
            return if (cfg.active) |active_fn| active_fn(revision_value) else false;
        }

        pub fn warmsDelegatedTarget(revision_value: R) bool {
            return if (cfg.warmsDelegatedTarget) |warms| warms(revision_value) else false;
        }

        pub fn successGasAdjustment(
            revision_value: R,
            account_exists: bool,
            clears_delegation: bool,
            cur_delegated: bool,
            pre_delegated: bool,
        ) interface.AuthorizationGasAdjustment {
            return if (cfg.successGasAdjustment) |adjust|
                adjust(revision_value, account_exists, clears_delegation, cur_delegated, pre_delegated)
            else
                .{};
        }

        pub fn invalidGasAdjustment(revision_value: R) interface.AuthorizationGasAdjustment {
            return if (cfg.invalidGasAdjustment) |adjust| adjust(revision_value) else .{};
        }

        pub fn malformedGasAdjustment(revision_value: R, missing_count: usize) interface.AuthorizationGasAdjustment {
            return if (cfg.malformedGasAdjustment) |adjust| adjust(revision_value, missing_count) else .{};
        }
    };
}

fn BoundBlock(comptime R: type, comptime cfg: BlockConfig(R)) type {
    return struct {
        pub fn valueTransferLog(revision_value: R, from: Address, to: Address, amount: u256) ?interface.ValueTransferLog {
            return if (cfg.valueTransferLog) |value_transfer_log| value_transfer_log(revision_value, from, to, amount) else null;
        }

        pub fn blockStartSystemCalls(revision_value: R, context: interface.BlockStartContext) interface.BlockStartSystemCalls {
            return if (cfg.blockStartSystemCalls) |system_calls| system_calls(revision_value, context) else .{};
        }

        pub fn transactionWarmsCoinbase(revision_value: R) bool {
            return if (cfg.transactionWarmsCoinbase) |warms| warms(revision_value) else false;
        }
    };
}

fn BoundCall(comptime R: type, comptime cfg: CallConfig(R)) type {
    return struct {
        pub fn callBaseGas(revision_value: R) i64 {
            return cfg.callBaseGas.?(revision_value);
        }

        pub fn callColdAccountAccessGas(revision_value: R) ?i64 {
            return if (cfg.callColdAccountAccessGas) |gas| gas(revision_value) else null;
        }

        pub fn callValueTransferGas(revision_value: R) i64 {
            return cfg.callValueTransferGas.?(revision_value);
        }

        pub fn callValueStipend(revision_value: R) i64 {
            return cfg.callValueStipend.?(revision_value);
        }

        pub fn callNewAccountGas(revision_value: R, value: u256, account_exists: bool) interface.CallNewAccountGas {
            return cfg.callNewAccountGas.?(revision_value, value, account_exists);
        }

        pub fn topFrameValueTransferStateGas(revision_value: R, value: u256, same_address: bool, account_exists: bool) i64 {
            return if (cfg.topFrameValueTransferStateGas) |gas| gas(revision_value, value, same_address, account_exists) else 0;
        }

        pub fn delegatedAccountAccessGas(revision_value: R, cold: bool) i64 {
            return cfg.delegatedAccountAccessGas.?(revision_value, cold);
        }

        pub fn topLevelDelegatedAccountAccess(revision_value: R, target_is_precompile: bool, already_warm: bool) ?interface.DelegatedAccountAccess {
            return if (cfg.topLevelDelegatedAccountAccess) |access| access(revision_value, target_is_precompile, already_warm) else null;
        }

        pub fn touchesEmptyCallRecipient(revision_value: R) bool {
            return cfg.touchesEmptyCallRecipient.?(revision_value);
        }

        pub fn childGas(revision_value: R, requested: i64, available: i64) interface.ChildGas {
            return cfg.childGas.?(revision_value, requested, available);
        }
    };
}

fn BoundCreate(comptime R: type, comptime cfg: CreateConfig(R)) type {
    return struct {
        pub fn createCodeSizeLimit(revision_value: R) ?usize {
            return if (cfg.createCodeSizeLimit) |limit| limit(revision_value) else null;
        }

        pub fn rejectsCreateCode(revision_value: R, code: []const u8) bool {
            return if (cfg.rejectsCreateCode) |rejects| rejects(revision_value, code) else false;
        }

        pub fn createDepositRegularGas(revision_value: R, runtime_size: i64) ?i64 {
            return cfg.createDepositRegularGas.?(revision_value, runtime_size);
        }

        pub fn createDepositStateGas(revision_value: R, runtime_size: i64) ?i64 {
            return if (cfg.createDepositStateGas) |gas| gas(revision_value, runtime_size) else 0;
        }

        pub fn createDepositRegularGasOogCommits(revision_value: R) bool {
            return if (cfg.createDepositRegularGasOogCommits) |commits| commits(revision_value) else false;
        }

        pub fn createAccountStateGasRefund(revision_value: R, account_pre_existing: bool) i64 {
            return if (cfg.createAccountStateGasRefund) |refund| refund(revision_value, account_pre_existing) else 0;
        }

        pub fn createTransactionRollbackStateGasRefund(revision_value: R) i64 {
            return if (cfg.createTransactionRollbackStateGasRefund) |refund| refund(revision_value) else 0;
        }

        pub fn createWarmsCreatedAddress(revision_value: R) bool {
            return if (cfg.createWarmsCreatedAddress) |warms| warms(revision_value) else false;
        }

        pub fn createInitialNonce(revision_value: R) u64 {
            return cfg.createInitialNonce.?(revision_value);
        }

        pub fn createInitCodeSizeLimit(revision_value: R) ?usize {
            return if (cfg.createInitCodeSizeLimit) |limit| limit(revision_value) else null;
        }

        pub fn createInitCodeWordGas(revision_value: R, is_create2: bool) i64 {
            return cfg.createInitCodeWordGas.?(revision_value, is_create2);
        }

        pub fn createAccountStateGas(revision_value: R) i64 {
            return if (cfg.createAccountStateGas) |gas| gas(revision_value) else 0;
        }
    };
}

fn BoundStorage(comptime R: type, comptime cfg: StorageConfig(R)) type {
    return struct {
        pub fn sloadColdStorageAccessGas(revision_value: R) ?i64 {
            return if (cfg.sloadColdStorageAccessGas) |gas| gas(revision_value) else null;
        }

        pub fn sstoreMinimumGas(revision_value: R) ?i64 {
            return if (cfg.sstoreMinimumGas) |gas| gas(revision_value) else null;
        }

        pub fn sstoreStorageAccessGas(revision_value: R, status: interface.AccountAccessStatus) ?i64 {
            return if (cfg.sstoreStorageAccessGas) |gas| gas(revision_value, status) else null;
        }

        pub fn sstoreGas(revision_value: R, status: interface.StorageStatus) interface.StorageGas {
            return cfg.sstoreGas.?(revision_value, status);
        }

        pub fn sstoreStateGas(revision_value: R, status: interface.StorageStatus) interface.StorageStateGas {
            return if (cfg.sstoreStateGas) |gas| gas(revision_value, status) else .{};
        }
    };
}

fn BoundSelfDestruct(comptime R: type, comptime cfg: SelfDestructConfig(R)) type {
    return struct {
        pub fn selfDestructPolicy(revision_value: R, same_address: bool, created_in_transaction: bool) interface.SelfDestructPolicy {
            return cfg.selfDestructPolicy.?(revision_value, same_address, created_in_transaction);
        }

        pub fn selfDestructFinalization(revision_value: R, created_in_transaction: bool) interface.SelfDestructFinalization {
            return cfg.selfDestructFinalization.?(revision_value, created_in_transaction);
        }

        pub fn selfDestructNewAccountGas(revision_value: R, same_address: bool, transfers_balance: bool, account_exists: bool) interface.CallNewAccountGas {
            return cfg.selfDestructNewAccountGas.?(revision_value, same_address, transfers_balance, account_exists);
        }

        pub fn selfDestructColdAccountAccessGas(revision_value: R) ?i64 {
            return if (cfg.selfDestructColdAccountAccessGas) |gas| gas(revision_value) else null;
        }

        pub fn selfDestructRefundGas(revision_value: R) i64 {
            return cfg.selfDestructRefundGas.?(revision_value);
        }
    };
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

        pub fn codeAccountAccessGas(revision: anytype, status: @import("protocol/interface.zig").AccountAccessStatus) ?i64 {
            return Base.codeAccountAccessGas(revision, status);
        }
    };
}

fn coerceAvailability(comptime Availability: type, comptime value: anytype) Availability {
    return switch (value) {
        .never => .never,
        .always => .always,
        .since => |revision| .{ .since = revision },
    };
}

test "revision model accepts custom ordering function" {
    const R = enum(u8) {
        alpha = 10,
        beta = 5,
    };
    const reverse = struct {
        fn isImpl(current: R, fork: R) bool {
            return @intFromEnum(current) <= @intFromEnum(fork);
        }
    };
    const model = RevisionModel(R, .{
        .revisions = &.{ .alpha, .beta },
        .latest = .beta,
        .isImpl = reverse.isImpl,
    });

    comptime {
        if (!reverse.isImpl(.beta, .alpha)) @compileError("reverse isImpl check is broken");
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
