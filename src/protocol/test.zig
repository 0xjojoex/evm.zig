const std = @import("std");

const address = @import("../address.zig");
const definition = @import("../definition.zig");
const opcode_info = @import("../opcode.zig");
const precompile_mod = @import("../precompile.zig");
const precompile_runtime = @import("../execution/precompile_runtime.zig");
const tx = @import("../transaction.zig");
const tx_gas = @import("../transaction/gas.zig");
const eth_config = @import("../eth/config.zig");

const protocol = @import("../protocol.zig");
const binding = @import("binding.zig");
const validate = @import("validate.zig");
const support = @import("support.zig");
const types = @import("types.zig");
const compileExecution = binding.compileExecution;
const compileTransaction = binding.compileTransaction;
const Resolution = protocol.Resolution;
const ExecutionTarget = protocol.ExecutionTarget;
const RevisionModel = support.Model;
const InstructionContext = @import("instruction.zig").Context;
const OpcodeTier = protocol.OpcodeTier;
const StaticGas = protocol.StaticGas;
const assertExecutionContract = struct {
    fn call(comptime execution_rules: anytype) void {
        validate.assertExecutionContract(definition.ExecutionModel(execution_rules));
    }
}.call;
const assertDispatchContract = struct {
    fn call(comptime execution_rules: anytype) void {
        validate.assertDispatchContract(definition.ExecutionModel(execution_rules));
    }
}.call;

fn instructionFor(comptime ProtocolType: type, comptime opcode: opcode_info.Opcode) ProtocolType.Instruction.Value {
    return ProtocolType.Instruction.fromByte(@intFromEnum(opcode));
}

fn testExecutionRules(
    comptime R: type,
    comptime Instruction: type,
    comptime create_code_size_limit: ?*const fn (R) ?usize,
) definition.ExecutionRules(R) {
    const Neutral = struct {
        fn valueTransferLog(_: R, _: types.ValueTransferInput) ?types.ValueTransferLog {
            return null;
        }
    };
    return .{
        .name = "test",
        .revision = .{},
        .instruction = Instruction,
        .value_transfer_log = Neutral.valueTransferLog,
        .call = testCallConfig(R),
        .create = testCreateConfig(R, create_code_size_limit),
        .storage = testStorageConfig(R),
        .self_destruct = testSelfDestructConfig(R),
        .precompile = TestPrecompile(R),
    };
}

fn testTransactionLayerRules(comptime R: type) definition.TransactionLayerRules(R) {
    return .{
        .transaction = testTransactionConfig(R),
        .settlement = testSettlementConfig(R),
        .authorization = .default,
    };
}

fn protocolFor(
    comptime execution_rules: anytype,
    comptime support_window: definition.ExecutionModel(execution_rules).Support,
) type {
    return compileExecution(execution_rules, support_window);
}

fn testTransactionConfig(comptime R: type) definition.TransactionConfig(R) {
    const F = struct {
        fn kindActive(_: R, _: tx.TxKind) bool {
            return true;
        }

        fn allowsContractCreation(_: R, _: tx.TxKind) bool {
            return true;
        }

        fn requiresAuthorizationList(_: R, _: tx.TxKind) bool {
            return false;
        }

        fn rejectsNonDelegatingSenderCode(_: R, _: tx.TxKind) bool {
            return false;
        }

        fn maxInitcodeSize(_: R) usize {
            return std.math.maxInt(usize);
        }

        fn intrinsicBaseGas(_: R, _: tx_gas.IntrinsicGasOptions) ?u64 {
            return 0;
        }

        fn createIntrinsicGas(_: R) ?u64 {
            return 0;
        }

        fn calldataGas(_: R, _: []const u8) ?u64 {
            return 0;
        }

        fn accessListAddressGas(_: R) u64 {
            return 0;
        }

        fn storageKeyGas(_: R) u64 {
            return 0;
        }

        fn accessListDataGas(_: R, _: tx_gas.AccessListCounts) ?u64 {
            return 0;
        }

        fn initCodeWordGas(_: R) u64 {
            return 0;
        }

        fn authorizationIntrinsicGas(_: R) u64 {
            return 0;
        }

        fn floorGas(_: R, _: tx_gas.FloorGasInput) ?u64 {
            return null;
        }

        fn regularGasLimit(_: R, gas_limit: u64) u64 {
            return gas_limit;
        }

        fn intrinsicRegularGasLimit(_: R) ?u64 {
            return null;
        }

        fn totalGasLimit(_: R) ?u64 {
            return null;
        }
    };
    return .{
        .kindActive = F.kindActive,
        .allowsContractCreation = F.allowsContractCreation,
        .requiresAuthorizationList = F.requiresAuthorizationList,
        .rejectsNonDelegatingSenderCode = F.rejectsNonDelegatingSenderCode,
        .maxInitcodeSize = F.maxInitcodeSize,
        .intrinsicBaseGas = F.intrinsicBaseGas,
        .createIntrinsicGas = F.createIntrinsicGas,
        .calldataGas = F.calldataGas,
        .accessListAddressGas = F.accessListAddressGas,
        .storageKeyGas = F.storageKeyGas,
        .accessListDataGas = F.accessListDataGas,
        .initCodeWordGas = F.initCodeWordGas,
        .authorizationIntrinsicGas = F.authorizationIntrinsicGas,
        .floorGas = F.floorGas,
        .regularGasLimit = F.regularGasLimit,
        .intrinsicRegularGasLimit = F.intrinsicRegularGasLimit,
        .totalGasLimit = F.totalGasLimit,
    };
}

fn testSettlementConfig(comptime R: type) definition.SettlementConfig(R) {
    const F = struct {
        fn gasRefundCapDivisor(_: R) u64 {
            return 2;
        }
    };
    return .{ .gasRefundCapDivisor = F.gasRefundCapDivisor };
}

fn testCallConfig(comptime R: type) definition.CallConfig(R) {
    const F = struct {
        fn callBaseGas(_: R) i64 {
            return 0;
        }

        fn callValueTransferGas(_: R) i64 {
            return 0;
        }

        fn callValueStipend(_: R) i64 {
            return 0;
        }

        fn callNewAccountGas(_: R, _: types.CallNewAccountInput) types.CallNewAccountGas {
            return .{};
        }

        fn delegatedAccountAccessGas(_: R, _: bool) i64 {
            return 0;
        }

        fn touchesEmptyCallRecipient(_: R) bool {
            return false;
        }

        fn childGas(_: R, input: types.ChildGasInput) types.ChildGas {
            return .{ .gas = @min(input.requested, input.available) };
        }
    };
    return .{
        .callBaseGas = F.callBaseGas,
        .callValueTransferGas = F.callValueTransferGas,
        .callValueStipend = F.callValueStipend,
        .callNewAccountGas = F.callNewAccountGas,
        .delegatedAccountAccessGas = F.delegatedAccountAccessGas,
        .touchesEmptyCallRecipient = F.touchesEmptyCallRecipient,
        .childGas = F.childGas,
    };
}

fn testCreateConfig(comptime R: type, comptime create_code_size_limit: ?*const fn (R) ?usize) definition.CreateConfig(R) {
    const F = struct {
        fn createDepositRegularGas(_: R, _: i64) ?i64 {
            return 0;
        }

        fn createInitialNonce(_: R) u64 {
            return 0;
        }

        fn createInitCodeWordGas(_: R, _: bool) i64 {
            return 0;
        }
    };
    return .{
        .createCodeSizeLimit = create_code_size_limit orelse definition.CreateConfig(R).default.createCodeSizeLimit,
        .createDepositRegularGas = F.createDepositRegularGas,
        .createInitialNonce = F.createInitialNonce,
        .createInitCodeWordGas = F.createInitCodeWordGas,
    };
}

fn testStorageConfig(comptime R: type) definition.StorageConfig(R) {
    const F = struct {
        fn sstoreGas(_: R, _: types.StorageStatus) types.StorageGas {
            return .{};
        }
    };
    return .{ .sstoreGas = F.sstoreGas };
}

fn testSelfDestructConfig(comptime R: type) definition.SelfDestructConfig(R) {
    const F = struct {
        fn selfDestructPolicy(_: R, _: types.SelfDestructPolicyInput) types.SelfDestructPolicy {
            return .{
                .clear_balance = false,
                .reset_nonce = false,
                .mark_selfdestructed = false,
            };
        }

        fn selfDestructFinalization(_: R, _: bool) types.SelfDestructFinalization {
            return .{};
        }

        fn selfDestructNewAccountGas(_: R, _: types.SelfDestructNewAccountInput) types.CallNewAccountGas {
            return .{};
        }

        fn selfDestructRefundGas(_: R) i64 {
            return 0;
        }
    };
    return .{
        .selfDestructPolicy = F.selfDestructPolicy,
        .selfDestructFinalization = F.selfDestructFinalization,
        .selfDestructNewAccountGas = F.selfDestructNewAccountGas,
        .selfDestructRefundGas = F.selfDestructRefundGas,
    };
}

fn TestPrecompile(comptime R: type) type {
    return struct {
        pub const Entry = void;

        pub fn resolve(_: R, _: address.Address) ?Entry {
            return null;
        }

        pub fn execute(
            _: R,
            _: Entry,
            _: precompile_runtime.PrecompileCall,
        ) precompile_mod.Error!precompile_runtime.PrecompileOutcome {
            unreachable;
        }
    };
}

test "protocol type exposes dispatch facts" {
    const eth = @import("../eth.zig");
    const resolved = eth_config.canonical;
    const Ethereum = definition.ExecutionModel(resolved.execution);
    const CancunPlus = compileExecution(
        resolved.execution,
        Ethereum.Support.since(.cancun),
    );
    const blobbasefee = comptime instructionFor(CancunPlus, .BLOBBASEFEE);
    const slotnum = comptime instructionFor(CancunPlus, .SLOTNUM);
    const balance = comptime instructionFor(CancunPlus, .BALANCE);
    const add = comptime instructionFor(CancunPlus, .ADD);
    const add_entry = comptime CancunPlus.Instruction.entry(add);

    try std.testing.expectEqual(eth.Revision.cancun, CancunPlus.support.min);
    try std.testing.expectEqual(Ethereum.Support.all.max, CancunPlus.support.max);
    try std.testing.expectEqual(Resolution.always, CancunPlus.Instruction.availability(blobbasefee));
    try std.testing.expectEqual(Resolution.runtime, CancunPlus.Instruction.availability(slotnum));
    try std.testing.expectEqual(@as(?i64, 100), CancunPlus.Instruction.staticGasConstant(balance));
    try std.testing.expectEqual(ExecutionTarget{ .builtin = .ADD }, add_entry.execution_target);
    try std.testing.expectEqual(u8, CancunPlus.Instruction.Value);
    try std.testing.expectEqual(Resolution.always, CancunPlus.Instruction.availability(add));
    try std.testing.expectEqual(@as(?i64, 3), CancunPlus.Instruction.staticGasConstant(add));
}

test "transaction resolver defaults engine protocol shape" {
    const eth = @import("../eth.zig");
    const resolved = eth_config.canonical;
    const Ethereum = definition.ExecutionModel(resolved.execution);
    assertExecutionContract(resolved.execution);

    const Cancun = compileTransaction(
        compileExecution(resolved.execution, Ethereum.Support.at(.cancun)),
        resolved.transaction,
    );
    try std.testing.expectEqual(eth.Revision.cancun, Cancun.support.min);
    try std.testing.expectEqual(eth.Revision.cancun, Cancun.support.max);
    try std.testing.expectEqual(tx.Transaction, Cancun.Tx.Value);
    try std.testing.expectEqual(tx.TransactionView, Cancun.Tx.View);
    try std.testing.expectEqual(eth.transaction_validation.ValidationError, Cancun.Tx.ValidationError);

    const sender = address.addr(0xaaaa);
    const view = Cancun.Tx.view(.{
        .sender = sender,
        .gas_limit = 21_000,
    });
    try std.testing.expectEqualSlices(u8, &sender, &view.sender);
    try std.testing.expectEqual(@as(u64, 21_000), view.gas_limit);
}

test "protocol contract accepts non-Ethereum revision model" {
    const FakeRevision = enum(u8) {
        alpha = 10,
        beta = 2,
    };
    const FakeSemantics = struct {
        pub const BaseRevision = @import("../eth/revision.zig").Revision;

        pub fn baseRevision(revision_value: FakeRevision) BaseRevision {
            return switch (revision_value) {
                .alpha => .london,
                .beta => .cancun,
            };
        }
    };
    const FakeGates = struct {
        fn blobOpcodes(revision_value: FakeRevision) bool {
            return revision_value == .beta;
        }
    };
    const FakeOrder = struct {
        fn order(a: FakeRevision, b: FakeRevision) std.math.Order {
            const a_index: u8 = switch (a) {
                .alpha => 0,
                .beta => 1,
            };
            const b_index: u8 = switch (b) {
                .alpha => 0,
                .beta => 1,
            };
            return std.math.order(a_index, b_index);
        }
    };
    const fake_revision_config: definition.RevisionConfig(FakeRevision) = .{
        .revisions = &.{ .alpha, .beta },
        .latest = .beta,
        .stable = .alpha,
        .order = FakeOrder.order,
        .semantics = FakeSemantics,
    };

    const fake_revision = definition.RevisionModel(FakeRevision, fake_revision_config);
    const FakeInstruction = struct {
        pub const Value = u8;

        pub fn fromByte(comptime opcode_byte: u8) Value {
            return opcode_byte;
        }

        pub fn context(comptime value: Value) InstructionContext {
            return .{ .byte = value };
        }

        pub fn info(comptime value: Value) opcode_info.OpInfo {
            return opcode_info.info(value);
        }

        pub fn availability(comptime value: Value) fake_revision.Availability {
            if (value == @intFromEnum(opcode_info.Opcode.LOG1)) return .{ .gate = FakeGates.blobOpcodes };
            return if (info(value).defined) .always else .never;
        }

        pub fn tier(comptime value: Value) OpcodeTier {
            return if (value == @intFromEnum(opcode_info.Opcode.ADD)) .hot else .cold;
        }

        pub fn executionTarget(comptime value: Value) ExecutionTarget {
            const info_value = info(value);
            if (!info_value.defined) return .invalid;
            const opcode: opcode_info.Opcode = @enumFromInt(value);
            return switch (opcode) {
                .INVALID => .invalid,
                else => .{ .builtin = opcode },
            };
        }

        pub fn staticGasForRevisionByte(revision_value: FakeRevision, comptime opcode_byte: u8) i64 {
            if (opcode_byte == @intFromEnum(opcode_info.Opcode.ADD) and revision_value == .beta) return 4;
            return @intCast(info(fromByte(opcode_byte)).static_gas);
        }
    };
    const FakeCreate = struct {
        fn createCodeSizeLimit(revision_value: FakeRevision) ?usize {
            return if (revision_value == .beta) 42 else null;
        }
    };
    const FakeRules = comptime blk: {
        var value = testExecutionRules(FakeRevision, FakeInstruction, FakeCreate.createCodeSizeLimit);
        value.revision = fake_revision_config;
        break :blk value;
    };
    const FakeExecution = definition.ExecutionModel(FakeRules);

    assertDispatchContract(FakeRules);

    const FakeProtocol = protocolFor(FakeRules, FakeExecution.Support.all);
    const fake_add = comptime instructionFor(FakeProtocol, .ADD);
    const fake_log1 = comptime instructionFor(FakeProtocol, .LOG1);
    try std.testing.expectEqual(Resolution.always, FakeProtocol.Instruction.availability(fake_add));
    try std.testing.expectEqual(Resolution.runtime, FakeProtocol.Instruction.availability(fake_log1));
    try std.testing.expectEqual(@as(?i64, null), FakeProtocol.Instruction.staticGasConstant(fake_add));
    try std.testing.expectEqual(OpcodeTier.hot, FakeProtocol.Instruction.tier(fake_add));
    try std.testing.expect(!FakeProtocol.Instruction.entry(fake_add).hot_path);
    try std.testing.expectEqual(@as(?usize, 42), FakeProtocol.create.createCodeSizeLimit(.beta));
    try std.testing.expectEqual(FakeRevision.beta, FakeExecution.latest);
    try std.testing.expectEqual(FakeRevision.alpha, FakeExecution.stable);
    try std.testing.expect(FakeExecution.Support.all.contains(.beta));
    try std.testing.expectEqual(std.math.Order.lt, FakeProtocol.order(.alpha, .beta));
    try std.testing.expectEqual(FakeSemantics.BaseRevision.cancun, FakeProtocol.baseRevision(.beta));

    const FakeTx = compileTransaction(FakeProtocol, testTransactionLayerRules(FakeRevision));
    try std.testing.expectEqual(
        @import("../eth/transaction_validation.zig").ValidationError,
        FakeTx.Tx.ValidationError,
    );
    try std.testing.expectEqual(FakeProtocol.support, FakeTx.support);

    const AlphaProtocol = protocolFor(FakeRules, FakeExecution.Support.at(.alpha));
    const alpha_add = comptime instructionFor(AlphaProtocol, .ADD);
    const alpha_log1 = comptime instructionFor(AlphaProtocol, .LOG1);
    try std.testing.expectEqual(@as(?i64, 3), AlphaProtocol.Instruction.staticGasConstant(alpha_add));
    try std.testing.expect(AlphaProtocol.Instruction.entry(alpha_add).hot_path);
    try std.testing.expectEqual(Resolution.never, AlphaProtocol.Instruction.availability(alpha_log1));
    try std.testing.expectEqual(@as(?usize, null), AlphaProtocol.create.createCodeSizeLimit(.alpha));

    const BetaProtocol = protocolFor(FakeRules, FakeExecution.Support.at(.beta));
    const beta_log1 = comptime instructionFor(BetaProtocol, .LOG1);
    try std.testing.expectEqual(Resolution.always, BetaProtocol.Instruction.availability(beta_log1));
}

test "rule-owned instruction type can compose custom opcode identity" {
    const CustomRevision = enum(u8) {
        alpha,
    };

    const custom_revision = RevisionModel(CustomRevision);
    const custom_opcode_byte = 0xc0;
    const custom_subopcode_byte = 0x01;
    const CustomHandler = struct {
        pub fn execute() void {}
    };
    const CustomInstruction = struct {
        pub const Value = union(enum) {
            byte: u8,
            prefix,
            evm64: u8,
        };

        pub fn fromByte(comptime opcode_byte: u8) Value {
            if (opcode_byte == custom_opcode_byte) return .prefix;
            return .{ .byte = opcode_byte };
        }

        pub fn context(comptime value: Value) InstructionContext {
            return switch (value) {
                .byte => |opcode_byte| .{ .byte = opcode_byte },
                .prefix, .evm64 => .{ .custom = .{ .first_byte = custom_opcode_byte } },
            };
        }

        pub fn info(comptime value: Value) opcode_info.OpInfo {
            return switch (value) {
                .byte => |opcode_byte| opcode_info.info(opcode_byte),
                .prefix => .{
                    .name = "EVM64_PREFIX",
                    .defined = true,
                    .exit = .invalid,
                },
                .evm64 => |subopcode| if (subopcode == custom_subopcode_byte)
                    .{
                        .name = "C001_ADD64",
                        .defined = true,
                        .static_gas = 3,
                        .stack_in = 2,
                        .stack_out = 1,
                    }
                else
                    .{ .exit = .invalid },
            };
        }

        pub fn availability(comptime value: Value) custom_revision.Availability {
            return if (info(value).defined) .always else .never;
        }

        pub fn tier(_: Value) OpcodeTier {
            return .cold;
        }

        pub fn executionTarget(comptime value: Value) ExecutionTarget {
            return switch (value) {
                .byte => |opcode_byte| blk: {
                    const info_value = info(value);
                    if (!info_value.defined) break :blk .invalid;
                    const opcode: opcode_info.Opcode = @enumFromInt(opcode_byte);
                    break :blk switch (opcode) {
                        .INVALID => .invalid,
                        else => .{ .builtin = opcode },
                    };
                },
                .prefix => .{ .custom = CustomHandler },
                .evm64 => .invalid,
            };
        }

        pub fn staticGasForRevisionByte(_: CustomRevision, comptime opcode_byte: u8) i64 {
            return @intCast(info(fromByte(opcode_byte)).static_gas);
        }

        pub fn staticGasByte(comptime opcode_byte: u8, comptime _: anytype) StaticGas {
            if (opcode_byte == @intFromEnum(opcode_info.Opcode.ADD)) {
                return .{ .constant = 7 };
            }
            return .{ .constant = @intCast(info(fromByte(opcode_byte)).static_gas) };
        }

        pub fn staticGasForRevisionInstruction(_: CustomRevision, comptime value: Value) i64 {
            return @intCast(info(value).static_gas);
        }
    };
    const CustomRules = testExecutionRules(CustomRevision, CustomInstruction, null);
    const CustomExecution = definition.ExecutionModel(CustomRules);

    assertDispatchContract(CustomRules);

    const CustomProtocol = protocolFor(CustomRules, CustomExecution.Support.all);
    const entry = CustomProtocol.Instruction.entry(CustomProtocol.Instruction.fromByte(custom_opcode_byte));
    try std.testing.expectEqual(@as(u8, custom_opcode_byte), entry.opcode_byte);
    try std.testing.expect(entry.defined());
    try std.testing.expectEqualStrings("EVM64_PREFIX", entry.info.name.?);
    try std.testing.expectEqual(@as(?i64, 0), entry.staticGasConstant());
    switch (entry.execution_target) {
        .custom => |Handler| try std.testing.expect(Handler == CustomHandler),
        else => return error.ExpectedCustomTarget,
    }

    const inherited_instruction = comptime CustomProtocol.Instruction.fromByte(@intFromEnum(opcode_info.Opcode.ADD));
    const inherited_entry = CustomProtocol.Instruction.entry(inherited_instruction);
    try std.testing.expectEqual(@as(u8, @intFromEnum(opcode_info.Opcode.ADD)), inherited_entry.opcode_byte);
    try std.testing.expectEqual(ExecutionTarget{ .builtin = .ADD }, inherited_entry.execution_target);
    try std.testing.expectEqual(@as(?i64, 7), CustomProtocol.Instruction.staticGasConstant(inherited_instruction));

    const subinstruction = CustomExecution.Instruction.Value{ .evm64 = custom_subopcode_byte };
    const subentry = CustomProtocol.Instruction.entry(subinstruction);
    try std.testing.expectEqual(@as(u8, custom_opcode_byte), subentry.opcode_byte);
    try std.testing.expectEqualStrings("C001_ADD64", subentry.info.name.?);
    try std.testing.expectEqual(Resolution.always, subentry.availability);
    try std.testing.expectEqual(@as(?i64, 3), subentry.staticGasConstant());
    try std.testing.expectEqual(ExecutionTarget.invalid, subentry.execution_target);
}

test "canonical Ethereum execution satisfies full runtime contract" {
    assertExecutionContract(eth_config.canonical.execution);
}
