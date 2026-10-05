const std = @import("std");
const evmz = @import("../evm.zig");
const t = evmz.t;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Step = evmz.execution.NativeContractStep;
const Call = evmz.execution.NativeContractCall;
const ChildRequest = evmz.execution.NativeContractChildRequest;
const Host = evmz.Host;

/// One native type for every probe, so they share one executor instantiation.
const Native = union(enum) {
    static: *StaticProbe,
    value: *ValueProbe,
    guard: *GuardProbe,
    credit: *CreditProbe,
    priced: *PricedProbe,
    output: *OutputProbe,
    balance: *BalanceProbe,
    depth: *DepthProbe,
    sstore: *SstoreLike,
    stipend: *StipendProbe,

    const address = evmz.addr(0x1234);
    pub fn active(candidate: evmz.Address) bool {
        return candidate.eql(Native.address);
    }
    pub fn execute(self: *Native, ctx: anytype, call: Call) !Step {
        return switch (self.*) {
            inline else => |probe| probe.execute(ctx, call),
        };
    }
};
const Latest = t.CustomVm(.latest, .{ .native_contract = Native }).?;
const sender = evmz.addr(0xaaaa);
const child_address = evmz.addr(0xbbbb);
const context: evmz.execution.ExecutionContext = .{
    .chain = .{ .chain_id = 1 },
    .transaction = .{ .origin = sender },
};

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

/// A value-free CALL of `target` with all remaining gas.
fn childCall(call: Call, target: evmz.Address) Step {
    return .{ .call = .{
        .kind = .call,
        .recipient = target,
        .code_address = target,
        .sender = call.message.recipient,
        .gas = call.ledger.gas_left,
    } };
}

const StaticProbe = struct {
    action: enum { storage, fused_storage, transient, log, destruction, credit, debit, value_call },
    caught: bool = false,
    entries: u8 = 0,

    fn effect(self: *StaticProbe, ctx: anytype) !void {
        const address = Native.address;
        switch (self.action) {
            .storage => _ = try ctx.setStorage(address, 0, 1),
            .fused_storage => _ = try ctx.storeStorage(address, 0, 1),
            .transient => try ctx.setTransientStorage(address, 0, 1),
            .log => try ctx.emitLog(.{ .address = address, .topics = &.{1}, .data = &.{2} }),
            .destruction => _ = try ctx.selfDestruct(address, child_address),
            .credit => try ctx.addBalance(address, 0),
            .debit => _ = try ctx.subtractBalance(address, 0),
            .value_call => {},
        }
    }

    fn execute(self: *StaticProbe, ctx: anytype, call: Call) !Step {
        self.entries += 1;
        if (!call.ledger.trackStateGas(8)) return .{ .done = .{} };
        self.effect(ctx) catch |err| {
            if (err != error.StaticModeViolation) return err;
            self.caught = true;
        };
        call.ledger.gas_refund = 13;
        // Swallowing the error and requesting a child must still fail this scope.
        var request = childCall(call, child_address);
        if (self.action == .value_call) request.call.value = 1;
        return request;
    }
};

test "native static violations remain terminal after callback catches them" {
    inline for (std.meta.tags(@FieldType(StaticProbe, "action"))) |action| {
        var probe = StaticProbe{ .action = action };
        var native: Native = .{ .static = &probe };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, Native.address, .{ .balance = 10 });
        var msg = message(100, 5);
        msg.is_static = true;
        const result = try invoke(&executor, msg);
        try equal(action != .value_call, probe.caught);
        try equal(@as(u8, 1), probe.entries);
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
    kind: ChildRequest.Kind,
    fn execute(self: *ValueProbe, _: anytype, call: Call) !Step {
        if (call.child) |child| return .{ .done = .{
            .status = child.status(),
            .output_data = try call.allocator.dupe(u8, child.output_data),
        } };
        var request = childCall(call, child_address);
        request.call.kind = self.kind;
        request.call.recipient = call.message.recipient;
        request.call.value = call.message.value;
        return request;
    }
};

test "native static CALLCODE and DELEGATECALL preserve nonzero CALLVALUE" {
    inline for (.{ ChildRequest.Kind.callcode, ChildRequest.Kind.delegatecall }) |kind| {
        var probe = ValueProbe{ .kind = kind };
        var native: Native = .{ .value = &probe };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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

const GuardProbe = struct {
    nested: bool = false,
    fail_child_service: bool = false,
    fn execute(self: *GuardProbe, ctx: anytype, call: Call) !Step {
        if (call.message.depth != 0) {
            self.nested = true;
            if (self.fail_child_service) return error.ChildServiceFailed;
            _ = try ctx.setStorage(Native.address, 1, 9);
            return .{ .done = .{} };
        }
        if (call.child == null) {
            var request = childCall(call, child_address);
            request.call.kind = .staticcall;
            return request;
        }
        _ = try ctx.setStorage(Native.address, 0, 1);
        return .{ .done = .{} };
    }
};

test "native guard is per entry across bytecode reentry; service errors abort" {
    for ([_]bool{ false, true }) |is_static| {
        for ([_]bool{ false, true }) |fail_child_service| {
            var probe = GuardProbe{ .fail_child_service = fail_child_service };
            var native: Native = .{ .guard = &probe };
            var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
            defer executor.deinit();
            try t.seedExecutorAccount(&executor, child_address, .{ .code = &relay_code });
            var msg = message(100_000, 0);
            msg.is_static = is_static;
            if (fail_child_service) {
                try std.testing.expectError(error.ChildServiceFailed, invoke(&executor, msg));
            } else {
                const result = try invoke(&executor, msg);
                try equal(if (is_static) evmz.execution.Status.invalid else .success, result.status());
                try equal(@as(u256, if (is_static) 0 else 1), try executor.getStorage(Native.address, 0));
            }
            try expect(probe.nested);
            try equal(@as(u256, 0), try executor.getStorage(Native.address, 1));
            try equal(@as(usize, 0), executor.native_frames.items.len);
        }
    }
}

const CreditProbe = struct {
    credit: i64,
    completion: evmz.execution.Status = .success,
    fn execute(self: *CreditProbe, ctx: anytype, call: Call) !Step {
        if (call.child != null) return .{ .done = .{
            .status = self.completion,
            .output_data = try call.allocator.dupe(u8, &.{0xaa}),
        } };
        _ = try ctx.setStorage(Native.address, call.message.depth, 1);
        if (call.message.depth != 0) {
            call.ledger.refillStateGas(self.credit);
            call.ledger.gas_refund = 11;
            return .{ .done = .{} };
        }
        if (!call.ledger.trackStateGas(10)) return .{ .done = .{} };
        // Retain half the regular gas so pass-through child results cannot work.
        var request = childCall(call, child_address);
        request.call.gas = @divTrunc(call.ledger.gas_left, 2);
        return request;
    }
};

test "native bytecode native settlement repays spill and unwinds completion failure" {
    var baseline_gas: i64 = 0;
    for ([_]i64{ 0, 7 }) |credit| {
        inline for (std.meta.tags(evmz.execution.Status)) |completion| {
            var probe = CreditProbe{ .credit = credit, .completion = completion };
            var native: Native = .{ .credit = &probe };
            var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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

const PricedProbe = struct {
    fn execute(_: *PricedProbe, ctx: anytype, call: Call) !Step {
        const ledger = call.ledger;
        const storage = @TypeOf(ctx).spec.storage;
        const status = try ctx.setStorage(call.message.recipient, 0, 42);
        const regular = storage.sstoreGas(status);
        const state = storage.sstoreStateGas(status);
        if (!ledger.trackGas(regular.cost)) return .{ .done = .{} };
        ledger.gas_refund += regular.refund;
        if (!ledger.trackStateGas(state.charge)) return .{ .done = .{} };
        ledger.refillStateGas(state.refund);
        return .{ .done = .{} };
    }
};

test "native pricing uses exact custom spec with empty and nonempty reservoir" {
    inline for (.{ @as(i64, 0), 8, 12 }) |charge| {
        const Vm = t.CustomVm(.latest, .{
            .native_contract = Native,
            .storage = .{ .sstoreGas = Tariff(charge).regular, .sstoreStateGas = Tariff(charge).state },
        }).?;
        for ([_]i64{ 0, 5, 20 }) |reservoir| {
            var runtime: PricedProbe = .{};
            var native: Native = .{ .priced = &runtime };
            var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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
    var runtime: PricedProbe = .{};
    var native: Native = .{ .priced = &runtime };
    var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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
    fn execute(self: *OutputProbe, ctx: anytype, call: Call) !Step {
        const child = call.child orelse {
            var request = childCall(call, evmz.addr(4));
            request.call.input_data = &.{ 0xaa, 0xbb };
            return request;
        };
        try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, child.output_data);
        if (self.violation) _ = try ctx.setStorage(Native.address, 0, 1);
        if (self.completion == .out_of_gas) {
            try expect(!call.ledger.trackGas(call.ledger.gas_left + 1));
            return .{ .done = .{} };
        }
        return .{ .done = .{ .status = self.completion } };
    }
};

test "native empty completion clears retained child output including faults" {
    inline for (std.meta.tags(evmz.execution.Status)) |completion| {
        var probe = OutputProbe{ .completion = completion };
        var native: Native = .{ .output = &probe };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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

/// Arc-style issuance built from the context: mint or burn, then the chain's
/// own log only when the balance moved.
const BalanceProbe = struct {
    kind: enum { credit, debit },
    amount: u256 = 3,
    completion: evmz.execution.Status = .success,
    applied: ?bool = null,

    fn execute(self: *BalanceProbe, ctx: anytype, _: Call) !Step {
        const applied = switch (self.kind) {
            .credit => if (ctx.addBalance(Native.address, self.amount)) true else |err| switch (err) {
                error.BalanceOverflow => false,
                else => return err,
            },
            .debit => try ctx.subtractBalance(Native.address, self.amount),
        };
        self.applied = applied;
        if (applied) try ctx.emitLog(.{ .address = Native.address, .topics = &.{9}, .data = &.{1} });
        return .{ .done = .{ .status = self.completion } };
    }
};

test "native issuance journals balance and log with frame rollback" {
    inline for (.{ .credit, .debit }) |kind| {
        for ([_]bool{ false, true }) |native_revert| {
            for ([_]bool{ false, true }) |parent_revert| {
                var probe = BalanceProbe{ .kind = kind, .completion = if (native_revert) .revert else .success };
                var native: Native = .{ .balance = &probe };
                var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
                defer executor.deinit();
                try t.seedExecutorAccount(&executor, Native.address, .{ .balance = 10 });
                const parent_code = relay_code[0 .. relay_code.len - 1].* ++ t.bytecode(.{ .PUSH0, .PUSH0, .REVERT });
                try t.seedExecutorAccount(&executor, child_address, .{ .code = if (parent_revert) &parent_code else &relay_code });
                var msg = message(100_000, 0);
                msg.recipient = child_address;
                msg.code_address = child_address;
                _ = try invoke(&executor, msg);
                try expect(probe.applied.?);
                const rolled_back = native_revert or parent_revert;
                try equal(@as(u256, if (rolled_back) 10 else if (kind == .credit) 13 else 7), try executor.getBalance(Native.address));
                try equal(@as(usize, if (rolled_back) 0 else 1), executor.logView().len());
            }
        }
    }
}

test "native rejected issuance leaves the balance unchanged" {
    const cases = [_]struct { probe: BalanceProbe, balance: u256 }{
        .{ .probe = .{ .kind = .credit, .amount = 1 }, .balance = std.math.maxInt(u256) },
        .{ .probe = .{ .kind = .debit, .amount = 3 }, .balance = 2 },
        .{ .probe = .{ .kind = .credit, .amount = 0 }, .balance = 2 },
    };
    for (cases) |case| {
        var probe = case.probe;
        var native: Native = .{ .balance = &probe };
        var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
        defer executor.deinit();
        try t.seedExecutorAccount(&executor, Native.address, .{ .balance = case.balance });
        const result = try invoke(&executor, message(1000, 0));
        try equal(.success, result.status());
        try equal(probe.amount == 0, probe.applied.?);
        try equal(case.balance, try executor.getBalance(Native.address));
        try equal(@as(usize, @intFromBool(probe.applied.?)), executor.logView().len());
    }
}

const DepthProbe = struct {
    alternating: bool,
    revert_root: bool,
    max_depth: u16 = 0,
    stack_low: usize = std.math.maxInt(usize),
    stack_high: usize = 0,

    fn execute(self: *DepthProbe, ctx: anytype, call: Call) !Step {
        var marker: u8 = 0;
        self.stack_low = @min(self.stack_low, @intFromPtr(&marker));
        self.stack_high = @max(self.stack_high, @intFromPtr(&marker));
        self.max_depth = @max(self.max_depth, call.message.depth);
        std.mem.doNotOptimizeAway(&marker);
        const child = call.child orelse
            return childCall(call, if (self.alternating) child_address else Native.address);
        if (call.message.depth == Host.max_call_depth) {
            try equal(.call_depth_exceeded, child.terminalCause());
            _ = try ctx.setStorage(Native.address, 0, 1);
        }
        return .{ .done = .{ .status = if (call.message.depth == 0 and self.revert_root) .revert else .success } };
    }
};

test "native max depth reenters at one stack depth and unwinds" {
    for ([_]bool{ false, true }) |alternating| {
        for ([_]bool{ false, true }) |revert_root| {
            var probe = DepthProbe{ .alternating = alternating, .revert_root = revert_root };
            var native: Native = .{ .depth = &probe };
            var executor = Latest.Executor.init(std.testing.allocator, .{ .native_contract = &native });
            defer executor.deinit();
            try t.seedExecutorAccount(&executor, child_address, .{ .code = &relay_code });
            const result = try invoke(&executor, message(1_000_000_000_000, 0));
            try equal(if (revert_root) evmz.execution.Status.revert else .success, result.status());
            try equal(Host.max_call_depth, probe.max_depth);
            try equal(@as(u256, if (revert_root) 0 else 1), try executor.getStorage(Native.address, 0));
            // Every entry is made from the runtime loop, never from a parent entry.
            try equal(probe.stack_low, probe.stack_high);
            try equal(@as(usize, 0), executor.native_frames.items.len);
        }
    }
}

fn addedStateGasFive(status: evmz.execution.StorageStatus) evmz.execution.StorageStateGas {
    return .{ .charge = if (status == .added) 5 else 0 };
}

fn addedStateGasNine(status: evmz.execution.StorageStatus) evmz.execution.StorageStateGas {
    return .{ .charge = if (status == .added) 9 else 0 };
}

// An SSTORE-like native write priced only through the context's spec, never a fork.
const SstoreLike = struct {
    fn execute(_: *SstoreLike, ctx: anytype, call: Call) !Step {
        const ledger = call.ledger;
        const rules = @TypeOf(ctx).spec.storage;
        const stored = try ctx.storeStorage(Native.address, 0, 1);
        if (!ledger.trackGas(rules.sstoreAccessGas(stored.access_status) orelse 0)) return .{ .done = .{} };
        const cost = rules.sstoreGas(stored.storage_status);
        if (!ledger.trackGas(cost.cost)) return .{ .done = .{} };
        ledger.gas_refund += cost.refund;
        const state_gas = rules.sstoreStateGas(stored.storage_status);
        if (!ledger.trackStateGas(state_gas.charge)) return .{ .done = .{} };
        ledger.refillStateGas(state_gas.refund);
        return .{ .done = .{} };
    }
};

test "native context spec follows the executor's spec, not a builtin fork" {
    try expect(addedStateGasFive(.added).charge != addedStateGasNine(.added).charge);
    inline for (.{ addedStateGasFive, addedStateGasNine }) |sstoreStateGas| {
        const Vm = t.CustomVm(.latest, .{
            .native_contract = Native,
            .storage = .{ .sstoreStateGas = sstoreStateGas },
        }).?;
        var probe: SstoreLike = .{};
        var native: Native = .{ .sstore = &probe };
        var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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

const StipendProbe = struct {
    fn execute(_: *StipendProbe, ctx: anytype, call: Call) !Step {
        if (call.child != null) return .{ .done = .{} };
        const rules = @TypeOf(ctx).spec.call;
        if (!call.ledger.trackGas(rules.base_gas + rules.value_transfer_gas)) return .{ .done = .{} };
        // CALL(0, child_address, 1, ...); the executor adds the stipend.
        var request = childCall(call, child_address);
        request.call.value = 1;
        request.call.gas = 0;
        return request;
    }
};

test "native value call returns a custom stipend like bytecode CALL" {
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
            var probe: StipendProbe = .{};
            var native: Native = .{ .stipend = &probe };
            var executor = Vm.Executor.init(std.testing.allocator, .{ .native_contract = &native });
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
