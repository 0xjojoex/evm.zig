//! Fork-neutral opcode implementations and their shared gas constants.

const opcode_info = @import("opcode.zig");
const Opcode = opcode_info.Opcode;
const std = @import("std");
const dispatcher = @import("./protocol/dispatcher.zig");
const support = @import("./protocol/support.zig");
const protocol_types = @import("./protocol/types.zig");
const evmz = @import("./evm.zig");
const Interpreter = @import("./Interpreter.zig");
const CallFrame = Interpreter.CallFrame;

pub const call_value_cost = 9000;
pub const account_creation_cost = 25000;

// [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929)
pub const cold_sload_cost = 2100;
pub const cold_account_access_cost = 2600;
pub const warm_storage_read_cost = 100;

// warm_storage_read_cost is count before instruction execution
pub const cold_account_access_gas = cold_account_access_cost - warm_storage_read_cost;
pub const cold_sload_gas = cold_sload_cost - warm_storage_read_cost;

pub const Error = error{
    UnknownOpcode,
};

pub const arithmetic = @import("./instruction/arithmetic.zig");
pub const environment = @import("./instruction/environment.zig");
pub const flow = @import("./instruction/flow.zig");
pub const logging = @import("./instruction/logging.zig");
pub const stack = @import("./instruction/stack.zig");
pub const storage = @import("./instruction/storage.zig");
pub const system = @import("./instruction/system.zig");
pub const memory = @import("./instruction/memory.zig");
pub const logic = @import("./instruction/logic.zig");

test {
    _ = @import("./instruction/tail_dispatch_test.zig");
}

pub const Instruction = struct {
    opcode: Opcode,
    static_gas: u16,
};

pub fn decode(opcode_byte: u8) ?Instruction {
    const opcode: Opcode = @enumFromInt(opcode_byte);
    const row = opcode_info.info(opcode.toByte());
    if (!row.defined) return null;
    return .{ .opcode = opcode, .static_gas = row.static_gas };
}

test decode {
    try std.testing.expectEqual(@as(u16, 0), decode(0x00).?.static_gas);
    try std.testing.expectEqual(@as(u16, 3), decode(0x60).?.static_gas);
    try std.testing.expectEqual(null, decode(0x0c));
}

test "decode follows opcode table for every byte" {
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const row = opcode_info.info(opcode_byte);
        const decoded = decode(opcode_byte);
        if (!row.defined) {
            try std.testing.expectEqual(null, decoded);
            continue;
        }

        try std.testing.expect(decoded != null);
        try std.testing.expectEqual(opcode_byte, @intFromEnum(decoded.?.opcode));
        try std.testing.expectEqual(row.static_gas, decoded.?.static_gas);
    }
}

test "fork-gated opcodes are invalid before their activation fork" {
    try evmz.t.expectBytecodeStatusByRevision(.{.RETURNDATASIZE}, .homestead, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.RETURNDATASIZE}, .byzantium, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.BASEFEE}, .berlin, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.BASEFEE}, .london, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.PUSH0}, .london, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.PUSH0}, .shanghai, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.BLOBBASEFEE}, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.BLOBBASEFEE}, .cancun, .success);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .BLOBHASH }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .BLOBHASH }, .cancun, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.SLOTNUM}, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.SLOTNUM}, .amsterdam, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .amsterdam, .success);
}

test "fork-dependent static gas follows legacy schedules" {
    const EthInstructions = For(evmz.Evm.ExecutionProtocol);
    try std.testing.expectEqual(@as(i64, 20), EthInstructions.staticGasForRevision(.frontier, .BALANCE));
    try std.testing.expectEqual(@as(i64, 400), EthInstructions.staticGasForRevision(.byzantium, .BALANCE));
    try std.testing.expectEqual(@as(i64, 700), EthInstructions.staticGasForRevision(.istanbul, .BALANCE));
    try std.testing.expectEqual(@as(i64, 100), EthInstructions.staticGasForRevision(.berlin, .BALANCE));

    try std.testing.expectEqual(@as(i64, 20), EthInstructions.staticGasForRevision(.homestead, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 700), EthInstructions.staticGasForRevision(.byzantium, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 400), EthInstructions.staticGasForRevision(.petersburg, .EXTCODEHASH));
    try std.testing.expectEqual(@as(i64, 700), EthInstructions.staticGasForRevision(.istanbul, .EXTCODEHASH));

    try std.testing.expectEqual(@as(i64, 50), EthInstructions.staticGasForRevision(.frontier, .SLOAD));
    try std.testing.expectEqual(@as(i64, 200), EthInstructions.staticGasForRevision(.byzantium, .SLOAD));
    try std.testing.expectEqual(@as(i64, 800), EthInstructions.staticGasForRevision(.istanbul, .SLOAD));

    try std.testing.expectEqual(@as(i64, 0), EthInstructions.staticGasForRevision(.homestead, .SELFDESTRUCT));
    try std.testing.expectEqual(@as(i64, 5000), EthInstructions.staticGasForRevision(.tangerine_whistle, .SELFDESTRUCT));
}

test "execute charges dynamic and fixed static gas" {
    const Mainnet = evmz.Evm.ExecutionProtocol;
    const IstanbulProtocol = evmz.eth.fork(.istanbul).ExecutionProtocol;

    try std.testing.expectEqual(@as(i64, 99_980), try executeBalance(Mainnet, .frontier));
    try std.testing.expectEqual(@as(i64, 99_300), try executeBalance(Mainnet, .istanbul));
    try std.testing.expectEqual(@as(i64, 99_300), try executeBalance(IstanbulProtocol, .istanbul));
}

test "execute uses definition availability from support window" {
    const FrontierProtocol = evmz.eth.fork(.frontier).ExecutionProtocol;
    try expectOpcodeStatus(FrontierProtocol, .frontier, .BASEFEE, .invalid);
}

test "execute uses resolved dispatch target for hot opcodes" {
    const OverrideProtocol = DispatchOverrideProtocol(.invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter.OwnedCallFrame(OverrideProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
    });
    defer frame.deinit();

    try frame.frame.stack.push(2);
    try frame.frame.stack.push(3);
    try For(OverrideProtocol).execute(@intFromEnum(Opcode.ADD), frame.frame);
    try std.testing.expectEqual(Interpreter.FrameStatus.invalid, frame.frame.status);
}

test "untraced interpreter raw fallback respects resolved dispatch target" {
    const OverrideProtocol = DispatchOverrideProtocol(.invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        2,
        @intFromEnum(Opcode.PUSH1),
        3,
        @intFromEnum(Opcode.ADD),
    };

    var frame = try Interpreter.OwnedCallFrame(OverrideProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
}

test "untraced interpreter tail dispatch respects resolved dispatch target" {
    const OverrideProtocol = DispatchOverrideProtocol(.invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        2,
        @intFromEnum(Opcode.PUSH1),
        3,
        @intFromEnum(Opcode.ADD),
    };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter.OwnedCallFrame(OverrideProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
}

test "execute calls custom dispatch target directly" {
    const CustomHandler = struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .ADD)) return;
            return frame.stack.push(42);
        }
    };
    const OverrideProtocol = DispatchOverrideProtocol(.{ .custom = CustomHandler });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter.OwnedCallFrame(OverrideProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
    });
    defer frame.deinit();

    try For(OverrideProtocol).execute(@intFromEnum(Opcode.ADD), frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(u256, 42), frame.frame.stack.pop());
    try std.testing.expectEqual(msg.gas - staticGas(.ADD), frame.frame.gas_left);
}

fn DispatchOverrideProtocol(comptime add_target: dispatcher.ExecutionTarget) type {
    const target_for_add = add_target;
    return struct {
        pub const Revision = evmz.eth.Revision;
        pub const hot_cold_dispatch_enabled = true;
        pub const Instruction = evmz.Evm.ExecutionProtocol.Instruction;
        pub const storage = evmz.Evm.ExecutionProtocol.storage;
        pub const call = evmz.Evm.ExecutionProtocol.call;
        pub const create = evmz.Evm.ExecutionProtocol.create;
        pub const self_destruct = evmz.Evm.ExecutionProtocol.self_destruct;

        pub fn staticGas(comptime opcode: Opcode) support.StaticGas {
            return .{ .constant = @intCast(opcode_info.info(@intFromEnum(opcode)).static_gas) };
        }

        pub fn dispatchEntry(comptime opcode: Opcode) dispatcher.DispatchEntry {
            return dispatchEntryByte(@intFromEnum(opcode));
        }

        pub fn dispatchEntryByte(comptime opcode_byte: u8) dispatcher.DispatchEntry {
            const info = opcode_info.info(opcode_byte);
            const target: dispatcher.ExecutionTarget = if (comptime opcode_byte == @intFromEnum(Opcode.ADD))
                target_for_add
            else if (comptime info.defined)
                .{ .builtin = @enumFromInt(opcode_byte) }
            else
                .invalid;
            return .{
                .opcode_byte = opcode_byte,
                .opcode = @enumFromInt(opcode_byte),
                .info = info,
                .availability = if (comptime info.defined) .always else .never,
                .static_gas = .{ .constant = @intCast(info.static_gas) },
                .tier = if (comptime opcode_byte == @intFromEnum(Opcode.ADD)) .hot else .cold,
                .execution_target = target,
                .hot_path = opcode_byte == @intFromEnum(Opcode.ADD),
            };
        }

        pub fn dispatchTable() dispatcher.DispatchTable {
            @setEvalBranchQuota(10_000);
            var table: dispatcher.DispatchTable = undefined;
            inline for (0..256) |index| {
                table[index] = dispatchEntryByte(@intCast(index));
            }
            return table;
        }
    };
}

fn testDispatchTable(comptime TestProtocol: type) dispatcher.DispatchTable {
    @setEvalBranchQuota(10_000);
    var table: dispatcher.DispatchTable = undefined;
    inline for (0..256) |index| {
        table[index] = testDispatchEntryByte(TestProtocol, @intCast(index));
    }
    return table;
}

fn testDispatchEntryByte(comptime TestProtocol: type, comptime opcode_byte: u8) dispatcher.DispatchEntry {
    const info = opcode_info.info(opcode_byte);
    const opcode: Opcode = @enumFromInt(opcode_byte);
    const availability: support.Resolution = if (comptime std.meta.hasFn(TestProtocol, "availability"))
        TestProtocol.availability(opcode)
    else if (comptime info.defined)
        .always
    else
        .never;
    const static_gas: support.StaticGas = if (comptime std.meta.hasFn(TestProtocol, "staticGas"))
        TestProtocol.staticGas(opcode)
    else
        .{ .constant = @intCast(info.static_gas) };
    const tier: support.OpcodeTier = if (opcode == .ADD) .hot else .cold;
    const execution_target: dispatcher.ExecutionTarget = if (!info.defined)
        .invalid
    else switch (opcode) {
        .INVALID => .invalid,
        else => .{ .builtin = opcode },
    };
    const constant_static_gas = switch (static_gas) {
        .constant => true,
        .revision_bands => false,
    };
    return .{
        .opcode_byte = opcode_byte,
        .opcode = opcode,
        .info = info,
        .availability = availability,
        .static_gas = static_gas,
        .tier = tier,
        .execution_target = execution_target,
        .hot_path = availability == .always and constant_static_gas and tier == .hot,
    };
}

fn executeBalance(comptime Protocol: type, revision: Protocol.Revision) !i64 {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.BALANCE)};

    var frame = try Interpreter.OwnedCallFrame(Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = revision,
    });
    defer frame.deinit();

    try frame.frame.stack.push(0);
    try For(Protocol).execute(@intFromEnum(Opcode.BALANCE), frame.frame);
    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    return frame.frame.gas_left;
}

fn expectOpcodeStatus(comptime Protocol: type, revision: Protocol.Revision, opcode: Opcode, expected: Interpreter.FrameStatus) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(opcode)};

    var frame = try Interpreter.OwnedCallFrame(Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = revision,
    });
    defer frame.deinit();

    try For(Protocol).execute(@intFromEnum(opcode), frame.frame);
    try std.testing.expectEqual(expected, frame.frame.status);
}

test "static gas helper uses resolved rule gas" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.CALL)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .frontier,
    });
    defer frame.deinit();

    const ConstantProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub fn staticGas(comptime opcode: Opcode) support.StaticGas {
            _ = opcode;
            return .{ .constant = 7 };
        }

        pub fn dispatchTable() dispatcher.DispatchTable {
            return testDispatchTable(@This());
        }

        pub fn staticGasForRevision(revision: evmz.eth.Revision, comptime opcode: Opcode) i64 {
            _ = revision;
            _ = opcode;
            return 99;
        }
    };
    const BandedProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub fn staticGas(comptime opcode: Opcode) support.StaticGas {
            _ = opcode;
            return .{ .revision_bands = support.StaticGasBands.from(.{
                .{ .since = evmz.eth.Revision.frontier, .gas = 11 },
                .{ .since = evmz.eth.Revision.homestead, .gas = 13 },
            }) };
        }

        pub fn dispatchTable() dispatcher.DispatchTable {
            return testDispatchTable(@This());
        }

        pub fn staticGasForRevision(revision: evmz.eth.Revision, comptime opcode: Opcode) i64 {
            _ = opcode;
            return if (revision == .frontier) 11 else 13;
        }
    };

    try std.testing.expectEqual(@as(i64, 7), For(ConstantProtocol).staticGasForFrame(frame.frame, .CALL));
    try std.testing.expectEqual(@as(i64, 11), For(BandedProtocol).staticGasForFrame(frame.frame, .CALL));
}

test "interpreter executes with non-Ethereum revision protocol" {
    const CustomRevision = enum(u8) {
        alpha = 10,
        beta = 2,
    };
    const Order = struct {
        fn order(a: CustomRevision, b: CustomRevision) std.math.Order {
            const rank = struct {
                fn of(revision: CustomRevision) u8 {
                    return switch (revision) {
                        .alpha => 0,
                        .beta => 1,
                    };
                }
            }.of;
            return std.math.order(rank(a), rank(b));
        }
    };
    const Semantics = struct {
        pub const BaseRevision = CustomRevision;

        pub fn baseRevision(revision_value: CustomRevision) BaseRevision {
            return revision_value;
        }
    };
    const Gates = struct {
        fn logging(revision_value: CustomRevision) bool {
            return revision_value == .beta;
        }
    };
    const revision = support.ModelWithConfig(CustomRevision, .{
        .revisions = &.{ .alpha, .beta },
        .order = Order.order,
        .semantics = Semantics,
    });

    const CustomProtocol = struct {
        pub const Revision = CustomRevision;
        pub const isImpl = revision.isImpl;

        pub fn staticGas(comptime opcode: Opcode) support.StaticGas {
            if (opcode == .ADD) return .{ .revision_bands = support.StaticGasBands.from(.{
                .{ .since = CustomRevision.alpha, .gas = 3 },
                .{ .since = CustomRevision.beta, .gas = 4 },
            }) };
            if (opcode == .PUSH1) return .{ .constant = 4 };
            if (opcode == .SSTORE) return .{ .constant = 17 };
            return .{ .constant = @intCast(opcode_info.info(@intFromEnum(opcode)).static_gas) };
        }

        pub fn availability(comptime opcode: Opcode) support.Resolution {
            if (opcode == .LOG1) return .runtime;
            return .always;
        }

        pub fn dispatchTable() dispatcher.DispatchTable {
            return testDispatchTable(@This());
        }

        pub const Instruction = struct {
            pub const Value = u8;

            pub fn fromByte(comptime opcode_byte: u8) Value {
                return opcode_byte;
            }

            pub fn rawAvailability(comptime value: Value) revision.Availability {
                if (value == @intFromEnum(Opcode.LOG1)) return .{ .gate = Gates.logging };
                return .always;
            }

            pub fn staticGasForRevision(revision_value: CustomRevision, comptime value: Value) i64 {
                const opcode: Opcode = @enumFromInt(value);
                if (opcode == .ADD and revision_value == .beta) return 4;
                if (opcode == .PUSH1) return 4;
                if (opcode == .SSTORE) return 17;
                return @intCast(opcode_info.info(value).static_gas);
            }

            pub fn expByteGas(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 1;
            }

            pub fn accountReadColdAccessGas(revision_value: CustomRevision) ?i64 {
                _ = revision_value;
                return null;
            }

            pub fn codeAccountAccessGas(revision_value: CustomRevision, status: protocol_types.AccountAccessStatus) ?i64 {
                _ = revision_value;
                _ = status;
                return null;
            }
        };

        pub const storage = struct {
            pub fn sloadColdStorageAccessGas(revision_value: CustomRevision) ?i64 {
                _ = revision_value;
                return null;
            }

            pub fn sstoreMinimumGas(revision_value: CustomRevision) ?i64 {
                _ = revision_value;
                return null;
            }

            pub fn sstoreStorageAccessGas(revision_value: CustomRevision, status: protocol_types.AccountAccessStatus) ?i64 {
                _ = revision_value;
                _ = status;
                return null;
            }

            pub fn sstoreGas(revision_value: CustomRevision, status: protocol_types.StorageStatus) protocol_types.StorageGas {
                _ = revision_value;
                _ = status;
                return .{};
            }

            pub fn sstoreStateGas(revision_value: CustomRevision, status: protocol_types.StorageStatus) protocol_types.StorageStateGas {
                _ = revision_value;
                _ = status;
                return .{};
            }
        };

        pub const call = struct {
            pub fn callBaseGas(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 40;
            }

            pub fn callColdAccountAccessGas(revision_value: CustomRevision) ?i64 {
                _ = revision_value;
                return null;
            }

            pub fn callValueTransferGas(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 0;
            }

            pub fn callValueStipend(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 0;
            }

            pub fn callNewAccountGas(revision_value: CustomRevision, input: protocol_types.CallNewAccountInput) protocol_types.CallNewAccountGas {
                _ = revision_value;
                _ = input;
                return .{};
            }

            pub fn topFrameValueTransferStateGas(revision_value: CustomRevision, input: protocol_types.TopFrameValueTransferInput) i64 {
                _ = revision_value;
                _ = input;
                return 0;
            }

            pub fn delegatedAccountAccessGas(revision_value: CustomRevision, cold: bool) i64 {
                _ = revision_value;
                _ = cold;
                return 0;
            }

            pub fn topLevelDelegatedAccountAccess(
                revision_value: CustomRevision,
                input: protocol_types.TopLevelDelegatedAccountAccessInput,
            ) ?protocol_types.DelegatedAccountAccess {
                _ = revision_value;
                _ = input;
                return null;
            }

            pub fn touchesEmptyCallRecipient(revision_value: CustomRevision) bool {
                _ = revision_value;
                return false;
            }

            pub fn childGas(revision_value: CustomRevision, input: protocol_types.ChildGasInput) protocol_types.ChildGas {
                _ = revision_value;
                return .{ .gas = @min(input.requested, input.available) };
            }
        };

        pub const create = struct {
            pub fn createInitCodeSizeLimit(revision_value: CustomRevision) ?usize {
                _ = revision_value;
                return null;
            }

            pub fn createInitCodeWordGas(revision_value: CustomRevision, is_create2: bool) i64 {
                _ = revision_value;
                _ = is_create2;
                return 0;
            }

            pub fn createAccountStateGas(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 0;
            }
        };

        pub const self_destruct = struct {
            pub fn selfDestructPolicy(
                revision_value: CustomRevision,
                input: protocol_types.SelfDestructPolicyInput,
            ) protocol_types.SelfDestructPolicy {
                _ = revision_value;
                _ = input;
                return .{
                    .clear_balance = true,
                    .reset_nonce = false,
                    .mark_selfdestructed = true,
                };
            }

            pub fn selfDestructFinalization(revision_value: CustomRevision, created_in_transaction: bool) protocol_types.SelfDestructFinalization {
                _ = revision_value;
                _ = created_in_transaction;
                return .{ .delete_account = true, .clear_storage = true };
            }

            pub fn selfDestructNewAccountGas(
                revision_value: CustomRevision,
                input: protocol_types.SelfDestructNewAccountInput,
            ) protocol_types.CallNewAccountGas {
                _ = revision_value;
                _ = input;
                return .{};
            }

            pub fn selfDestructColdAccountAccessGas(revision_value: CustomRevision) ?i64 {
                _ = revision_value;
                return null;
            }

            pub fn selfDestructRefundGas(revision_value: CustomRevision) i64 {
                _ = revision_value;
                return 0;
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 2,
        @intFromEnum(Opcode.PUSH1), 3,
        @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
    };

    var frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .beta,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 88), result.gas_left);
    try std.testing.expectEqual(@as(u256, 5), frame.frame.stack.pop());

    var alpha_frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .alpha,
    });
    defer alpha_frame.deinit();
    var alpha_interpreter = alpha_frame.interpreter();
    const alpha_result = try alpha_interpreter.execute();
    try std.testing.expectEqual(Interpreter.Status.success, alpha_result.status);
    try std.testing.expectEqual(@as(i64, 89), alpha_result.gas_left);

    const storage_code = [_]u8{
        @intFromEnum(Opcode.PUSH1),  42,
        @intFromEnum(Opcode.PUSH1),  0,
        @intFromEnum(Opcode.SSTORE), @intFromEnum(Opcode.STOP),
    };
    var storage_msg = evmz.t.defaultMessage();
    storage_msg.gas = 100;

    var raw_storage_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer raw_storage_state.deinit();
    var raw_storage_host = raw_storage_state.host();
    var raw_storage_frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &raw_storage_host,
        .msg = &storage_msg,
        .code = &storage_code,
        .revision = .beta,
    });
    defer raw_storage_frame.deinit();
    var raw_storage_interpreter = raw_storage_frame.interpreter();
    const raw_storage_result = try raw_storage_interpreter.execute();

    var storage_bytecode = try evmz.Bytecode.init(std.testing.allocator, &storage_code);
    defer storage_bytecode.deinit(std.testing.allocator);
    var prepared_storage_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer prepared_storage_state.deinit();
    var prepared_storage_host = prepared_storage_state.host();
    var prepared_storage_frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &prepared_storage_host,
        .msg = &storage_msg,
        .bytecode = &storage_bytecode,
        .revision = .beta,
    });
    defer prepared_storage_frame.deinit();
    var prepared_storage_interpreter = prepared_storage_frame.interpreter();
    const prepared_storage_result = try prepared_storage_interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.success, raw_storage_result.status);
    try std.testing.expectEqual(Interpreter.Status.success, prepared_storage_result.status);
    try std.testing.expectEqual(@as(i64, 92), raw_storage_result.gas_left);
    try std.testing.expectEqual(raw_storage_result.gas_left, prepared_storage_result.gas_left);
    try std.testing.expectEqual(@as(u256, 42), raw_storage_state.storageValue(0));
    try std.testing.expectEqual(@as(u256, 42), prepared_storage_state.storageValue(0));

    const log_code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0,
        @intFromEnum(Opcode.PUSH1), 0,
        @intFromEnum(Opcode.PUSH1), 0,
        @intFromEnum(Opcode.LOG1),
    };
    var log_msg = evmz.t.defaultMessage();
    log_msg.gas = 10_000;
    var log_bytecode = try evmz.Bytecode.init(std.testing.allocator, &log_code);
    defer log_bytecode.deinit(std.testing.allocator);
    var log_frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &log_msg,
        .bytecode = &log_bytecode,
        .revision = .alpha,
    });
    defer log_frame.deinit();
    var log_interpreter = log_frame.interpreter();

    const log_result = try log_interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, log_result.status);
    try std.testing.expectEqual(@as(usize, 0), mock_host.logs.items.len);

    var beta_log_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer beta_log_state.deinit();
    var beta_log_host = beta_log_state.host();
    var beta_log_frame = try Interpreter.OwnedCallFrame(CustomProtocol).init(std.testing.allocator, .{
        .host = &beta_log_host,
        .msg = &log_msg,
        .bytecode = &log_bytecode,
        .revision = .beta,
    });
    defer beta_log_frame.deinit();
    var beta_log_interpreter = beta_log_frame.interpreter();
    const beta_log_result = try beta_log_interpreter.execute();
    try std.testing.expectEqual(Interpreter.Status.success, beta_log_result.status);
    try std.testing.expectEqual(@as(usize, 1), beta_log_state.logs.items.len);
}

pub fn staticGas(opcode: Opcode) u16 {
    return opcode_info.table[@intFromEnum(opcode)].static_gas;
}

const UnknownBuiltinHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions;
        _ = frame;
        return error.UnknownOpcode;
    }
};

const InvalidBuiltinHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions;
        return system.invalid(frame);
    }
};

fn NoGasHandler(comptime run: anytype) type {
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            _ = Instructions;
            return run_fn(frame);
        }
    };
}

fn ChargeHandler(comptime opcode: Opcode, comptime run: anytype) type {
    const op = opcode;
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return run_fn(frame);
        }
    };
}

fn RequireChargeHandler(comptime opcode: Opcode, comptime run: anytype) type {
    const op = opcode;
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return run_fn(frame);
        }
    };
}

fn PushHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.push(frame, @intFromEnum(op) - @intFromEnum(Opcode.PUSH0));
        }
    };
}

fn DupHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.dup(frame, @intFromEnum(op) - @intFromEnum(Opcode.DUP1) + 1);
        }
    };
}

fn SwapHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.swap(frame, @intFromEnum(op) - @intFromEnum(Opcode.SWAP1) + 1);
        }
    };
}

fn LogHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            const topics: u8 = @intFromEnum(op) - @intFromEnum(Opcode.LOG0);
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return logging.log(frame, topics);
        }
    };
}

const ExpHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXP)) return;
        return arithmetic.For(Instructions.Protocol).exp(frame);
    }
};

const BalanceHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .BALANCE)) return;
        return environment.For(Instructions.Protocol).balance(frame);
    }
};

const ExtCodeSizeHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXTCODESIZE)) return;
        return environment.For(Instructions.Protocol).extcodesize(frame);
    }
};

const ExtCodeCopyHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXTCODECOPY)) return;
        return environment.For(Instructions.Protocol).extcodecopy(frame);
    }
};

const ExtCodeHashHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .EXTCODEHASH)) return;
        if (!Instructions.chargeStaticGas(frame, .EXTCODEHASH)) return;
        return environment.For(Instructions.Protocol).extcodehash(frame);
    }
};

const JumpDestHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions.chargeStaticGas(frame, .JUMPDEST);
        return;
    }
};

const SLoadHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .SLOAD)) return;
        return storage.For(Instructions.Protocol).sload(frame);
    }
};

const SStoreHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        return storage.For(Instructions.Protocol).sstore(frame);
    }
};

const DupNHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .DUPN)) return;
        if (!Instructions.chargeStaticGas(frame, .DUPN)) return;
        return stack.dupn(frame);
    }
};

const SwapNHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .SWAPN)) return;
        if (!Instructions.chargeStaticGas(frame, .SWAPN)) return;
        return stack.swapn(frame);
    }
};

const ExchangeHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .EXCHANGE)) return;
        if (!Instructions.chargeStaticGas(frame, .EXCHANGE)) return;
        return stack.exchange(frame);
    }
};

const CreateHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .CREATE)) return;
        return system.For(Instructions.Protocol).create(frame);
    }
};

fn CallByOpHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (comptime op == .DELEGATECALL or op == .STATICCALL) {
                if (!Instructions.requireOpcode(frame, op)) return;
            }
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return system.For(Instructions.Protocol).callByOp(frame, op);
        }
    };
}

const ReturnHandler = NoGasHandler(system.ret);

const Create2Handler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .CREATE2)) return;
        if (!Instructions.chargeStaticGas(frame, .CREATE2)) return;
        return system.For(Instructions.Protocol).create2(frame);
    }
};

const RevertHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .REVERT)) return;
        return system.revert(frame);
    }
};

const SelfDestructHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .SELFDESTRUCT)) return;
        return system.For(Instructions.Protocol).selfdestruct(frame);
    }
};

const BuiltinInstruction = struct {
    opcode: Opcode,
    handler: type,
};

const builtin_instruction_catalog = [_]BuiltinInstruction{
    .{ .opcode = .STOP, .handler = NoGasHandler(system.stop) },
    .{ .opcode = .ADD, .handler = ChargeHandler(.ADD, arithmetic.add) },
    .{ .opcode = .MUL, .handler = ChargeHandler(.MUL, arithmetic.mul) },
    .{ .opcode = .SUB, .handler = ChargeHandler(.SUB, arithmetic.sub) },
    .{ .opcode = .DIV, .handler = ChargeHandler(.DIV, arithmetic.div) },
    .{ .opcode = .SDIV, .handler = ChargeHandler(.SDIV, arithmetic.sdiv) },
    .{ .opcode = .MOD, .handler = ChargeHandler(.MOD, arithmetic.mod) },
    .{ .opcode = .SMOD, .handler = ChargeHandler(.SMOD, arithmetic.smod) },
    .{ .opcode = .ADDMOD, .handler = ChargeHandler(.ADDMOD, arithmetic.addmod) },
    .{ .opcode = .MULMOD, .handler = ChargeHandler(.MULMOD, arithmetic.mulmod) },
    .{ .opcode = .EXP, .handler = ExpHandler },
    .{ .opcode = .SIGNEXTEND, .handler = ChargeHandler(.SIGNEXTEND, arithmetic.signextend) },
    .{ .opcode = .LT, .handler = ChargeHandler(.LT, logic.lt) },
    .{ .opcode = .GT, .handler = ChargeHandler(.GT, logic.gt) },
    .{ .opcode = .SLT, .handler = ChargeHandler(.SLT, logic.slt) },
    .{ .opcode = .SGT, .handler = ChargeHandler(.SGT, logic.sgt) },
    .{ .opcode = .EQ, .handler = ChargeHandler(.EQ, logic.eq) },
    .{ .opcode = .ISZERO, .handler = ChargeHandler(.ISZERO, logic.iszero) },
    .{ .opcode = .AND, .handler = ChargeHandler(.AND, logic.bitAnd) },
    .{ .opcode = .OR, .handler = ChargeHandler(.OR, logic.bitOr) },
    .{ .opcode = .XOR, .handler = ChargeHandler(.XOR, logic.bitXor) },
    .{ .opcode = .NOT, .handler = ChargeHandler(.NOT, logic.bitNot) },
    .{ .opcode = .BYTE, .handler = ChargeHandler(.BYTE, logic.byte) },
    .{ .opcode = .SHL, .handler = RequireChargeHandler(.SHL, logic.shl) },
    .{ .opcode = .SHR, .handler = RequireChargeHandler(.SHR, logic.shr) },
    .{ .opcode = .SAR, .handler = RequireChargeHandler(.SAR, logic.sar) },
    .{ .opcode = .CLZ, .handler = RequireChargeHandler(.CLZ, logic.clz) },
    .{ .opcode = .KECCAK256, .handler = ChargeHandler(.KECCAK256, arithmetic.keccak256) },
    .{ .opcode = .ADDRESS, .handler = ChargeHandler(.ADDRESS, environment.address) },
    .{ .opcode = .BALANCE, .handler = BalanceHandler },
    .{ .opcode = .ORIGIN, .handler = ChargeHandler(.ORIGIN, environment.origin) },
    .{ .opcode = .CALLER, .handler = ChargeHandler(.CALLER, environment.caller) },
    .{ .opcode = .CALLVALUE, .handler = ChargeHandler(.CALLVALUE, environment.callvalue) },
    .{ .opcode = .CALLDATALOAD, .handler = ChargeHandler(.CALLDATALOAD, environment.calldataload) },
    .{ .opcode = .CALLDATASIZE, .handler = ChargeHandler(.CALLDATASIZE, environment.calldatasize) },
    .{ .opcode = .CALLDATACOPY, .handler = ChargeHandler(.CALLDATACOPY, environment.calldatacopy) },
    .{ .opcode = .CODESIZE, .handler = ChargeHandler(.CODESIZE, environment.codesize) },
    .{ .opcode = .CODECOPY, .handler = ChargeHandler(.CODECOPY, environment.codecopy) },
    .{ .opcode = .GASPRICE, .handler = ChargeHandler(.GASPRICE, environment.gasprice) },
    .{ .opcode = .EXTCODESIZE, .handler = ExtCodeSizeHandler },
    .{ .opcode = .EXTCODECOPY, .handler = ExtCodeCopyHandler },
    .{ .opcode = .RETURNDATASIZE, .handler = RequireChargeHandler(.RETURNDATASIZE, environment.returndatasize) },
    .{ .opcode = .RETURNDATACOPY, .handler = RequireChargeHandler(.RETURNDATACOPY, environment.returndatacopy) },
    .{ .opcode = .EXTCODEHASH, .handler = ExtCodeHashHandler },
    .{ .opcode = .BLOCKHASH, .handler = ChargeHandler(.BLOCKHASH, environment.blockhash) },
    .{ .opcode = .COINBASE, .handler = ChargeHandler(.COINBASE, environment.coinbase) },
    .{ .opcode = .TIMESTAMP, .handler = ChargeHandler(.TIMESTAMP, environment.timestamp) },
    .{ .opcode = .NUMBER, .handler = ChargeHandler(.NUMBER, environment.number) },
    .{ .opcode = .PREVRANDAO, .handler = ChargeHandler(.PREVRANDAO, environment.prevrandao) },
    .{ .opcode = .GASLIMIT, .handler = ChargeHandler(.GASLIMIT, environment.gaslimit) },
    .{ .opcode = .CHAINID, .handler = RequireChargeHandler(.CHAINID, environment.chainid) },
    .{ .opcode = .SELFBALANCE, .handler = RequireChargeHandler(.SELFBALANCE, environment.selfbalance) },
    .{ .opcode = .BASEFEE, .handler = RequireChargeHandler(.BASEFEE, environment.basefee) },
    .{ .opcode = .BLOBHASH, .handler = RequireChargeHandler(.BLOBHASH, environment.blobhash) },
    .{ .opcode = .BLOBBASEFEE, .handler = RequireChargeHandler(.BLOBBASEFEE, environment.blobbasefee) },
    .{ .opcode = .SLOTNUM, .handler = RequireChargeHandler(.SLOTNUM, environment.slotnum) },
    .{ .opcode = .POP, .handler = ChargeHandler(.POP, stack.pop) },
    .{ .opcode = .MLOAD, .handler = ChargeHandler(.MLOAD, memory.mload) },
    .{ .opcode = .MSTORE, .handler = ChargeHandler(.MSTORE, memory.mstore) },
    .{ .opcode = .MSTORE8, .handler = ChargeHandler(.MSTORE8, memory.mstore8) },
    .{ .opcode = .SLOAD, .handler = SLoadHandler },
    .{ .opcode = .SSTORE, .handler = SStoreHandler },
    .{ .opcode = .JUMP, .handler = ChargeHandler(.JUMP, flow.jump) },
    .{ .opcode = .JUMPI, .handler = ChargeHandler(.JUMPI, flow.jumpi) },
    .{ .opcode = .PC, .handler = ChargeHandler(.PC, flow.pc) },
    .{ .opcode = .MSIZE, .handler = ChargeHandler(.MSIZE, memory.msize) },
    .{ .opcode = .GAS, .handler = ChargeHandler(.GAS, environment.gas) },
    .{ .opcode = .JUMPDEST, .handler = JumpDestHandler },
    .{ .opcode = .TLOAD, .handler = RequireChargeHandler(.TLOAD, storage.tload) },
    .{ .opcode = .TSTORE, .handler = RequireChargeHandler(.TSTORE, storage.tstore) },
    .{ .opcode = .MCOPY, .handler = RequireChargeHandler(.MCOPY, memory.mcopy) },
    .{ .opcode = .PUSH0, .handler = RequireChargeHandler(.PUSH0, stack.push0) },
    .{ .opcode = .DUPN, .handler = DupNHandler },
    .{ .opcode = .SWAPN, .handler = SwapNHandler },
    .{ .opcode = .EXCHANGE, .handler = ExchangeHandler },
    .{ .opcode = .CREATE, .handler = CreateHandler },
    .{ .opcode = .CALL, .handler = CallByOpHandler(.CALL) },
    .{ .opcode = .CALLCODE, .handler = CallByOpHandler(.CALLCODE) },
    .{ .opcode = .RETURN, .handler = ReturnHandler },
    .{ .opcode = .DELEGATECALL, .handler = CallByOpHandler(.DELEGATECALL) },
    .{ .opcode = .CREATE2, .handler = Create2Handler },
    .{ .opcode = .STATICCALL, .handler = CallByOpHandler(.STATICCALL) },
    .{ .opcode = .REVERT, .handler = RevertHandler },
    .{ .opcode = .INVALID, .handler = InvalidBuiltinHandler },
    .{ .opcode = .SELFDESTRUCT, .handler = SelfDestructHandler },
};

const builtin_handler_table: [256]type = blk: {
    var table = [_]type{UnknownBuiltinHandler} ** 256;
    for (builtin_instruction_catalog) |instruction| {
        table[@intFromEnum(instruction.opcode)] = instruction.handler;
    }
    for (@intFromEnum(Opcode.PUSH1)..@intFromEnum(Opcode.PUSH32) + 1) |byte| {
        table[byte] = PushHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.DUP1)..@intFromEnum(Opcode.DUP16) + 1) |byte| {
        table[byte] = DupHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.SWAP1)..@intFromEnum(Opcode.SWAP16) + 1) |byte| {
        table[byte] = SwapHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.LOG0)..@intFromEnum(Opcode.LOG4) + 1) |byte| {
        table[byte] = LogHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    break :blk table;
};

inline fn builtinHandlerForByte(comptime opcode_byte: u8) type {
    return builtin_handler_table[opcode_byte];
}

inline fn builtinHandlerForOpcode(comptime opcode: Opcode) type {
    return builtinHandlerForByte(@intFromEnum(opcode));
}

comptime {
    assertBuiltinHandlerCatalogCoversBaseOpcodeTable();
}

fn assertBuiltinHandlerCatalogCoversBaseOpcodeTable() void {
    @setEvalBranchQuota(10_000);
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const Handler = builtinHandlerForByte(opcode_byte);
        const defined = opcode_info.info(opcode_byte).defined;
        if (defined) {
            std.debug.assert(Handler != UnknownBuiltinHandler);
        } else {
            std.debug.assert(Handler == UnknownBuiltinHandler);
        }
    }
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();
        const has_dispatch_table = std.meta.hasFn(Protocol, "dispatchTable");
        const dispatch_table: dispatcher.DispatchTable = if (has_dispatch_table) Protocol.dispatchTable() else undefined;

        pub const Protocol = ProtocolType;

        pub fn staticGasForRevision(revision: Protocol.Revision, comptime opcode: Opcode) i64 {
            return Protocol.Instruction.staticGasForRevision(
                revision,
                Protocol.Instruction.fromByte(@intFromEnum(opcode)),
            );
        }

        pub inline fn frameRevision(frame: *const CallFrame) Protocol.Revision {
            return Interpreter.For(Protocol).revision(frame);
        }

        pub inline fn revisionIncludes(current: Protocol.Revision, activation: Protocol.Revision) bool {
            if (comptime @hasDecl(Protocol, "isImpl")) {
                return Protocol.isImpl(current, activation);
            }
            return @intFromEnum(current) >= @intFromEnum(activation);
        }

        pub inline fn staticGasForFrame(frame: *CallFrame, comptime opcode: Opcode) i64 {
            return switch (comptime Self.dispatchEntryForOpcode(opcode).static_gas) {
                .constant => |gas| gas,
                .revision_bands => |bands| Self.staticGasFromBands(Self.frameRevision(frame), bands),
            };
        }

        pub inline fn execute(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            if (comptime @hasDecl(Protocol, "hot_cold_dispatch_enabled") and Protocol.hot_cold_dispatch_enabled) {
                return executeHotCold(opcode_byte, frame);
            }
            return executeFull(opcode_byte, frame);
        }

        inline fn executeHotCold(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            @setEvalBranchQuota(30_000);
            return switch (opcode_byte) {
                inline 0...255 => |byte| {
                    const dispatch_byte: u8 = @intCast(byte);
                    if (comptime Self.hotPathByte(dispatch_byte)) {
                        return Self.executeDispatchEntryForByte(dispatch_byte, frame);
                    }
                    return executeCold(dispatch_byte, frame);
                },
            };
        }

        noinline fn executeCold(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            return executeFull(opcode_byte, frame);
        }

        inline fn executeFull(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            @setEvalBranchQuota(30_000);
            return switch (opcode_byte) {
                inline 0...255 => |byte| Self.executeDispatchEntryForByte(@as(u8, byte), frame),
            };
        }

        inline fn hotPath(comptime opcode: Opcode) bool {
            return Self.hotPathByte(@intFromEnum(opcode));
        }

        inline fn hotPathByte(comptime opcode_byte: u8) bool {
            return Self.dispatchEntryForByte(opcode_byte).hot_path;
        }

        pub inline fn executeDispatchEntryForByte(comptime opcode_byte: u8, frame: *CallFrame) anyerror!void {
            return Self.executeDispatchEntry(Self.dispatchEntryForByte(opcode_byte), frame);
        }

        pub inline fn tailFastPathBuiltin(comptime opcode: Opcode) ?support.Resolution {
            const entry = comptime Self.dispatchEntryForOpcode(opcode);
            return switch (comptime entry.dispatchTarget()) {
                .builtin => |builtin| if (builtin == opcode) entry.availability else null,
                .invalid, .custom => null,
            };
        }

        inline fn dispatchEntryForOpcode(comptime opcode: Opcode) dispatcher.DispatchEntry {
            return Self.dispatchEntryForByte(@intFromEnum(opcode));
        }

        inline fn dispatchEntryForByte(comptime opcode_byte: u8) dispatcher.DispatchEntry {
            if (comptime has_dispatch_table) return dispatch_table[opcode_byte];
            return Protocol.Instruction.entry(Protocol.Instruction.fromByte(opcode_byte));
        }

        pub inline fn executeDispatchEntry(comptime entry: dispatcher.DispatchEntry, frame: *CallFrame) anyerror!void {
            return switch (comptime entry.dispatchTarget()) {
                .invalid => Self.executeInvalidDispatchEntry(entry, frame),
                .builtin => |opcode| builtinHandlerForOpcode(opcode).execute(Self, frame),
                .custom => |Handler| Self.executeCustomDispatchEntry(Handler, frame),
            };
        }

        inline fn executeInvalidDispatchEntry(comptime entry: dispatcher.DispatchEntry, frame: *CallFrame) anyerror!void {
            if (comptime !entry.defined()) return error.UnknownOpcode;
            return system.invalid(frame);
        }

        inline fn executeCustomDispatchEntry(comptime Handler: type, frame: *CallFrame) anyerror!void {
            return Handler.execute(Self, frame);
        }

        pub inline fn chargeStaticGas(frame: *CallFrame, comptime opcode: Opcode) bool {
            return chargeGas(frame, Self.staticGasForFrame(frame, opcode));
        }

        inline fn staticGasFromBands(revision: Protocol.Revision, comptime bands: support.StaticGasBands) i64 {
            const len: usize = bands.len;
            inline for (0..len) |offset| {
                const index = len - 1 - offset;
                const band = bands.items[index];
                const activation = support.decodeRevision(Protocol.Revision, band.since);
                if (Self.revisionIncludes(revision, activation)) return band.gas;
            }
            unreachable;
        }

        inline fn chargeGas(frame: *CallFrame, gas: i64) bool {
            frame.trackGas(gas);
            return frame.status == .running;
        }

        pub inline fn requireOpcode(frame: *CallFrame, comptime opcode: Opcode) bool {
            @setEvalBranchQuota(10_000);
            return switch (comptime Self.dispatchEntryForOpcode(opcode).availability) {
                .always => true,
                .never => failInvalid(frame),
                .runtime => switch (comptime Protocol.Instruction.rawAvailability(
                    Protocol.Instruction.fromByte(@intFromEnum(opcode)),
                )) {
                    .always => true,
                    .never => failInvalid(frame),
                    .since => |activation| if (Self.revisionIncludes(Self.frameRevision(frame), activation)) true else failInvalid(frame),
                    .gate => |active| if (active(Self.frameRevision(frame))) true else failInvalid(frame),
                },
            };
        }
    };
}

inline fn failInvalid(frame: *CallFrame) bool {
    frame.failWithStatus(.invalid);
    return false;
}
