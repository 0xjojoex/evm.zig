const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const instruction = evmz.instruction;
const Host = evmz.Host;
const std = @import("std");

const CallFrame = Interpreter.CallFrame;
const AccountAccessStatus = evmz.protocol.AccountAccessStatus;
const DefinitionStorageStatus = evmz.protocol.StorageStatus;

fn accountAccessStatus(status: Host.AccessStatus) AccountAccessStatus {
    return switch (status) {
        .cold => .cold,
        .warm => .warm,
    };
}

fn storageStatus(status: Host.StorageStatus) DefinitionStorageStatus {
    return switch (status) {
        .assigned => .assigned,
        .added => .added,
        .deleted => .deleted,
        .modified => .modified,
        .deleted_added => .deleted_added,
        .modified_deleted => .modified_deleted,
        .deleted_restored => .deleted_restored,
        .added_deleted => .added_deleted,
        .modified_restored => .modified_restored,
    };
}

test "Petersburg disables Constantinople net SSTORE metering until Istanbul" {
    const storage = evmz.eth.system.Storage;
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 200, .refund = 4800 }, storage.sstoreGas(.constantinople, .modified_restored));
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 5000, .refund = 0 }, storage.sstoreGas(.petersburg, .modified_restored));
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 800, .refund = 4200 }, storage.sstoreGas(.istanbul, .modified_restored));
}

test "Amsterdam SSTORE separates access and write gas from state gas" {
    const storage = evmz.eth.system.Storage;
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 10_000, .refund = 0 }, storage.sstoreGas(.amsterdam, .added));
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 0, .refund = 10_000 }, storage.sstoreGas(.amsterdam, .added_deleted));
    try std.testing.expectEqual(evmz.protocol.StorageGas{ .cost = 0, .refund = -2_480 }, storage.sstoreGas(.amsterdam, .deleted_restored));
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        inline fn frameRevision(frame: *const CallFrame) Protocol.Revision {
            return Interpreter.For(Protocol).revision(frame);
        }

        pub fn sstore(frame: *CallFrame) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }
            const key, const value = try frame.stack.popN(2);

            try Self.sstoreAfterPop(frame, key, value);
        }

        pub fn sstoreAfterPop(frame: *CallFrame, key: u256, value: u256) !void {
            const recipient = frame.msg.recipient;
            const host = frame.host;
            const revision = Self.frameRevision(frame);

            if (Protocol.storage.sstoreMinimumGas(revision)) |minimum_gas| {
                if (frame.gas_left <= minimum_gas) {
                    frame.failWithStatus(.out_of_gas);
                    return;
                }
            }

            const host_status = blk: {
                if (Protocol.storage.sstoreStorageAccessGas(revision, .warm)) |warm_access_gas| {
                    const cold_access_gas = Protocol.storage.sstoreStorageAccessGas(revision, .cold) orelse warm_access_gas;
                    if (frame.gas_left >= @max(warm_access_gas, cold_access_gas)) {
                        const result = try host.storeStorage(recipient, key, value);
                        const access_status = accountAccessStatus(result.access_status);
                        frame.trackGas(Protocol.storage.sstoreStorageAccessGas(revision, access_status) orelse 0);
                        if (frame.status != .running) return;
                        break :blk result.storage_status;
                    }

                    const access_status = accountAccessStatus(try host.accessStorage(recipient, key));
                    const access_gas = Protocol.storage.sstoreStorageAccessGas(revision, access_status) orelse 0;
                    frame.trackGas(access_gas);
                    if (frame.status != .running) return;
                }

                break :blk try host.setStorage(recipient, key, value);
            };

            const status = storageStatus(host_status);

            const cost = Protocol.storage.sstoreGas(revision, status);

            frame.trackGas(cost.cost);
            if (frame.status != .running) return;
            frame.gas_refund += cost.refund;

            const state_gas = Protocol.storage.sstoreStateGas(revision, status);
            frame.trackStateGas(state_gas.charge);
            frame.refillStateGas(state_gas.refund);
        }

        pub fn sload(frame: *CallFrame) !void {
            const key = try frame.stack.pop();
            const value = (try Self.sloadAfterPop(frame, key)) orelse return;
            frame.stack.pushUnchecked(value);
        }

        pub fn sloadAfterPop(frame: *CallFrame, key: u256) !?u256 {
            const host = frame.host;
            const recipient = frame.msg.recipient;
            const revision = Self.frameRevision(frame);

            if (Protocol.storage.sloadColdStorageAccessGas(revision)) |cold_storage_access_gas| {
                if (frame.gas_left >= cold_storage_access_gas) {
                    const result = try host.loadStorage(recipient, key);
                    if (result.access_status == .cold) {
                        frame.trackGas(cold_storage_access_gas);
                        if (frame.status != .running) return null;
                    }
                    return result.value;
                }

                if (try host.accessStorage(recipient, key) == .cold) {
                    frame.trackGas(cold_storage_access_gas);
                    if (frame.status != .running) return null;
                }
            }

            return try host.getStorage(recipient, key);
        }
    };
}

pub fn tload(frame: *CallFrame) !void {
    const key = try frame.stack.pop();
    const value = try frame.host.getTransientStorage(frame.msg.recipient, key);
    frame.stack.pushUnchecked(value);
}

pub fn tstore(frame: *CallFrame) !void {
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const key, const value = try frame.stack.popN(2);

    try frame.host.setTransientStorage(frame.msg.recipient, key, value);
}

test "transient storage opcodes are only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .TLOAD }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x00, .TLOAD }, .cancun, 1);

    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .cancun, .success);
}

test "SLOAD cold storage access gas comes from comptime protocol" {
    const CustomProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const storage = struct {
            pub fn sloadColdStorageAccessGas(revision: evmz.eth.Revision) ?i64 {
                _ = revision;
                return 11;
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.SLOAD)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .frontier,
    });
    defer frame.deinit();

    try frame.frame.stack.push(0);
    try For(CustomProtocol).sload(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_989), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_loads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "SSTORE gas and state gas come from comptime protocol" {
    const CustomProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const storage = struct {
            pub fn sstoreMinimumGas(revision: evmz.eth.Revision) ?i64 {
                _ = revision;
                return null;
            }

            pub fn sstoreStorageAccessGas(revision: evmz.eth.Revision, status: AccountAccessStatus) ?i64 {
                _ = revision;
                _ = status;
                return null;
            }

            pub fn sstoreGas(revision: evmz.eth.Revision, status: DefinitionStorageStatus) evmz.protocol.StorageGas {
                _ = revision;
                _ = status;
                return .{ .cost = 7, .refund = 3 };
            }

            pub fn sstoreStateGas(revision: evmz.eth.Revision, status: DefinitionStorageStatus) evmz.protocol.StorageStateGas {
                _ = revision;
                _ = status;
                return .{ .charge = 5 };
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas_reservoir = 5;
    const code = [_]u8{@intFromEnum(evmz.Opcode.SSTORE)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .frontier,
    });
    defer frame.deinit();

    try frame.frame.stack.push(42);
    try frame.frame.stack.push(0);
    try For(CustomProtocol).sstore(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_993), frame.frame.gas_left);
    try std.testing.expectEqual(@as(i64, 0), frame.frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 3), frame.frame.gas_refund);
    try std.testing.expectEqual(@as(i64, 5), frame.frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), frame.frame.state_gas_from_gas_left);
    try std.testing.expectEqual(@as(u256, 42), mock_host.storageValue(0));
}

test "cold SSTORE charges full cold SLOAD cost from Berlin" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 100_000,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .berlin,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 100_000 - 3 - 3 - instruction.cold_sload_cost - 20_000), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
}

test "Amsterdam cold new SSTORE charges state gas from reservoir" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 100_000,
        .gas_reservoir = @intCast(evmz.eth.transaction.amsterdam_storage_set_state_gas),
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .amsterdam,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 100_000 - 3 - 3 - 3_000 - 10_000), result.gas_left);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, @intCast(evmz.eth.transaction.amsterdam_storage_set_state_gas)), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
}

test "prepared cold Amsterdam SSTORE out of access gas stops before storage write" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 3 + 3 + 2_500,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .amsterdam,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 1), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u256, 0), mock_host.storageValue(0));
}

test "prepared SSTORE rejects static context before host access" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.is_static = true;
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .osaka,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u256, 0), mock_host.storageValue(0));
}

test "prepared cold SLOAD out of gas stops before storage read" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 3 + instruction.cold_sload_cost - 1,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const code = &.{ 0x60, 0x00, 0x54 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .berlin,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 1), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_loads);
}
