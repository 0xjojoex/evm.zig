const evmz = @import("../evm.zig");
const ExactSpec = @import("../spec.zig").Spec;
const Interpreter = @import("../Interpreter.zig");
const instruction = evmz.instruction;
const Host = evmz.Host;
const std = @import("std");

const CallFrame = Interpreter.CallFrame;
const AccountAccessStatus = evmz.execution.AccountAccessStatus;
const StorageStatus = evmz.execution.StorageStatus;

fn accountAccessStatus(status: Host.AccessStatus) AccountAccessStatus {
    return switch (status) {
        .cold => .cold,
        .warm => .warm,
    };
}

fn storageStatus(status: Host.StorageStatus) StorageStatus {
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
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 200, .refund = 4800 }, evmz.eth.constantinople.storage.sstoreGas(.modified_restored));
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 5000, .refund = 0 }, evmz.eth.petersburg.storage.sstoreGas(.modified_restored));
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 800, .refund = 4200 }, evmz.eth.istanbul.storage.sstoreGas(.modified_restored));
}

test "Amsterdam SSTORE separates access and write gas from state gas" {
    const storage = evmz.eth.amsterdam.storage;
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 10_000, .refund = 0 }, storage.sstoreGas(.added));
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 0, .refund = 10_000 }, storage.sstoreGas(.added_deleted));
    try std.testing.expectEqual(evmz.execution.StorageGas{ .cost = 0, .refund = -2_480 }, storage.sstoreGas(.deleted_restored));
}

pub fn bind(comptime spec: ExactSpec) type {
    return struct {
        const Self = @This();

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
            if (spec.storage.sstore_minimum_gas) |minimum_gas| {
                if (frame.gas_left <= minimum_gas) {
                    @branchHint(.unlikely);
                    frame.failWithStatus(.out_of_gas);
                    return;
                }
            }

            const host_status = blk: {
                if (spec.storage.sstoreAccessGas(.warm)) |warm_access_gas| {
                    const cold_access_gas = spec.storage.sstoreAccessGas(.cold) orelse warm_access_gas;
                    if (frame.gas_left >= @max(warm_access_gas, cold_access_gas)) {
                        const result = try host.storeStorage(recipient, key, value);
                        const access_status = accountAccessStatus(result.access_status);
                        if (!frame.trackGas(spec.storage.sstoreAccessGas(access_status) orelse 0)) return;
                        break :blk result.storage_status;
                    }

                    const access_status = accountAccessStatus(try host.accessStorage(recipient, key));
                    const access_gas = spec.storage.sstoreAccessGas(access_status) orelse 0;
                    if (!frame.trackGas(access_gas)) return;
                }

                break :blk try host.setStorage(recipient, key, value);
            };

            const status = storageStatus(host_status);

            const cost = spec.storage.sstoreGas(status);

            if (!frame.trackGas(cost.cost)) return;
            frame.gas_refund += cost.refund;

            const state_gas = spec.storage.sstoreStateGas(status);
            if (!frame.trackStateGas(state_gas.charge)) return;
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
            if (spec.storage.sload_cold_access_gas) |cold_storage_access_gas| {
                if (frame.gas_left >= cold_storage_access_gas) {
                    const result = try host.loadStorage(recipient, key);
                    if (result.access_status == .cold) {
                        if (!frame.trackGas(cold_storage_access_gas)) return null;
                    }
                    return result.value;
                }

                if (try host.accessStorage(recipient, key) == .cold) {
                    if (!frame.trackGas(cold_storage_access_gas)) return null;
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

test "SLOAD cold storage access gas comes from the exact spec" {
    const spec = evmz.eth.frontier.extend(.{
        .storage = .{ .sload_cold_access_gas = .{ .replace = 11 } },
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.SLOAD)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try frame.frame.stack.push(0);
    try bind(spec).sload(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_989), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_loads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "SSTORE gas and state gas come from the exact spec" {
    const semantics = struct {
        fn sstoreAccessGas(_: AccountAccessStatus) ?i64 {
            return null;
        }

        fn sstoreGas(_: StorageStatus) evmz.execution.StorageGas {
            return .{ .cost = 7, .refund = 3 };
        }

        fn sstoreStateGas(_: StorageStatus) evmz.execution.StorageStateGas {
            return .{ .charge = 5 };
        }
    };
    const spec = evmz.eth.frontier.extend(.{
        .storage = .{
            .sstoreAccessGas = semantics.sstoreAccessGas,
            .sstoreGas = semantics.sstoreGas,
            .sstoreStateGas = semantics.sstoreStateGas,
        },
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas_reservoir = 5;
    const code = [_]u8{@intFromEnum(evmz.Opcode.SSTORE)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try frame.frame.stack.push(42);
    try frame.frame.stack.push(0);
    try bind(spec).sstore(frame.frame);

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

    const Berlin = evmz.Vm(evmz.eth.berlin);
    var frame = try Berlin.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
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

    const Amsterdam = evmz.Vm(evmz.eth.amsterdam);
    var frame = try Amsterdam.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
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

    const Amsterdam = evmz.Vm(evmz.eth.amsterdam);
    var frame = try Amsterdam.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
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

    const Osaka = evmz.Vm(evmz.eth.osaka);
    var frame = try Osaka.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
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

    const Berlin = evmz.Vm(evmz.eth.berlin);
    var frame = try Berlin.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 1), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_loads);
}
