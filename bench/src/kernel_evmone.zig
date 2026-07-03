const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const evmc = @cImport({
    @cInclude("evmc/evmc.h");
});

extern fn evmc_create_evmone() ?*evmc.evmc_vm;

pub const Mode = enum {
    baseline,
    advanced,
};

pub const Measurement = struct {
    elapsed_ns: u64,
    gas_used: u64,
    host_calls: u64,
};

pub fn measure(code: []const u8, spec: evmz.Spec, mode: Mode) !Measurement {
    const vm = evmc_create_evmone() orelse return error.EvmoneCreateFailed;
    defer vm.*.destroy.?(vm);

    if (mode == .advanced) {
        const result = vm.*.set_option.?(vm, "advanced", "");
        if (result != evmc.EVMC_SET_OPTION_SUCCESS) return error.EvmoneOptionFailed;
    }

    var context = Context{};
    const host = interface();
    var message = std.mem.zeroes(evmc.evmc_message);
    message.kind = evmc.EVMC_CALL;
    message.gas = common.max_gas;
    message.recipient = toEvmcAddress(common.contract_address);
    message.sender = toEvmcAddress(common.caller_address);
    message.code_address = toEvmcAddress(common.contract_address);

    const code_ptr: [*c]const u8 = if (code.len == 0) null else code.ptr;
    const start_ns = try common.monotonicNowNs();
    var result = vm.*.execute.?(
        vm,
        &host,
        context.toContext(),
        revFromSpec(spec),
        &message,
        code_ptr,
        code.len,
    );
    const end_ns = try common.monotonicNowNs();
    defer releaseResult(&result);

    if (result.status_code != evmc.EVMC_SUCCESS) return error.EvmoneExecutionFailed;
    return .{
        .elapsed_ns = end_ns - start_ns,
        .gas_used = @intCast(common.max_gas - result.gas_left),
        .host_calls = context.host_calls,
    };
}

const Context = struct {
    host_calls: u64 = 0,

    fn toContext(self: *Context) ?*evmc.evmc_host_context {
        return @ptrCast(@alignCast(self));
    }

    fn fromContext(context: ?*evmc.evmc_host_context) *Context {
        return @ptrCast(@alignCast(context orelse @panic("EVMC host context is null")));
    }

    fn touch(context: ?*evmc.evmc_host_context) void {
        fromContext(context).host_calls += 1;
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
    _ = address;
    Context.touch(context);
    return false;
}

fn getStorage(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address, key: [*c]const evmc.evmc_bytes32) callconv(.c) evmc.evmc_bytes32 {
    _ = address;
    _ = key;
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_bytes32);
}

fn setStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_storage_status {
    _ = address;
    _ = key;
    _ = value;
    Context.touch(context);
    return evmc.EVMC_STORAGE_ASSIGNED;
}

fn getBalance(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    _ = address;
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_bytes32);
}

fn getCodeSize(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) usize {
    _ = address;
    Context.touch(context);
    return 0;
}

fn getCodeHash(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    _ = address;
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_bytes32);
}

fn copyCode(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    code_offset: usize,
    buffer_data: [*c]u8,
    buffer_size: usize,
) callconv(.c) usize {
    _ = address;
    _ = code_offset;
    _ = buffer_data;
    _ = buffer_size;
    Context.touch(context);
    return 0;
}

fn selfDestruct(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    beneficiary: [*c]const evmc.evmc_address,
) callconv(.c) bool {
    _ = address;
    _ = beneficiary;
    Context.touch(context);
    return false;
}

fn call(context: ?*evmc.evmc_host_context, message: [*c]const evmc.evmc_message) callconv(.c) evmc.evmc_result {
    _ = message;
    Context.touch(context);
    return .{
        .status_code = evmc.EVMC_SUCCESS,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .release = null,
        .create_address = std.mem.zeroes(evmc.evmc_address),
    };
}

fn getTxContext(context: ?*evmc.evmc_host_context) callconv(.c) evmc.evmc_tx_context {
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_tx_context);
}

fn getBlockHash(context: ?*evmc.evmc_host_context, number: i64) callconv(.c) evmc.evmc_bytes32 {
    _ = number;
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_bytes32);
}

fn emitLog(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    data: [*c]const u8,
    data_size: usize,
    topics: [*c]const evmc.evmc_bytes32,
    topics_count: usize,
) callconv(.c) void {
    _ = address;
    _ = data;
    _ = data_size;
    _ = topics;
    _ = topics_count;
    Context.touch(context);
}

fn accessAccount(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_access_status {
    _ = address;
    Context.touch(context);
    return evmc.EVMC_ACCESS_COLD;
}

fn accessStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_access_status {
    _ = address;
    _ = key;
    Context.touch(context);
    return evmc.EVMC_ACCESS_COLD;
}

fn getTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_bytes32 {
    _ = address;
    _ = key;
    Context.touch(context);
    return std.mem.zeroes(evmc.evmc_bytes32);
}

fn setTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) void {
    _ = address;
    _ = key;
    _ = value;
    Context.touch(context);
}

fn releaseResult(result: *const evmc.evmc_result) void {
    if (result.release) |release| release(result);
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

fn toEvmcAddress(address: common.Address) evmc.evmc_address {
    return .{ .bytes = address };
}

test "evmone baseline executes push pop kernel" {
    const code = [_]u8{ 0x60, 0x01, 0x50, 0x00 };
    const measurement = try measure(&code, .latest, .baseline);
    try std.testing.expectEqual(@as(u64, 0), measurement.host_calls);
}
