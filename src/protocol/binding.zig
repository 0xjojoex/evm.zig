const std = @import("std");

const interface = @import("interface.zig");
const dispatcher = @import("dispatcher.zig");
const instruction_mod = @import("instruction.zig");
const transaction_mod = @import("transaction.zig");
const definition_mod = @import("../definition.zig");
const address = @import("../address.zig");
const opcode_info = @import("../opcode.zig");
const precompile_mod = @import("../precompile.zig");
const support_mod = @import("support.zig");
const Resolution = support_mod.Resolution;

pub fn Protocol(comptime definition_value: anytype, comptime support_window: definition_mod.Bound(definition_value).Support) type {
    return ProtocolWithDispatch(definition_value, support_window, .{});
}

pub fn ProtocolWithDispatch(
    comptime definition_value: anytype,
    comptime support_window: definition_mod.Bound(definition_value).Support,
    comptime dispatch_config: dispatcher.DispatchConfig,
) type {
    const DefinitionType = definition_mod.Bound(definition_value);
    interface.assertValidProtocolDefinition(DefinitionType);
    support_window.assertValid();
    const hot_cold_dispatch = dispatcher.useHotColdDispatch(dispatch_config);
    const InstructionFacts = instruction_mod.For(DefinitionType, support_window);
    const AuthorizationFacts = DefinitionType.Authorization;
    const BlockFacts = DefinitionType.Block;
    const CallFacts = DefinitionType.Call;
    const CreateFacts = DefinitionType.Create;
    const SettlementFacts = DefinitionType.Settlement;
    const SelfDestructFacts = DefinitionType.SelfDestruct;
    const StorageFacts = DefinitionType.Storage;
    const TransactionFacts = transaction_mod.For(DefinitionType);

    return struct {
        const Self = @This();

        pub const Revision = DefinitionType.Revision;
        pub const revisions = DefinitionType.revisions;
        pub const Support = DefinitionType.Support;
        pub const Availability = DefinitionType.Availability;
        pub const InstructionContext = instruction_mod.Context;
        pub const opcodeInfoByte = DefinitionType.opcodeInfoByte;
        pub const opcodeInfo = DefinitionType.opcodeInfo;
        pub const opcodeAvailabilityByte = DefinitionType.opcodeAvailabilityByte;
        pub const opcodeAvailability = DefinitionType.opcodeAvailability;
        pub const resolveAvailability = DefinitionType.resolveAvailability;
        pub const staticGasForRevisionByte = DefinitionType.staticGasForRevisionByte;
        pub const staticGasForRevision = DefinitionType.staticGasForRevision;

        pub const support = support_window;
        pub const dispatch = dispatch_config;
        pub const hot_cold_dispatch_enabled = hot_cold_dispatch;

        pub const Block = BlockFacts;
        pub const Create = CreateFacts;
        pub const Settlement = SettlementFacts;
        pub const Storage = StorageFacts;
        pub const Transaction = TransactionFacts;
        pub const Authorization = AuthorizationFacts;
        pub const Precompile = struct {
            pub fn active(revision: DefinitionType.Revision, target: address.Address) bool {
                if (comptime std.meta.hasFn(DefinitionType.Precompile, "active")) {
                    return DefinitionType.Precompile.active(revision, target);
                }
                return DefinitionType.Precompile.resolve(revision, target) != null;
            }

            pub fn execute(
                allocator: std.mem.Allocator,
                revision: DefinitionType.Revision,
                target: address.Address,
                input_data: []const u8,
                gas: i64,
            ) precompile_mod.Error!?precompile_mod.Result {
                const entry = DefinitionType.Precompile.resolve(revision, target) orelse return null;
                return try DefinitionType.Precompile.execute(allocator, revision, entry, input_data, gas);
            }

            pub fn executeWithOutputBuffer(
                allocator: std.mem.Allocator,
                revision: DefinitionType.Revision,
                target: address.Address,
                input_data: []const u8,
                gas: i64,
                output_buffer: ?[]u8,
            ) precompile_mod.Error!?precompile_mod.Result {
                const entry = DefinitionType.Precompile.resolve(revision, target) orelse return null;
                if (comptime std.meta.hasFn(DefinitionType.Precompile, "executeWithOutputBuffer")) {
                    return try DefinitionType.Precompile.executeWithOutputBuffer(allocator, revision, entry, input_data, gas, output_buffer);
                }
                return try DefinitionType.Precompile.execute(allocator, revision, entry, input_data, gas);
            }
        };
        pub const Call = CallFacts;
        pub const SelfDestruct = SelfDestructFacts;

        const byte = struct {
            pub fn entry(comptime opcode_byte: u8) dispatcher.DispatchEntry {
                return dispatcher.resolveDispatchEntryByte(DefinitionType, support_window, opcode_byte);
            }

            pub fn info(comptime opcode_byte: u8) opcode_info.OpInfo {
                return InstructionFacts.info(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn availability(comptime opcode_byte: u8) Resolution {
                return InstructionFacts.availability(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn tier(comptime opcode_byte: u8) dispatcher.OpcodeTier {
                return InstructionFacts.tier(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn executionTarget(comptime opcode_byte: u8) dispatcher.ExecutionTarget {
                return InstructionFacts.executionTarget(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn hotPath(comptime opcode_byte: u8) bool {
                @setEvalBranchQuota(10_000);
                return entry(opcode_byte).hot_path;
            }

            pub fn staticGas(comptime opcode_byte: u8) dispatcher.StaticGas {
                return dispatcher.resolveStaticGasByte(DefinitionType, support_window, opcode_byte);
            }

            pub fn staticGasConstant(comptime opcode_byte: u8) ?i64 {
                return switch (@This().staticGas(opcode_byte)) {
                    .constant => |gas| gas,
                    .revision_bands => null,
                };
            }
        };

        pub const Instruction = struct {
            pub const Value = InstructionFacts.Value;
            pub const Context = InstructionFacts.Context;

            pub fn fromByte(comptime opcode_byte: u8) Value {
                return InstructionFacts.fromByte(opcode_byte);
            }

            pub fn context(comptime value: Value) Context {
                return InstructionFacts.context(value);
            }

            pub fn entry(comptime value: Value) dispatcher.DispatchEntry {
                @setEvalBranchQuota(10_000);
                return switch (comptime @This().context(value)) {
                    .byte => |opcode_byte| byte.entry(opcode_byte),
                    .custom => dispatcher.resolveDispatchEntryInstruction(DefinitionType, support_window, value),
                };
            }

            pub fn info(comptime value: Value) opcode_info.OpInfo {
                return InstructionFacts.info(value);
            }

            pub fn rawAvailability(comptime value: Value) DefinitionType.Availability {
                return InstructionFacts.rawAvailability(value);
            }

            pub fn availability(comptime value: Value) Resolution {
                return InstructionFacts.availability(value);
            }

            pub fn staticGasForRevision(revision: DefinitionType.Revision, comptime value: Value) i64 {
                return switch (comptime context(value)) {
                    .byte => |opcode_byte| DefinitionType.staticGasForRevisionByte(revision, opcode_byte),
                    .custom => dispatcher.resolveStaticGasForRevisionInstruction(DefinitionType, revision, value),
                };
            }

            pub fn tier(comptime value: Value) dispatcher.OpcodeTier {
                return InstructionFacts.tier(value);
            }

            pub fn executionTarget(comptime value: Value) dispatcher.ExecutionTarget {
                return InstructionFacts.executionTarget(value);
            }

            pub fn staticGas(comptime value: Value) dispatcher.StaticGas {
                return switch (comptime context(value)) {
                    .byte => |opcode_byte| byte.staticGas(opcode_byte),
                    .custom => dispatcher.resolveStaticGasInstruction(DefinitionType, support_window, value),
                };
            }

            pub fn staticGasConstant(comptime value: Value) ?i64 {
                return switch (@This().staticGas(value)) {
                    .constant => |gas| gas,
                    .revision_bands => null,
                };
            }

            pub fn expByteGas(revision: DefinitionType.Revision) i64 {
                return InstructionFacts.expByteGas(revision);
            }

            pub fn accountReadColdAccessGas(revision: DefinitionType.Revision) ?i64 {
                return InstructionFacts.accountReadColdAccessGas(revision);
            }

            pub fn codeAccountAccessGas(revision: DefinitionType.Revision, status: interface.AccountAccessStatus) ?i64 {
                return InstructionFacts.codeAccountAccessGas(revision, status);
            }
        };

        pub fn dispatchTable() dispatcher.DispatchTable {
            return dispatcher.resolveDispatchTable(DefinitionType, support_window);
        }
    };
}

fn instructionFor(comptime ProtocolType: type, comptime opcode: opcode_info.Opcode) ProtocolType.Instruction.Value {
    return ProtocolType.Instruction.fromByte(@intFromEnum(opcode));
}

test "protocol type exposes resolved Ethereum facts" {
    const ethereum = @import("../eth.zig");
    const CancunPlus = Protocol(ethereum.definition, ethereum.Support.since(.cancun));
    const blobbasefee = comptime instructionFor(CancunPlus, .BLOBBASEFEE);
    const slotnum = comptime instructionFor(CancunPlus, .SLOTNUM);
    const balance = comptime instructionFor(CancunPlus, .BALANCE);
    const add = comptime instructionFor(CancunPlus, .ADD);
    const push1 = comptime instructionFor(CancunPlus, .PUSH1);
    const push0 = comptime instructionFor(CancunPlus, .PUSH0);
    const sload = comptime instructionFor(CancunPlus, .SLOAD);

    try std.testing.expectEqual(Resolution.always, CancunPlus.Instruction.availability(blobbasefee));
    try std.testing.expectEqual(Resolution.runtime, CancunPlus.Instruction.availability(slotnum));
    try std.testing.expectEqual(@as(?i64, 100), CancunPlus.Instruction.staticGasConstant(balance));
    try std.testing.expect(CancunPlus.hot_cold_dispatch_enabled);
    try std.testing.expect(CancunPlus.Instruction.entry(add).hot_path);
    try std.testing.expect(CancunPlus.Instruction.entry(push1).hot_path);
    try std.testing.expect(CancunPlus.Instruction.entry(push0).hot_path);
    try std.testing.expect(!CancunPlus.Instruction.entry(slotnum).hot_path);
    try std.testing.expect(!CancunPlus.Instruction.entry(sload).hot_path);
    try std.testing.expectEqual(@as(?usize, ethereum.system.Create.max_code_size), CancunPlus.Create.createCodeSizeLimit(.cancun));
    try std.testing.expectEqual(@as(i64, 50), CancunPlus.Instruction.expByteGas(.cancun));
    try std.testing.expectEqual(@as(?precompile_mod.Contract, .ecrecover), ethereum.Precompile.resolve(.cancun, address.addr(0x01)));
    try std.testing.expect(CancunPlus.Precompile.active(.cancun, address.addr(0x01)));

    const Amsterdam = Protocol(ethereum.definition, ethereum.Support.at(.amsterdam));
    try std.testing.expect(Amsterdam.hot_cold_dispatch_enabled);
    try std.testing.expectEqual(@as(?usize, ethereum.system.Create.amsterdam_max_code_size), Amsterdam.Create.createCodeSizeLimit(.amsterdam));

    const AmsterdamWithoutHotCold = ProtocolWithDispatch(ethereum.definition, ethereum.Support.at(.amsterdam), .{ .hot_cold = .disabled });
    try std.testing.expect(!AmsterdamWithoutHotCold.hot_cold_dispatch_enabled);

    const Frontier = Protocol(ethereum.definition, ethereum.Support.at(.frontier));
    try std.testing.expectEqual(@as(?usize, null), Frontier.Create.createCodeSizeLimit(.frontier));
}
