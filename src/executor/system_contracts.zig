const std = @import("std");
const evmz = @import("../evm.zig");
const block_lifecycle = @import("../block/lifecycle.zig");
const system_prepared_code = @import("../eth/system_prepared_code.zig");

const Address = evmz.Address;
const ExecutionContext = evmz.execution.ExecutionContext;
const Interpreter = evmz.interpreter;
const InstrumentationMode = @import("instrumentation.zig").Mode;

pub const BeforeBlockContext = block_lifecycle.BeforeBlockContext;
pub const AfterTransactionContext = block_lifecycle.AfterTransactionContext;
pub const FinalizeBlockContext = block_lifecycle.FinalizeBlockContext;

/// Applies before-block system contract calls:
/// - EIP-4788 stores the parent beacon block root from Cancun onward.
/// - EIP-2935 stores the previous block hash from Prague onward.
pub fn applyBeforeBlock(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
) !void {
    try applySystemCalls(executor, execution_context, calls, .normal, {});
}

pub fn applyBeforeBlockObserved(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
    observer: anytype,
) !void {
    try applySystemCalls(executor, execution_context, calls, .observed, observer);
}

/// Execute a before-transaction batch inside the transaction program's outer
/// journal attempt. Each call keeps its own execution checkpoint, while any
/// later hook/payload/inclusion failure discards the complete attempt.
pub fn applyPreludeSystemCalls(
    prelude: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
) @TypeOf(prelude).Error!void {
    for (calls) |call| {
        try callSystemContractInPrelude(
            prelude,
            execution_context,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            call.require_code,
        );
    }
}

pub fn applyAfterTransaction(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
) !void {
    try applySystemCalls(executor, execution_context, calls, .normal, {});
}

pub fn applyAfterTransactionObserved(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
    observer: anytype,
) !void {
    try applySystemCalls(executor, execution_context, calls, .observed, observer);
}

pub fn applyAfterTransactionCaptured(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
    capture: *evmz.executor.CaptureContext,
    observer: anytype,
) !void {
    try applySystemCalls(executor, execution_context, calls, .{ .captured = capture }, observer);
}

pub fn applyFinalizeBlock(
    executor: anytype,
    execution_context: ExecutionContext,
    allocator: std.mem.Allocator,
    calls: []const block_lifecycle.FinalizeSystemCall,
) ![]const []const u8 {
    return applyFinalizeBlockMode(
        executor,
        execution_context,
        allocator,
        calls,
        .normal,
        {},
    );
}

pub fn applyFinalizeBlockObserved(
    executor: anytype,
    execution_context: ExecutionContext,
    allocator: std.mem.Allocator,
    calls: []const block_lifecycle.FinalizeSystemCall,
    observer: anytype,
) ![]const []const u8 {
    return applyFinalizeBlockMode(
        executor,
        execution_context,
        allocator,
        calls,
        .observed,
        observer,
    );
}

fn applyFinalizeBlockMode(
    executor: anytype,
    execution_context: ExecutionContext,
    allocator: std.mem.Allocator,
    calls: []const block_lifecycle.FinalizeSystemCall,
    mode: InstrumentationMode,
    observer: anytype,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |request| allocator.free(request);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, calls.len);
    if (calls.len == 0) return try out.toOwnedSlice(allocator);

    var phase_start = try executor.branchSnapshot();
    defer phase_start.deinit();
    errdefer executor.restoreBranch(&phase_start);

    executor.beginSystemCallBatch();
    defer executor.endSystemCallBatch();

    for (calls) |*finalize_call| {
        const call = &finalize_call.call;
        const request = try callRequestSystemContract(
            executor,
            execution_context,
            allocator,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            finalize_call.output_prefix,
            call.require_code,
            mode,
            observer,
        );
        if (request) |typed_request| out.appendAssumeCapacity(typed_request);
    }

    const owned = try out.toOwnedSlice(allocator);
    errdefer {
        for (owned) |request| allocator.free(request);
        allocator.free(owned);
    }
    return owned;
}

fn applySystemCalls(
    executor: anytype,
    execution_context: ExecutionContext,
    calls: []const block_lifecycle.BlockSystemCall,
    mode: InstrumentationMode,
    observer: anytype,
) !void {
    if (calls.len == 0) return;

    var phase_start = try executor.branchSnapshot();
    defer phase_start.deinit();
    errdefer executor.restoreBranch(&phase_start);

    executor.beginSystemCallBatch();
    defer executor.endSystemCallBatch();

    for (calls) |*call| {
        try callSystemContract(
            executor,
            execution_context,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            call.require_code,
            mode,
            observer,
        );
    }
}

fn callSystemContract(
    executor: anytype,
    execution_context: ExecutionContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    require_code: bool,
    mode: InstrumentationMode,
    observer: anytype,
) !void {
    const has_code = try executor.accountHasCode(recipient);
    if (!has_code and require_code) return error.SystemCallFailed;
    const result = switch (mode) {
        .normal => try executor.executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
        ),
        .observed => try executor.observe(observer).executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
        ),
        .captured => |capture| try executor.capture(capture).executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
            observer,
        ),
    };
    if (has_code and result.status() != .success) return error.SystemCallFailed;
}

fn callSystemContractInPrelude(
    prelude: anytype,
    execution_context: ExecutionContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    require_code: bool,
) @TypeOf(prelude).Error!void {
    const has_code = (try prelude.code(recipient)).len != 0;
    if (!has_code and require_code) return error.SystemCallFailed;

    const result = try prelude.executeRequest(.{
        .context = execution_context,
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .input = input,
        } },
        .gas = .{
            .regular_left = gas,
            .reservoir = state_gas,
        },
    });
    if (has_code and result.status() != .success) return error.SystemCallFailed;
}

fn callRequestSystemContract(
    executor: anytype,
    execution_context: ExecutionContext,
    allocator: std.mem.Allocator,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    request_type: u8,
    require_code: bool,
    mode: InstrumentationMode,
    observer: anytype,
) !?[]const u8 {
    const has_code = try executor.accountHasCode(recipient);
    if (!has_code and require_code) return error.SystemCallFailed;
    const result = switch (mode) {
        .normal => try executor.executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
        ),
        .observed => try executor.observe(observer).executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
        ),
        .captured => |capture| try executor.capture(capture).executeSystemCall(
            execution_context,
            sender,
            recipient,
            input,
            .{ .regular_left = gas, .reservoir = state_gas },
            observer,
        ),
    };
    if (has_code and result.status() != .success) return error.SystemCallFailed;
    if (!has_code or result.output_data.len == 0) return null;

    const request_len = std.math.add(usize, result.output_data.len, 1) catch return error.OutOfMemory;
    const request = try allocator.alloc(u8, request_len);
    request[0] = request_type;
    @memcpy(request[1..], result.output_data);
    return request;
}

test "before block calls Prague and Cancun system contracts" {
    const ethereum = evmz.eth;
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    var executor = Prague.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var history_code_buf: [83]u8 = undefined;
    const history_code = try std.fmt.hexToBytes(
        &history_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
    );
    var history_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try history_account.setCode(history_code);
    try executor.state.seedAccount(ethereum.history_storage_address, history_account);
    var beacon_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try beacon_account.setCode(&system_prepared_code.beacon_roots_code);
    try executor.state.seedAccount(ethereum.beacon_roots_address, beacon_account);

    var parent_hash = [_]u8{0} ** 32;
    parent_hash[31] = 0xaa;
    var beacon_root = [_]u8{0} ** 32;
    beacon_root[31] = 0xbb;

    const execution_context = testExecutionContext();
    const calls = Prague.spec.block.beforeBlock(.{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });
    for (calls.slice()) |call| {
        try std.testing.expectEqual(ethereum.system_address, call.sender);
        try std.testing.expectEqual(@as(u64, 0), call.state_gas);
    }

    try applyBeforeBlock(&executor, execution_context, calls.slice());

    try std.testing.expectEqual(@as(u256, 0xaa), try executor.getStorage(ethereum.history_storage_address, 0));
    try std.testing.expectEqual(@as(u256, 12), try executor.getStorage(ethereum.beacon_roots_address, 12));
    try std.testing.expectEqual(@as(u256, 0xbb), try executor.getStorage(ethereum.beacon_roots_address, 8191 + 12));

    try std.testing.expectEqual(Interpreter.Status.success, (try executor.executeSystemCall(
        execution_context,
        ethereum.system_address,
        evmz.addr(0x1234),
        &parent_hash,
        .legacy(ethereum.system_call_gas),
    )).status());
}

test "Amsterdam before-block system calls reserve state gas" {
    const ethereum = evmz.eth;
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const calls = Amsterdam.spec.block.beforeBlock(.{
        .number = 1,
        .timestamp = 12,
        .parent_hash = [_]u8{0xaa} ** 32,
        .parent_beacon_block_root = [_]u8{0xbb} ** 32,
    });

    for (calls.slice()) |call| {
        try std.testing.expectEqual(ethereum.system_call_state_gas, call.state_gas);
    }
}

test "Amsterdam block hook executes state growth from the system-call reservoir" {
    const ethereum = evmz.eth;
    const ReservoirBlock = struct {
        const recipient = evmz.addr(0x8037);

        fn beforeBlock(_: BeforeBlockContext) block_lifecycle.BlockSystemCalls {
            var calls = block_lifecycle.BlockSystemCalls{};
            calls.append(.{
                .sender = ethereum.system_address,
                .recipient = recipient,
                .gas = 20_000,
                .state_gas = ethereum.eip8037.storage_set_state_gas,
                .require_code = true,
            });
            return calls;
        }
    };
    const ReservoirVm = evmz.Vm(ethereum.amsterdam.extend(.{
        .block = .{ .beforeBlock = ReservoirBlock.beforeBlock },
    }));

    var executor = ReservoirVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var recipient_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try recipient_account.setCode(&.{
        0x60, 0x01, // PUSH1 1
        0x5f, // PUSH0
        0x55, // SSTORE
        0x00, // STOP
    });
    try executor.state.seedAccount(ReservoirBlock.recipient, recipient_account);

    const calls = ReservoirVm.spec.block.beforeBlock(.{
        .number = 1,
        .timestamp = 12,
    });
    try applyBeforeBlock(&executor, testExecutionContext(), calls.slice());
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(ReservoirBlock.recipient, 0));
}

test "finalize block copies successful system contract output into typed requests" {
    const ethereum = evmz.eth;

    const RequestBlock = struct {
        const recipient = evmz.addr(0x7002);

        pub fn finalizeBlock(_: FinalizeBlockContext) block_lifecycle.FinalizeSystemCalls {
            var calls = block_lifecycle.FinalizeSystemCalls{};
            calls.append(.{
                .call = .{
                    .sender = ethereum.system_address,
                    .recipient = recipient,
                    .gas = ethereum.system_call_gas,
                },
                .output_prefix = 0x01,
            });
            return calls;
        }
    };

    const RequestVm = evmz.Vm(ethereum.prague.extend(.{
        .block = .{ .finalizeBlock = RequestBlock.finalizeBlock },
    }));
    var executor = RequestVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const request_code = [_]u8{
        0x61, 0xaa, 0xbb, // PUSH2 0xaabb
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x02, // PUSH1 2
        0x60, 0x1e, // PUSH1 30
        0xf3, // RETURN
    };
    var request_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try request_account.setCode(&request_code);
    try executor.state.seedAccount(RequestBlock.recipient, request_account);

    const calls = RequestVm.spec.block.finalizeBlock(.{
        .number = 1,
        .timestamp = 12,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    });
    const requests = try applyFinalizeBlock(
        &executor,
        testExecutionContext(),
        std.testing.allocator,
        calls.slice(),
    );
    defer {
        for (requests) |request| std.testing.allocator.free(request);
        std.testing.allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xaa, 0xbb }, requests[0]);
}

test "finalize block rejects missing required system contract code" {
    const ethereum = evmz.eth;

    const RequiredBlock = struct {
        pub fn finalizeBlock(_: FinalizeBlockContext) block_lifecycle.FinalizeSystemCalls {
            var calls = block_lifecycle.FinalizeSystemCalls{};
            calls.append(.{
                .call = .{
                    .sender = ethereum.system_address,
                    .recipient = evmz.addr(0x7002),
                    .gas = ethereum.system_call_gas,
                    .require_code = true,
                },
                .output_prefix = 0x01,
            });
            return calls;
        }
    };

    const RequiredVm = evmz.Vm(ethereum.prague.extend(.{
        .block = .{ .finalizeBlock = RequiredBlock.finalizeBlock },
    }));
    var executor = RequiredVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const calls = RequiredVm.spec.block.finalizeBlock(.{
        .number = 1,
        .timestamp = 12,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    });
    try std.testing.expectError(
        error.SystemCallFailed,
        applyFinalizeBlock(
            &executor,
            testExecutionContext(),
            std.testing.allocator,
            calls.slice(),
        ),
    );
}

fn testExecutionContext() ExecutionContext {
    return .{
        .chain = .{ .chain_id = 1 },
        .block = .{ .number = 1, .timestamp = 12 },
        .transaction = .{ .origin = evmz.addr(0) },
    };
}
