const std = @import("std");
const evmz = @import("../evm.zig");
const t = evmz.t;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Result = evmz.execution.NativeContractResult;
const Call = evmz.execution.NativeContractCall;
const Host = evmz.Host;

const Native = struct {
    const address = evmz.addr(0x1234);
    pub fn active(candidate: evmz.Address) bool {
        return candidate.eql(Native.address);
    }
};
const Latest = t.CustomVm(.latest, .{ .native_contract = Native }).?;
const sender = evmz.addr(0xaaaa);
const child_address = evmz.addr(0xbbbb);
const context: evmz.execution.ExecutionContext = .{
    .chain = .{ .chain_id = 1 },
    .transaction = .{ .origin = sender },
};

fn service(ptr: anytype, comptime callback: anytype) evmz.execution.NativeContractRuntime {
    return .{ .ptr = ptr, .vtable = &.{ .execute = callback } };
}

fn message(gas: i64, reservoir: i64) Host.Message {
    return .{
        .depth = 0,
        .kind = .call,
        .gas = gas,
        .gas_reservoir = reservoir,
        .recipient = Native.address,
        .code_address = Native.address,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
    };
}

fn invoke(executor: anytype, msg: Host.Message) !Host.Result {
    try executor.beginTransaction(context, sender, msg.recipient);
    errdefer executor.discardStateTransition();
    var host = executor.host();
    const result = try host.call(msg);
    try executor.commitTransaction();
    return result;
}

fn childMessage(call: Call, ledger: Result, target: evmz.Address) Host.Message {
    var msg = call.message.*;
    msg.depth += 1;
    msg.kind = .call;
    msg.gas = ledger.gas_left;
    msg.gas_reservoir = ledger.gas_reservoir;
    msg.recipient = target;
    msg.code_address = target;
    msg.sender = call.message.recipient;
    msg.value = 0;
    return msg;
}

const StaticProbe = struct {
    action: enum { storage, fused_storage, transient, log, destruction, credit, debit, create, create2, value_call, missing_static },
    caught: bool = false,
    blocked_after: bool = false,

    fn effect(self: *StaticProbe, call: Call) !void {
        const address: evmz.AddressWord = .fromAddress(Native.address);
        switch (self.action) {
            .storage => _ = try call.host.setStorage(address, 0, 1),
            .fused_storage => _ = try call.host.storeStorage(address, 0, 1),
            .transient => try call.host.setTransientStorage(address, 0, 1),
            .log => try call.host.emitLog(.{ .address = Native.address, .topics = &.{1}, .data = &.{2} }),
            .destruction => _ = try call.host.selfDestruct(address, .fromAddress(child_address)),
            .credit, .debit => _ = try call.host.changeBalance(.{
                .address = address,
                .kind = if (self.action == .credit) .credit else .debit,
                .amount = 0,
            }),
            else => {
                var msg = childMessage(call, Result.init(call.message), child_address);
                switch (self.action) {
                    .create => msg.kind = .create,
                    .create2 => msg.kind = .create2,
                    .value_call => msg.value = 1,
                    .missing_static => msg.is_static = false,
                    else => unreachable,
                }
                _ = try call.host.call(msg);
            },
        }
    }

    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *StaticProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        if (!ledger.trackStateGas(8)) return ledger;
        self.effect(call) catch |err| {
            if (err != error.StaticModeViolation) return err;
            self.caught = true;
        };
        try std.testing.expectError(error.StaticModeViolation, call.host.call(childMessage(call, ledger, child_address)));
        self.blocked_after = true;
        ledger.output_data = try call.allocator.dupe(u8, &.{0xff});
        ledger.gas_refund = 13;
        // Even swallowing the error and reporting success must fail this scope.
        return ledger;
    }
};

test "native static violations remain terminal after callback catches them" {
    inline for (std.meta.tags(@FieldType(StaticProbe, "action"))) |action| {
        var probe = StaticProbe{ .action = action };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, StaticProbe.execute) });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, Native.address, .{ .balance = 10 });
        var msg = message(100, 5);
        msg.is_static = true;
        const result = try invoke(&executor, msg);
        try expect(probe.caught and probe.blocked_after);
        try equal(.invalid, result.status());
        try equal(.write_protection, result.terminalCause());
        try equal(@as(i64, 0), result.gas_left);
        try equal(@as(i64, 5), result.gas_reservoir);
        try equal(@as(i64, 0), result.state_gas_spent);
        try equal(@as(i64, 0), result.state_gas_from_gas_left);
        try equal(@as(i64, 0), result.gas_refund);
        try equal(@as(usize, 0), result.output_data.len);
        try equal(@as(u256, 0), try executor.getStorage(Native.address, 0));
        try equal(@as(u256, 10), try executor.getBalance(Native.address));
        try equal(@as(u256, 0), try executor.getBalance(child_address));
        try equal(@as(u64, 0), try executor.state.getNonce(.fromAddress(Native.address)));
        try equal(@as(usize, 0), executor.logView().len());
    }
}

const ValueProbe = struct {
    kind: Host.CallKind,
    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *ValueProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        var msg = childMessage(call, ledger, child_address);
        msg.kind = self.kind;
        msg.recipient = call.message.recipient;
        msg.value = call.message.value;
        const child = try call.host.call(msg);
        if (!ledger.settleChild(msg.gas, 0, child)) return ledger;
        ledger.status = child.status();
        ledger.output_data = try call.allocator.dupe(u8, child.output_data);
        return ledger;
    }
};

test "native static CALLCODE and DELEGATECALL preserve nonzero CALLVALUE" {
    inline for (.{ Host.CallKind.callcode, Host.CallKind.delegatecall }) |kind| {
        var probe = ValueProbe{ .kind = kind };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, ValueProbe.execute) });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, Native.address, .{ .balance = 7 });
        try t.seedExecutorAccount(&executor, child_address, .{ .code = &t.bytecode(.{ .CALLVALUE, .PUSH0, .MSTORE, .PUSH1, 32, .PUSH0, .RETURN }) });
        var msg = message(1000, 0);
        msg.kind = .callcode;
        msg.value = 7;
        msg.is_static = true;
        const result = try invoke(&executor, msg);
        try equal(.success, result.status());
        try equal(@as(u256, 7), std.mem.readInt(u256, result.output_data[0..32], .big));
        try equal(@as(u256, 7), try executor.getBalance(Native.address));
        try equal(@as(u256, 0), try executor.getBalance(child_address));
    }
}

// A bytecode frame enters native again, then survives its failure.
const relay_code = t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH2, 0x12, 0x34, .GAS, .CALL, .POP, .STOP });

const ContextProbe = struct {
    nested: bool = false,
    fail_child_service: bool = false,
    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *ContextProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        if (call.message.depth != 0) {
            self.nested = true;
            if (self.fail_child_service) return error.ChildServiceFailed;
            _ = try call.host.setStorage(.fromAddress(Native.address), 1, 9);
            return ledger;
        }
        var msg = childMessage(call, ledger, child_address);
        msg.is_static = true;
        const child: ?Host.Result = call.host.call(msg) catch |err| blk: {
            if (err != error.ChildServiceFailed) return err;
            break :blk @as(?Host.Result, null);
        };
        if (child) |result| if (!ledger.settleChild(msg.gas, 0, result)) return ledger;
        _ = try call.host.setStorage(.fromAddress(Native.address), 0, 1);
        return ledger;
    }
};

test "native context restores across bytecode reentry and service errors" {
    for ([_]bool{ false, true }) |is_static| {
        for ([_]bool{ false, true }) |fail_child_service| {
            var probe = ContextProbe{ .fail_child_service = fail_child_service };
            var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, ContextProbe.execute) });
            defer executor.deinit();
            try t.seedExecutorAccount(&executor, child_address, .{ .code = &relay_code });
            var msg = message(100_000, 0);
            msg.is_static = is_static;
            const result = try invoke(&executor, msg);
            try expect(probe.nested);
            try equal(if (is_static) evmz.execution.Status.invalid else .success, result.status());
            try equal(@as(u256, if (is_static) 0 else 1), try executor.getStorage(Native.address, 0));
            try equal(@as(u256, 0), try executor.getStorage(Native.address, 1));
            try expect(executor.native_context == null);
        }
    }
}

const CreditProbe = struct {
    credit: i64,
    completion: evmz.execution.Status = .success,
    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *CreditProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        _ = try call.host.setStorage(.fromAddress(Native.address), call.message.depth, 1);
        if (call.message.depth != 0) {
            ledger.refillStateGas(self.credit);
            ledger.gas_refund = 11;
            return ledger;
        }
        if (!ledger.trackStateGas(10)) return ledger;
        // Retain half the regular gas so pass-through child results cannot work.
        var msg = childMessage(call, ledger, child_address);
        msg.gas = @divTrunc(ledger.gas_left, 2);
        const child = try call.host.call(msg);
        if (!ledger.settleChild(msg.gas, 0, child)) return ledger;
        ledger.output_data = try call.allocator.dupe(u8, &.{0xaa});
        ledger.status = self.completion;
        return ledger;
    }
};

test "native bytecode native settlement repays spill and unwinds completion failure" {
    var baseline_gas: i64 = 0;
    for ([_]i64{ 0, 7 }) |credit| {
        inline for (std.meta.tags(evmz.execution.Status)) |completion| {
            var probe = CreditProbe{ .credit = credit, .completion = completion };
            var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, CreditProbe.execute) });
            defer executor.deinit();
            try t.seedExecutorAccount(&executor, child_address, .{ .code = &relay_code });
            const result = try invoke(&executor, message(100_000, 0));
            try equal(completion, result.status());
            if (completion == .success) {
                if (credit == 0) baseline_gas = result.gas_left;
                try equal(baseline_gas + credit, result.gas_left);
                try equal(10 - credit, result.state_gas_spent);
                try equal(10 - credit, result.state_gas_from_gas_left);
                try equal(@as(i64, 11), result.gas_refund);
            } else {
                try equal(@as(i64, 0), result.state_gas_spent);
                try equal(@as(i64, 0), result.state_gas_from_gas_left);
                try equal(@as(i64, 0), result.gas_refund);
                if (completion == .revert) {
                    try equal(baseline_gas + 10, result.gas_left);
                } else {
                    try equal(@as(i64, 0), result.gas_left);
                    try equal(@as(usize, 0), result.output_data.len);
                }
            }
            try equal(@as(i64, 0), result.gas_reservoir);
            const stored: u256 = if (completion == .success) 1 else 0;
            try equal(stored, try executor.getStorage(Native.address, 0));
            try equal(stored, try executor.getStorage(Native.address, 2));
        }
    }
}

fn Tariff(comptime charge: i64) type {
    return struct {
        fn regular(_: evmz.execution.StorageStatus) evmz.execution.StorageGas {
            return .{ .cost = 7, .refund = 3 };
        }
        fn state(_: evmz.execution.StorageStatus) evmz.execution.StorageStateGas {
            return .{ .charge = charge };
        }
    };
}

fn PricedRuntime(comptime spec: evmz.Spec) type {
    return struct {
        fn execute(_: *anyopaque, call: Call) !Result {
            var ledger = Result.init(call.message);
            const status = try call.host.setStorage(.fromAddress(call.message.recipient), 0, 42);
            const regular = spec.storage.sstoreGas(status);
            const state = spec.storage.sstoreStateGas(status);
            if (!ledger.trackGas(regular.cost)) return ledger;
            ledger.gas_refund += regular.refund;
            if (!ledger.trackStateGas(state.charge)) return ledger;
            ledger.refillStateGas(state.refund);
            return ledger;
        }
    };
}

test "native pricing uses exact custom spec with empty and nonempty reservoir" {
    inline for (.{ @as(i64, 0), 8, 12 }) |charge| {
        const Vm = t.CustomVm(.latest, .{
            .native_contract = Native,
            .storage = .{ .sstoreGas = Tariff(charge).regular, .sstoreStateGas = Tariff(charge).state },
        }).?;
        const Runtime = PricedRuntime(Vm.spec);
        for ([_]i64{ 0, 5, 20 }) |reservoir| {
            var runtime = Runtime{};
            var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&runtime, Runtime.execute) });
            defer executor.deinit();
            const result = try invoke(&executor, message(100, reservoir));
            try equal(.success, result.status());
            try equal(100 - 7 - @max(charge - reservoir, 0), result.gas_left);
            try equal(@max(reservoir - charge, 0), result.gas_reservoir);
            try equal(charge, result.state_gas_spent);
            try equal(@max(charge - reservoir, 0), result.state_gas_from_gas_left);
            try equal(@as(i64, 3), result.gas_refund);
        }
    }
}

test "native state gas OOG preserves the incoming reservoir and rolls back writes" {
    const Vm = t.CustomVm(.latest, .{
        .native_contract = Native,
        .storage = .{ .sstoreGas = Tariff(12).regular, .sstoreStateGas = Tariff(12).state },
    }).?;
    const Runtime = PricedRuntime(Vm.spec);
    var runtime = Runtime{};
    var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&runtime, Runtime.execute) });
    defer executor.deinit();
    const result = try invoke(&executor, message(10, 5));
    try equal(.out_of_gas, result.status());
    try equal(@as(i64, 0), result.gas_left);
    try equal(@as(i64, 5), result.gas_reservoir);
    try equal(@as(i64, 0), result.gas_refund);
    try equal(@as(i64, 0), result.state_gas_spent);
    try equal(@as(u256, 0), try executor.getStorage(Native.address, 0));
}

test "native targets are rejected before root system execution" {
    var executor = Latest.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    for ([_]evmz.Address{ Native.address, evmz.addr(4) }) |address| {
        try std.testing.expectError(error.NativeSystemCallUnsupported, executor.executeSystemCall(context, sender, address, &.{}, .legacy(100)));
        try expect(executor.scope_root == null);
    }
}

const OutputProbe = struct {
    completion: evmz.execution.Status,
    violation: bool = false,
    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *OutputProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        var msg = childMessage(call, ledger, evmz.addr(4));
        msg.input_data = &.{ 0xaa, 0xbb };
        const child = try call.host.call(msg);
        if (!ledger.settleChild(msg.gas, 0, child)) return ledger;
        try std.testing.expectEqualSlices(u8, msg.input_data, child.output_data);
        if (self.violation) _ = try call.host.setStorage(.fromAddress(Native.address), 0, 1);
        if (self.completion == .out_of_gas) {
            try expect(!ledger.trackGas(ledger.gas_left + 1));
            return ledger;
        }
        ledger.status = self.completion;
        return ledger;
    }
};

test "native empty completion clears retained child output including faults" {
    inline for (std.meta.tags(evmz.execution.Status)) |completion| {
        var probe = OutputProbe{ .completion = completion };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, OutputProbe.execute) });
        defer executor.deinit();
        const result = try invoke(&executor, message(1000, 0));
        try equal(completion, result.status());
        try equal(@as(usize, 0), result.output_data.len);
        try equal(@as(usize, 0), executor.lastOutputData().len);
        probe.violation = true;
        var msg = message(1000, 0);
        msg.is_static = true;
        const fault = try invoke(&executor, msg);
        try equal(.write_protection, fault.terminalCause());
        try equal(@as(usize, 0), executor.lastOutputData().len);
    }
}

test "native address delegation still selects bytecode for system roots" {
    var executor = Latest.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    const code = [_]u8{ 0xef, 0x01, 0x00 } ++ child_address.bytes;
    try t.seedExecutorAccount(&executor, Native.address, .{ .code = &code });
    try t.seedExecutorAccount(&executor, child_address, .{ .code = &t.bytecode(.{.STOP}) });
    const result = try executor.executeSystemCall(context, sender, Native.address, &.{}, .legacy(100));
    try equal(.success, result.status());
}

const BalanceProbe = struct {
    change: Host.BalanceChange,
    completion: evmz.execution.Status = .success,
    outcome: ?Host.BalanceChangeStatus = null,
    log_error: bool = false,

    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *BalanceProbe = @ptrCast(@alignCast(ptr));
        var ledger = Result.init(call.message);
        self.outcome = call.host.changeBalance(self.change) catch |err| blk: {
            if (err != error.TooManyLogTopics) return err;
            self.log_error = true;
            break :blk null;
        };
        ledger.status = self.completion;
        return ledger;
    }
};

test "native balance credit and debit journal issuance logs atomically" {
    inline for (.{ .credit, .debit }) |kind| {
        for ([_]bool{ false, true }) |native_revert| {
            for ([_]bool{ false, true }) |parent_revert| {
                var probe = BalanceProbe{
                    .change = .{
                        .address = .fromAddress(Native.address),
                        .kind = kind,
                        .amount = 3,
                        .event_log = .{ .address = Native.address, .topics = &.{9}, .data = &.{1} },
                    },
                    .completion = if (native_revert) .revert else .success,
                };
                var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, BalanceProbe.execute) });
                defer executor.deinit();
                try t.seedExecutorAccount(&executor, Native.address, .{ .balance = 10 });
                const parent_code = relay_code[0 .. relay_code.len - 1].* ++ t.bytecode(.{ .PUSH0, .PUSH0, .REVERT });
                try t.seedExecutorAccount(&executor, child_address, .{ .code = if (parent_revert) &parent_code else &relay_code });
                var msg = message(100_000, 0);
                msg.recipient = child_address;
                msg.code_address = child_address;
                _ = try invoke(&executor, msg);
                try equal(.applied, probe.outcome.?);
                const rolled_back = native_revert or parent_revert;
                try equal(@as(u256, if (rolled_back) 10 else if (kind == .credit) 13 else 7), try executor.getBalance(Native.address));
                try equal(@as(usize, if (rolled_back) 0 else 1), executor.logView().len());
            }
        }
    }
}

test "native rejected balance effects leave no partial balance or log" {
    const cases = [_]struct {
        kind: @FieldType(Host.BalanceChange, "kind"),
        balance: u256,
        amount: u256,
        status: ?Host.BalanceChangeStatus,
        bad_log: bool = false,
    }{
        .{ .kind = .credit, .balance = std.math.maxInt(u256), .amount = 1, .status = .overflow },
        .{ .kind = .debit, .balance = 2, .amount = 3, .status = .insufficient_balance },
        .{ .kind = .credit, .balance = 2, .amount = 3, .status = null, .bad_log = true },
        .{ .kind = .debit, .balance = 5, .amount = 3, .status = null, .bad_log = true },
        .{ .kind = .credit, .balance = 2, .amount = 0, .status = .applied },
    };
    for (cases) |case| {
        var probe = BalanceProbe{ .change = .{
            .address = .fromAddress(Native.address),
            .kind = case.kind,
            .amount = case.amount,
            .event_log = .{
                .address = Native.address,
                .topics = if (case.bad_log) &.{ 1, 2, 3, 4, 5 } else &.{1},
                .data = &.{},
            },
        } };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, BalanceProbe.execute) });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, Native.address, .{ .balance = case.balance });
        const result = try invoke(&executor, message(1000, 0));
        try equal(.success, result.status());
        try equal(case.status, probe.outcome);
        try equal(case.bad_log, probe.log_error);
        try equal(case.balance, try executor.getBalance(Native.address));
        try equal(@as(usize, if (case.status == .applied) 1 else 0), executor.logView().len());
    }
}

const DepthProbe = struct {
    alternating: bool,
    revert_root: bool,
    max_depth: u16 = 0,
    stack_low: usize = std.math.maxInt(usize),
    stack_high: usize = 0,
    error_value: ?anyerror = null,

    fn execute(ptr: *anyopaque, call: Call) !Result {
        const self: *DepthProbe = @ptrCast(@alignCast(ptr));
        var marker: u8 = 0;
        self.stack_low = @min(self.stack_low, @intFromPtr(&marker));
        self.stack_high = @max(self.stack_high, @intFromPtr(&marker));
        self.max_depth = @max(self.max_depth, call.message.depth);
        var ledger = Result.init(call.message);
        const target = if (self.alternating) child_address else Native.address;
        const msg = childMessage(call, ledger, target);
        const child = try call.host.call(msg);
        if (call.message.depth == Host.max_call_depth) {
            try equal(.call_depth_exceeded, child.terminalCause());
            _ = try call.host.setStorage(.fromAddress(Native.address), 0, 1);
        }
        if (!ledger.settleChild(msg.gas, 0, child)) return ledger;
        if (call.message.depth == 0 and self.revert_root) ledger.status = .revert;
        std.mem.doNotOptimizeAway(&marker);
        return ledger;
    }

    fn worker(self: *DepthProbe) void {
        self.run() catch |err| {
            self.error_value = err;
        };
    }

    fn run(self: *DepthProbe) !void {
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(self, execute) });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, child_address, .{ .code = &relay_code });
        const result = try invoke(&executor, message(1_000_000_000_000, 0));
        try equal(if (self.revert_root) evmz.execution.Status.revert else .success, result.status());
        try equal(Host.max_call_depth, self.max_depth);
        try equal(@as(u256, if (self.revert_root) 0 else 1), try executor.getStorage(Native.address, 0));
        try expect(executor.native_context == null);
    }
};

test "native max depth fits the declared thread stack and unwinds" {
    for ([_]bool{ false, true }) |alternating| {
        for ([_]bool{ false, true }) |revert_root| {
            var probe = DepthProbe{ .alternating = alternating, .revert_root = revert_root };
            const thread = try std.Thread.spawn(.{}, DepthProbe.worker, .{&probe});
            thread.join();
            if (probe.error_value) |err| return err;
            const span = probe.stack_high - probe.stack_low;
            try expect(span < std.Thread.SpawnConfig.default_stack_size);
            if (!revert_root) std.debug.print("native stack: mode={s} alternating={} depth={d} span={d} thread_stack={d}\n", .{
                @tagName(@import("builtin").mode), alternating, probe.max_depth, span, std.Thread.SpawnConfig.default_stack_size,
            });
        }
    }
}

fn addedStateGasFive(status: evmz.execution.StorageStatus) evmz.execution.StorageStateGas {
    return .{ .charge = if (status == .added) 5 else 0 };
}

fn addedStateGasNine(status: evmz.execution.StorageStatus) evmz.execution.StorageStateGas {
    return .{ .charge = if (status == .added) 9 else 0 };
}

// An SSTORE-like native write priced only through `call.rules`, never a fork.
const SstoreLike = struct {
    fn execute(_: *anyopaque, call: Call) !Result {
        var ledger = Result.init(call.message);
        const rules = call.rules.storage;
        const stored = try call.host.storeStorage(.fromAddress(Native.address), 0, 1);
        if (!ledger.trackGas(rules.sstoreAccessGas(stored.access_status) orelse 0)) return ledger;
        const cost = rules.sstoreGas(stored.storage_status);
        if (!ledger.trackGas(cost.cost)) return ledger;
        ledger.gas_refund += cost.refund;
        const state_gas = rules.sstoreStateGas(stored.storage_status);
        if (!ledger.trackStateGas(state_gas.charge)) return ledger;
        ledger.refillStateGas(state_gas.refund);
        return ledger;
    }
};

test "native rules follow the executor's spec, not a builtin fork" {
    try expect(addedStateGasFive(.added).charge != addedStateGasNine(.added).charge);
    inline for (.{ addedStateGasFive, addedStateGasNine }) |sstoreStateGas| {
        const Vm = t.CustomVm(.latest, .{
            .native_contract = Native,
            .storage = .{ .sstoreStateGas = sstoreStateGas },
        }).?;
        var probe: u8 = 0;
        var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, SstoreLike.execute) });
        defer executor.deinit();
        const result = try invoke(&executor, message(100_000, 1_000));
        try equal(.success, result.status());
        const state_gas = Vm.spec.storage.sstoreStateGas(.added);
        try equal(state_gas.charge, result.state_gas_spent);
        try equal(1_000 - state_gas.charge, result.gas_reservoir);
        try equal(@as(i64, 0), result.state_gas_from_gas_left);
        const access = Vm.spec.storage.sstoreAccessGas(.cold) orelse 0;
        const cost = Vm.spec.storage.sstoreGas(.added);
        try equal(100_000 - access - cost.cost, result.gas_left);
        try equal(cost.refund, result.gas_refund);
        try equal(@as(u256, 1), try executor.getStorage(Native.address, 0));
    }
}

test "native value call returns a custom stipend like bytecode CALL" {
    const Probe = struct {
        fn execute(_: *anyopaque, call: Call) !Result {
            var ledger = Result.init(call.message);
            const rules = call.rules.call;
            if (!ledger.trackGas(rules.base_gas + rules.value_transfer_gas)) return ledger;
            var msg = childMessage(call, ledger, child_address);
            msg.value = 1;
            // Mirror bytecode CALL: the stipend is credited to both sides.
            msg.gas += rules.value_stipend;
            ledger.gas_left += rules.value_stipend;
            _ = ledger.settleChild(msg.gas, 0, try call.host.call(msg));
            return ledger;
        }
    };
    const caller = evmz.addr(0xcccc);
    // CALL(0, child_address, 1, 0, 0, 0, 0)
    const code = [_]u8{ 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 0, 0x60, 1, 0x61, 0xbb, 0xbb, 0x60, 0, 0xf1, 0x00 };
    const stipends = [_]i64{ 0, 50_000 };
    // [stipend][native, bytecode]
    var gas_left: [2][2]i64 = undefined;
    inline for (stipends, 0..) |stipend, i| {
        const Vm = t.CustomVm(.latest, .{
            .native_contract = Native,
            .call = .{ .value_stipend = stipend, .value_transfer_gas = 0 },
        }).?;
        for ([_]evmz.Address{ Native.address, caller }, [_][]const u8{ &.{}, &code }, 0..) |recipient, bytes, j| {
            var probe: u8 = 0;
            var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract_runtime = service(&probe, Probe.execute) });
            defer executor.deinit();
            // An existing callee keeps account-creation charges out of the comparison.
            try t.seedExecutorAccount(&executor, child_address, .{ .balance = 1 });
            try t.seedExecutorAccount(&executor, recipient, .{ .balance = 1, .code = bytes });
            var msg = message(100_000, 0);
            msg.recipient = recipient;
            msg.code_address = recipient;
            const result = try invoke(&executor, msg);
            try equal(.success, result.status());
            gas_left[i][j] = result.gas_left;
        }
    }
    try expect(gas_left[1][0] > 100_000);
    for (0..2) |j| try equal(stipends[1] - stipends[0], gas_left[1][j] - gas_left[0][j]);
}
