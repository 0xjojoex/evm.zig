const std = @import("std");
const evmz = @import("evmz");

const evmc = @cImport({
    @cInclude("evmc/evmc.h");
});

const Address = evmz.Address;
const Executor = evmz.executor;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;

extern fn evmc_create_evmone() ?*evmc.evmc_vm;

pub const Mode = enum {
    baseline,
    advanced,
};

pub const Runner = struct {
    vm: *evmc.evmc_vm,
    context: Context,
    interface: evmc.evmc_host_interface,

    pub fn init(executor: *Executor, mode: Mode) !Runner {
        const vm = evmc_create_evmone() orelse return error.EvmoneCreateFailed;
        errdefer vm.*.destroy.?(vm);

        if (mode == .advanced) {
            const result = vm.*.set_option.?(vm, "advanced", "");
            if (result != evmc.EVMC_SET_OPTION_SUCCESS) return error.EvmoneOptionFailed;
        }

        return .{
            .vm = vm,
            .context = .{
                .executor = executor,
                .vm = vm,
            },
            .interface = interface(),
        };
    }

    pub fn deinit(self: *Runner) void {
        self.vm.*.destroy.?(self.vm);
    }

    pub fn executeCallTransaction(
        self: *Runner,
        sender: Address,
        recipient: Address,
        input: []const u8,
        gas: u64,
        value: u256,
    ) !Interpreter.Result {
        const executor = self.context.executor;
        executor.clearLastOutput();
        if (!try executor.transferValue(sender, recipient, value)) {
            return .{
                .status = .invalid,
                .gas_left = 0,
                .gas_refund = 0,
                .output_data = &.{},
            };
        }

        const code = try executor.dupeExecutionCode(recipient);
        defer executor.allocator.free(code);

        var message = std.mem.zeroes(evmc.evmc_message);
        message.kind = evmc.EVMC_CALL;
        message.gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64);
        message.recipient = toEvmcAddress(recipient);
        message.sender = toEvmcAddress(sender);
        message.input_data = if (input.len == 0) null else input.ptr;
        message.input_size = input.len;
        message.value = toEvmcBytes32(value);
        message.code_address = toEvmcAddress(recipient);

        return try self.executeMessage(&message, code);
    }

    pub fn executeCreateTransaction(
        self: *Runner,
        sender: Address,
        init_code: []const u8,
        gas: u64,
        value: u256,
    ) !Interpreter.Result {
        const executor = self.context.executor;
        executor.clearLastOutput();

        var message = std.mem.zeroes(evmc.evmc_message);
        message.kind = evmc.EVMC_CREATE;
        message.gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64);
        message.sender = toEvmcAddress(sender);
        message.input_data = if (init_code.len == 0) null else init_code.ptr;
        message.input_size = init_code.len;
        message.value = toEvmcBytes32(value);

        var result = try executeCreate(&self.context, self.context.toContext(), message);
        defer releaseResult(&result);

        const output = if (hasOutput(result.status_code) and result.output_size > 0)
            result.output_data[0..result.output_size]
        else
            &.{};
        const output_copy = try executor.allocator.dupe(u8, output);
        executor.clearLastOutput();
        executor.last_call_output = output_copy;

        return .{
            .status = statusFromEvmc(result.status_code),
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .output_data = executor.last_call_output,
        };
    }

    fn executeMessage(self: *Runner, message: *const evmc.evmc_message, code: []const u8) !Interpreter.Result {
        const code_ptr: [*c]const u8 = if (code.len == 0) null else code.ptr;
        var result = self.vm.*.execute.?(
            self.vm,
            &self.interface,
            self.context.toContext(),
            revFromSpec(self.context.executor.spec),
            message,
            code_ptr,
            code.len,
        );
        defer releaseResult(&result);

        const output = if (hasOutput(result.status_code) and result.output_size > 0)
            result.output_data[0..result.output_size]
        else
            &.{};
        self.context.executor.clearLastOutput();
        self.context.executor.last_call_output = try self.context.executor.allocator.dupe(u8, output);

        return .{
            .status = statusFromEvmc(result.status_code),
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .output_data = self.context.executor.last_call_output,
        };
    }
};

const Context = struct {
    executor: *Executor,
    vm: *evmc.evmc_vm,

    fn toContext(self: *Context) ?*evmc.evmc_host_context {
        return @ptrCast(@alignCast(self));
    }

    fn fromContext(context: ?*evmc.evmc_host_context) *Context {
        return @ptrCast(@alignCast(context orelse @panic("EVMC host context is null")));
    }
};

fn interface() evmc.evmc_host_interface {
    return .{
        .account_exists = accountExists,
        .get_storage = getStorage,
        .set_storage = setStorage,
        .get_balance = getBalance,
        .get_code_size = getCodeSize,
        .get_code_hash = getCodeHash,
        .copy_code = copyCode,
        .selfdestruct = selfDestruct,
        .call = call,
        .get_tx_context = getTxContext,
        .get_block_hash = getBlockHash,
        .emit_log = emitLog,
        .access_account = accessAccount,
        .access_storage = accessStorage,
        .get_transient_storage = getTransientStorage,
        .set_transient_storage = setTransientStorage,
    };
}

fn accountExists(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) bool {
    var host = Context.fromContext(context).executor.host();
    return host.accountExists(fromEvmcAddress(address.*)) catch false;
}

fn getStorage(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address, key: [*c]const evmc.evmc_bytes32) callconv(.c) evmc.evmc_bytes32 {
    var host = Context.fromContext(context).executor.host();
    return toEvmcBytes32(host.getStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch 0);
}

fn setStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_storage_status {
    var host = Context.fromContext(context).executor.host();
    const status = host.setStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {
        return evmc.EVMC_STORAGE_ASSIGNED;
    };
    return @intFromEnum(status);
}

fn getBalance(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    var host = Context.fromContext(context).executor.host();
    return toEvmcBytes32(host.getBalance(fromEvmcAddress(address.*)) catch 0);
}

fn getCodeSize(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) usize {
    var host = Context.fromContext(context).executor.host();
    return @intCast(host.getCodeSize(fromEvmcAddress(address.*)) catch 0);
}

fn getCodeHash(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    var host = Context.fromContext(context).executor.host();
    return toEvmcBytes32(host.getCodeHash(fromEvmcAddress(address.*)) catch 0);
}

fn copyCode(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    code_offset: usize,
    buffer_data: [*c]u8,
    buffer_size: usize,
) callconv(.c) usize {
    var host = Context.fromContext(context).executor.host();
    return host.copyCode(fromEvmcAddress(address.*), code_offset, buffer_data[0..buffer_size]) catch 0;
}

fn selfDestruct(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    beneficiary: [*c]const evmc.evmc_address,
) callconv(.c) bool {
    var host = Context.fromContext(context).executor.host();
    return host.selfDestruct(fromEvmcAddress(address.*), fromEvmcAddress(beneficiary.*)) catch false;
}

fn call(context: ?*evmc.evmc_host_context, message: [*c]const evmc.evmc_message) callconv(.c) evmc.evmc_result {
    const ctx = Context.fromContext(context);
    const executor = ctx.executor;
    executor.clearLastOutput();

    if (message.*.kind == evmc.EVMC_CREATE or message.*.kind == evmc.EVMC_CREATE2) {
        return executeCreate(ctx, context, message.*) catch return failureResult(evmc.EVMC_FAILURE, 0);
    }

    const value = fromEvmcBytes32(message.*.value);
    const checkpoint_state = executor.state.checkpoint();

    if (message.*.kind == evmc.EVMC_CALL and value > 0) {
        if (!(executor.transferValue(fromEvmcAddress(message.*.sender), fromEvmcAddress(message.*.recipient), value) catch false)) {
            executor.state.revertToCheckpoint(checkpoint_state) catch return failureResult(evmc.EVMC_FAILURE, 0);
            return failureResult(evmc.EVMC_INSUFFICIENT_BALANCE, 0);
        }
    }

    const code_address = fromEvmcAddress(message.*.code_address);
    const code = executor.dupeExecutionCode(code_address) catch {
        executor.state.revertToCheckpoint(checkpoint_state) catch return failureResult(evmc.EVMC_FAILURE, 0);
        return failureResult(evmc.EVMC_FAILURE, 0);
    };
    defer executor.allocator.free(code);

    const code_ptr: [*c]const u8 = if (code.len == 0) null else code.ptr;
    var result = ctx.vm.*.execute.?(
        ctx.vm,
        &interface(),
        context,
        revFromSpec(executor.spec),
        message,
        code_ptr,
        code.len,
    );
    defer releaseResult(&result);

    const output = if (hasOutput(result.status_code) and result.output_size > 0)
        result.output_data[0..result.output_size]
    else
        &.{};
    executor.last_call_output = executor.allocator.dupe(u8, output) catch {
        executor.state.revertToCheckpoint(checkpoint_state) catch return failureResult(evmc.EVMC_FAILURE, 0);
        return failureResult(evmc.EVMC_OUT_OF_MEMORY, 0);
    };
    if (result.status_code != evmc.EVMC_SUCCESS) {
        executor.state.revertToCheckpoint(checkpoint_state) catch return failureResult(evmc.EVMC_FAILURE, 0);
    } else {
        executor.state.commitCheckpoint(checkpoint_state);
    }

    return .{
        .status_code = result.status_code,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = if (executor.last_call_output.len == 0) null else executor.last_call_output.ptr,
        .output_size = executor.last_call_output.len,
        .release = null,
        .create_address = result.create_address,
    };
}

fn executeCreate(ctx: *Context, context: ?*evmc.evmc_host_context, message: evmc.evmc_message) !evmc.evmc_result {
    const executor = ctx.executor;
    const allocator = executor.allocator;
    const init_code = messageInput(&message);
    const sender = fromEvmcAddress(message.sender);
    const value = fromEvmcBytes32(message.value);
    const caller = try executor.getOrCreateAccount(sender);
    const create_address = switch (message.kind) {
        evmc.EVMC_CREATE => evmz.address.create(sender, caller.nonce),
        evmc.EVMC_CREATE2 => evmz.address.create2(sender, fromEvmcBytes32(message.create2_salt), init_code),
        else => unreachable,
    };
    if (executor.spec.isImpl(.berlin)) {
        try executor.warmAccessListAddress(create_address);
    }

    const next_nonce = std.math.add(u64, caller.nonce, 1) catch {
        return failureResultWithCreate(evmc.EVMC_FAILURE, message.gas, create_address);
    };
    try executor.state.setNonce(sender, next_nonce);
    const checkpoint_state = executor.state.checkpoint();
    var checkpoint_open = true;
    errdefer {
        if (checkpoint_open) executor.state.revertToCheckpoint(checkpoint_state) catch {};
    }

    if (caller.balance < value) {
        executor.state.commitCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_INSUFFICIENT_BALANCE, message.gas, create_address);
    }
    if (try createCollision(executor, create_address)) {
        executor.state.commitCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_FAILURE, 0, create_address);
    }

    _ = try executor.state.subtractBalance(sender, value);
    try executor.state.addBalance(create_address, value);
    try executor.state.setNonce(create_address, if (executor.spec.isImpl(.spurious_dragon)) 1 else 0);
    try executor.state.clearCode(create_address);
    try executor.state.markCreatedContract(create_address);

    var child_message = std.mem.zeroes(evmc.evmc_message);
    child_message.kind = message.kind;
    child_message.depth = message.depth;
    child_message.gas = message.gas;
    child_message.recipient = toEvmcAddress(create_address);
    child_message.sender = toEvmcAddress(sender);
    child_message.value = message.value;
    child_message.create2_salt = message.create2_salt;
    child_message.code_address = toEvmcAddress(create_address);

    const code_ptr: [*c]const u8 = if (init_code.len == 0) null else init_code.ptr;
    var child_result = ctx.vm.*.execute.?(
        ctx.vm,
        &interface(),
        context,
        revFromSpec(executor.spec),
        &child_message,
        code_ptr,
        init_code.len,
    );
    defer releaseResult(&child_result);

    const child_output = if (hasOutput(child_result.status_code) and child_result.output_size > 0)
        child_result.output_data[0..child_result.output_size]
    else
        &.{};

    if (child_result.status_code != evmc.EVMC_SUCCESS) {
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        executor.clearLastOutput();
        executor.last_call_output = try allocator.dupe(u8, child_output);
        return .{
            .status_code = child_result.status_code,
            .gas_left = child_result.gas_left,
            .gas_refund = child_result.gas_refund,
            .output_data = if (executor.last_call_output.len == 0) null else executor.last_call_output.ptr,
            .output_size = executor.last_call_output.len,
            .release = null,
            .create_address = toEvmcAddress(create_address),
        };
    }

    if (executor.spec.isImpl(.spurious_dragon) and child_output.len > Executor.maxCodeSize(executor.spec)) {
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_OUT_OF_GAS, 0, create_address);
    }
    if (executor.spec.isImpl(.london) and child_output.len > 0 and child_output[0] == 0xef) {
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_INVALID_INSTRUCTION, 0, create_address);
    }

    const runtime_size = std.math.cast(i64, child_output.len) orelse {
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_OUT_OF_GAS, 0, create_address);
    };
    const deposit_cost = std.math.mul(i64, runtime_size, Executor.code_deposit_gas) catch {
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_OUT_OF_GAS, 0, create_address);
    };
    if (child_result.gas_left < deposit_cost) {
        if (!executor.spec.isImpl(.homestead)) {
            executor.state.commitCheckpoint(checkpoint_state);
            checkpoint_open = false;
            return .{
                .status_code = evmc.EVMC_SUCCESS,
                .gas_left = child_result.gas_left,
                .gas_refund = child_result.gas_refund,
                .output_data = null,
                .output_size = 0,
                .release = null,
                .create_address = toEvmcAddress(create_address),
            };
        }
        try executor.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return failureResultWithCreate(evmc.EVMC_OUT_OF_GAS, 0, create_address);
    }

    try executor.state.setCode(create_address, child_output);
    executor.state.commitCheckpoint(checkpoint_state);
    checkpoint_open = false;

    return .{
        .status_code = evmc.EVMC_SUCCESS,
        .gas_left = child_result.gas_left - deposit_cost,
        .gas_refund = child_result.gas_refund,
        .output_data = null,
        .output_size = 0,
        .release = null,
        .create_address = toEvmcAddress(create_address),
    };
}

fn createCollision(executor: *Executor, address: Address) !bool {
    if (evmz.precompile.activeAt(executor.spec, address) != null) return true;
    const account = try executor.getAccountOrLoad(address) orelse return false;
    return account.nonce != 0 or account.code.len != 0 or try executor.state.accountHasStorage(address);
}

fn messageInput(message: *const evmc.evmc_message) []const u8 {
    if (message.input_size == 0) return &.{};
    return message.input_data[0..message.input_size];
}

fn getTxContext(context: ?*evmc.evmc_host_context) callconv(.c) evmc.evmc_tx_context {
    const executor = Context.fromContext(context).executor;
    const tx_context = executor.tx_context orelse return std.mem.zeroes(evmc.evmc_tx_context);
    return .{
        .tx_gas_price = toEvmcBytes32(tx_context.gas_price),
        .tx_origin = toEvmcAddress(tx_context.origin),
        .block_coinbase = toEvmcAddress(tx_context.coinbase),
        .block_number = @intCast(tx_context.number),
        .block_timestamp = @intCast(tx_context.timestamp),
        .block_gas_limit = @intCast(tx_context.gas_limit),
        .block_prev_randao = toEvmcBytes32(tx_context.prev_randao),
        .chain_id = toEvmcBytes32(tx_context.chain_id),
        .block_base_fee = toEvmcBytes32(tx_context.base_fee),
        .blob_base_fee = toEvmcBytes32(tx_context.blob_base_fee),
        .blob_hashes = null,
        .blob_hashes_count = 0,
        .block_slot_number = tx_context.slot_number,
    };
}

fn getBlockHash(context: ?*evmc.evmc_host_context, number: i64) callconv(.c) evmc.evmc_bytes32 {
    var host = Context.fromContext(context).executor.host();
    return toEvmcBytes32(host.getBlockHash(@intCast(number)) catch 0);
}

fn emitLog(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    data: [*c]const u8,
    data_size: usize,
    topics: [*c]const evmc.evmc_bytes32,
    topics_count: usize,
) callconv(.c) void {
    var host = Context.fromContext(context).executor.host();
    var topic_buf: [4]u256 = undefined;
    for (0..topics_count) |i| {
        topic_buf[i] = fromEvmcBytes32(topics[i]);
    }
    host.emitLog(.{
        .address = fromEvmcAddress(address.*),
        .data = if (data_size == 0) &.{} else data[0..data_size],
        .topics = topic_buf[0..topics_count],
    }) catch {};
}

fn accessAccount(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_access_status {
    var host = Context.fromContext(context).executor.host();
    const status = host.accessAccount(fromEvmcAddress(address.*)) catch Host.AccessStatus.cold;
    return @intFromEnum(status);
}

fn accessStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_access_status {
    var host = Context.fromContext(context).executor.host();
    const status = host.accessStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch Host.AccessStatus.cold;
    return @intFromEnum(status);
}

fn getTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_bytes32 {
    var host = Context.fromContext(context).executor.host();
    return toEvmcBytes32(host.getTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch 0);
}

fn setTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) void {
    var host = Context.fromContext(context).executor.host();
    host.setTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {};
}

fn failureResult(status_code: evmc.evmc_status_code, gas_left: i64) evmc.evmc_result {
    return .{
        .status_code = status_code,
        .gas_left = gas_left,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .release = null,
        .create_address = std.mem.zeroes(evmc.evmc_address),
    };
}

fn failureResultWithCreate(status_code: evmc.evmc_status_code, gas_left: i64, create_address: Address) evmc.evmc_result {
    var result = failureResult(status_code, gas_left);
    result.create_address = toEvmcAddress(create_address);
    return result;
}

fn releaseResult(result: *const evmc.evmc_result) void {
    if (result.release) |release| release(result);
}

fn hasOutput(status_code: evmc.evmc_status_code) bool {
    return status_code == evmc.EVMC_SUCCESS or status_code == evmc.EVMC_REVERT;
}

fn statusFromEvmc(status_code: evmc.evmc_status_code) Interpreter.Status {
    return switch (status_code) {
        evmc.EVMC_SUCCESS => .success,
        evmc.EVMC_REVERT => .revert,
        evmc.EVMC_OUT_OF_GAS => .out_of_gas,
        else => .invalid,
    };
}

fn revFromSpec(spec: evmz.Spec) evmc.evmc_revision {
    return switch (spec) {
        .frontier => evmc.EVMC_FRONTIER,
        .frontier_thawing => evmc.EVMC_FRONTIER,
        .homestead => evmc.EVMC_HOMESTEAD,
        .dao_fork => evmc.EVMC_HOMESTEAD,
        .tangerine_whistle => evmc.EVMC_TANGERINE_WHISTLE,
        .spurious_dragon => evmc.EVMC_SPURIOUS_DRAGON,
        .byzantium => evmc.EVMC_BYZANTIUM,
        .constantinople => evmc.EVMC_CONSTANTINOPLE,
        .petersburg => evmc.EVMC_PETERSBURG,
        .istanbul => evmc.EVMC_ISTANBUL,
        .muir_glacier => evmc.EVMC_ISTANBUL,
        .berlin => evmc.EVMC_BERLIN,
        .london => evmc.EVMC_LONDON,
        .arrow_glacier => evmc.EVMC_LONDON,
        .gray_glacier => evmc.EVMC_LONDON,
        .merge => evmc.EVMC_PARIS,
        .shanghai => evmc.EVMC_SHANGHAI,
        .cancun => evmc.EVMC_CANCUN,
        .prague => evmc.EVMC_PRAGUE,
        .osaka => evmc.EVMC_OSAKA,
        .amsterdam => evmc.EVMC_AMSTERDAM,
    };
}

fn toEvmcAddress(address: Address) evmc.evmc_address {
    return .{ .bytes = address };
}

fn fromEvmcAddress(address: evmc.evmc_address) Address {
    return address.bytes;
}

fn toEvmcBytes32(value: u256) evmc.evmc_bytes32 {
    var result = std.mem.zeroes(evmc.evmc_bytes32);
    std.mem.writeInt(u256, &result.bytes, value, .big);
    return result;
}

fn fromEvmcBytes32(value: evmc.evmc_bytes32) u256 {
    return std.mem.readInt(u256, &value.bytes, .big);
}
