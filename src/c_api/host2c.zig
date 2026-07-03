const std = @import("std");
const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");

const common = @import("common.zig");
const evmc = common.evmc;

const log = std.log.scoped(.evmz_host2c);
const toEvmcAddress = common.toEvmcAddress;
const fromEvmcAddress = common.fromEvmcAddress;
const fromEvmcBytes32 = common.fromEvmcBytes32;
const toEvmcBytes32 = common.toEvmcBytes32;

pub const HostContext = extern struct {
    ptr: *anyopaque align(@alignOf(*anyopaque)),
    host: *Host align(@alignOf(*Host)),
    blob_hashes: [common.max_blob_hashes]evmc.evmc_bytes32,

    vtable: *const struct {
        deinit: *const fn (ptr: *anyopaque) void,
    },

    pub fn borrowed(host: *Host) HostContext {
        return .{
            .ptr = host,
            .host = host,
            .blob_hashes = undefined,
            .vtable = &.{
                .deinit = borrowedDeinit,
            },
        };
    }

    pub fn deinit(self: *HostContext) void {
        return self.vtable.deinit(self.ptr);
    }

    pub fn toContext(self: *HostContext) ?*evmc.evmc_host_context {
        return @ptrCast(@alignCast(self));
    }

    pub fn getHostFromContext(ctx: ?*evmc.evmc_host_context) *Host {
        const self: ?*HostContext = fromContext(ctx);

        if (self) |s| {
            return @ptrCast(@alignCast(s.host));
        } else @panic("HostContext is null");
    }

    pub fn fromContext(ctx: ?*evmc.evmc_host_context) ?*HostContext {
        if (ctx == null) return null;
        return @ptrCast(@alignCast(ctx));
    }

    fn borrowedDeinit(ptr: *anyopaque) void {
        _ = ptr;
    }
};

pub fn getInterface() evmc.evmc_host_interface {
    return evmc.evmc_host_interface{
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
    const host = HostContext.getHostFromContext(context);
    return host.accountExists(fromEvmcAddress(address.*)) catch false;
}

fn getStorage(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address, key: [*c]const evmc.evmc_bytes32) callconv(.c) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch 0);
}

fn setStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_storage_status {
    const host = HostContext.getHostFromContext(context);
    const r = host.setStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {
        return 0;
    };
    return @intFromEnum(r);
}

fn getBalance(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    const b = host.getBalance(fromEvmcAddress(address.*)) catch 0;
    return toEvmcBytes32(b);
}

fn getCodeSize(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) usize {
    const host = HostContext.getHostFromContext(context);
    return @intCast(host.getCodeSize(fromEvmcAddress(address.*)) catch 0);
}

fn getCodeHash(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getCodeHash(fromEvmcAddress(address.*)) catch 0);
}

fn copyCode(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    code_offset: usize,
    buffer_data: [*c]u8,
    buffer_size: usize,
) callconv(.c) usize {
    const host = HostContext.getHostFromContext(context);
    return host.copyCode(fromEvmcAddress(address.*), code_offset, buffer_data[0..buffer_size]) catch 0;
}

fn selfDestruct(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    beneficiary: [*c]const evmc.evmc_address,
) callconv(.c) bool {
    const host = HostContext.getHostFromContext(context);
    return host.selfDestruct(fromEvmcAddress(address.*), fromEvmcAddress(beneficiary.*)) catch false;
}

fn call(
    context: ?*evmc.evmc_host_context,
    msg: [*c]const evmc.evmc_message,
) callconv(.c) evmc.evmc_result {
    const host = HostContext.getHostFromContext(context);
    const kind = common.callKindFromEvmc(msg.*.kind) catch return failureResult(evmc.EVMC_FAILURE);
    const depth = std.math.cast(u16, msg.*.depth) orelse return failureResult(evmc.EVMC_FAILURE);
    const input_data = common.evmcInputData(msg.*.input_data, msg.*.input_size) catch return failureResult(evmc.EVMC_FAILURE);

    const message = Host.Message{
        .kind = kind,
        .depth = depth,
        .gas = msg.*.gas,
        .recipient = fromEvmcAddress(msg.*.recipient),
        .sender = fromEvmcAddress(msg.*.sender),
        .input_data = input_data,
        .value = fromEvmcBytes32(msg.*.value),
        .is_static = msg.*.flags & evmc.EVMC_STATIC != 0,
        .code_address = fromEvmcAddress(msg.*.code_address),
        .create2_salt = fromEvmcBytes32(msg.*.create2_salt),
    };

    const result = host.call(message) catch return failureResult(evmc.EVMC_FAILURE);

    const output_data = result.outputData();
    var output_ptr: [*c]const u8 = null;
    var release_fn: evmc.evmc_release_result_fn = null;
    if (output_data.len > 0) {
        const output_copy = std.heap.c_allocator.alloc(u8, output_data.len) catch {
            return evmc.evmc_result{
                .status_code = evmc.EVMC_OUT_OF_MEMORY,
                .gas_left = 0,
                .gas_refund = 0,
                .output_data = null,
                .output_size = 0,
                .create_address = std.mem.zeroes(evmc.evmc_address),
                .release = null,
            };
        };
        @memcpy(output_copy, output_data);
        output_ptr = output_copy.ptr;
        release_fn = releaseResult;
    }

    const create_address = switch (result) {
        .call => std.mem.zeroes(evmc.evmc_address),
        .create => |create| toEvmcAddress(create.address),
    };

    return evmc.evmc_result{
        .status_code = statusToEvmc(result.status()),
        .gas_left = result.gasLeft(),
        .gas_refund = result.gasRefund(),
        .output_data = output_ptr,
        .output_size = output_data.len,
        .create_address = create_address,
        .release = release_fn,
    };
}

fn failureResult(status_code: evmc.evmc_status_code) evmc.evmc_result {
    return evmc.evmc_result{
        .status_code = status_code,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .create_address = std.mem.zeroes(evmc.evmc_address),
        .release = null,
    };
}

fn releaseResult(result: [*c]const evmc.evmc_result) callconv(.c) void {
    if (result.*.output_data == null) return;
    const data = @as([*]u8, @ptrCast(@constCast(result.*.output_data)))[0..result.*.output_size];
    std.heap.c_allocator.free(data);
}

fn getTxContext(context: ?*evmc.evmc_host_context) callconv(.c) evmc.evmc_tx_context {
    if (context == null) {
        return std.mem.zeroes(evmc.evmc_tx_context);
    }
    const host_context = HostContext.fromContext(context).?;
    const host = host_context.host;
    const tx_context = host.getTxContext() catch {
        log.warn("getTxContext failed", .{});
        return std.mem.zeroes(evmc.evmc_tx_context);
    };
    const blob_hashes = common.toEvmcBlobHashes(tx_context.blob_hashes, &host_context.blob_hashes) catch {
        log.warn("getTxContext blob hash conversion failed", .{});
        return std.mem.zeroes(evmc.evmc_tx_context);
    };

    return evmc.evmc_tx_context{
        .block_base_fee = toEvmcBytes32(tx_context.base_fee),
        .block_coinbase = toEvmcAddress(tx_context.coinbase),
        .block_gas_limit = @intCast(tx_context.gas_limit),
        .block_number = @intCast(tx_context.number),
        .block_prev_randao = toEvmcBytes32(tx_context.prev_randao),
        .block_timestamp = @intCast(tx_context.timestamp),
        .chain_id = toEvmcBytes32(tx_context.chain_id),
        .tx_gas_price = toEvmcBytes32(tx_context.gas_price),
        .tx_origin = toEvmcAddress(tx_context.origin),
        .blob_base_fee = toEvmcBytes32(tx_context.blob_base_fee),
        .blob_hashes = if (blob_hashes.len == 0) null else blob_hashes.ptr,
        .blob_hashes_count = blob_hashes.len,
        .block_slot_number = tx_context.slot_number,
    };
}

fn statusToEvmc(status: Interpreter.Status) evmc.evmc_status_code {
    return switch (status) {
        .success => evmc.EVMC_SUCCESS,
        .revert => evmc.EVMC_REVERT,
        .out_of_gas => evmc.EVMC_OUT_OF_GAS,
        .invalid => evmc.EVMC_INVALID_INSTRUCTION,
    };
}

fn getBlockHash(context: ?*evmc.evmc_host_context, number: i64) callconv(.c) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    if (number < 0) return toEvmcBytes32(0);
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
    const host = HostContext.getHostFromContext(context);
    if (topics_count > 4) {
        log.err("emitLog failed: too many topics {}", .{topics_count});
        return;
    }

    // EVMC permits at most 4 topics.
    var topics_max: [4]u256 = undefined;

    for (0..topics_count) |i| {
        topics_max[i] = fromEvmcBytes32(topics[i]);
    }

    host.emitLog(.{
        .address = fromEvmcAddress(address.*),
        .data = data[0..data_size],
        .topics = topics_max[0..topics_count],
    }) catch {
        log.err("emitLog failed", .{});
    };
}

fn accessAccount(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_access_status {
    const host = HostContext.getHostFromContext(context);
    return @intFromEnum(host.accessAccount(fromEvmcAddress(address.*)) catch Host.AccessStatus.cold);
}

fn accessStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_access_status {
    const host = HostContext.getHostFromContext(context);
    return @intFromEnum(host.accessStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch Host.AccessStatus.cold);
}

fn getTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.c) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch 0);
}

fn setTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.c) void {
    const host = HostContext.getHostFromContext(context);
    host.setTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {
        log.err("setTransientStorage failed", .{});
    };
}
