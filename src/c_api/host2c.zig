const evmc = @cImport({
    @cInclude("evmc.h");
});
const std = @import("std");
const Host = @import("../Host.zig");

const common = @import("common.zig");

const log = std.log.scoped(.evmz_host2c);
const toEvmcAddress = common.toEvmcAddress;
const fromEvmcAddress = common.fromEvmcAddress;
const fromEvmcBytes32 = common.fromEvmcBytes32;
const toEvmcBytes32 = common.toEvmcBytes32;

pub const HostContext = extern struct {
    ptr: *anyopaque align(@alignOf(*anyopaque)),
    host: *Host align(@alignOf(*Host)),

    vtable: *const struct {
        deinit: *const fn (ptr: *anyopaque) void,
    },

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
};

pub fn getInterface() evmc.evmc_host_interface {
    return evmc.evmc_host_interface{
        .account_exists = accountExists,
        .get_storage = getStorage,
        .set_storage = setStorage,
        .get_balance = getBalance,
        .get_code_size = getCodeSize,
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
fn accountExists(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.C) bool {
    const host = HostContext.getHostFromContext(context);
    return host.accountExists(fromEvmcAddress(address.*)) catch false;
}

fn getStorage(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address, key: [*c]const evmc.evmc_bytes32) callconv(.C) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*))).*;
}

fn setStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.C) evmc.evmc_storage_status {
    const host = HostContext.getHostFromContext(context);
    const r = host.setStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {
        return 0;
    };
    return @intFromEnum(r);
}

fn getBalance(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.C) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    const b = host.getBalance(fromEvmcAddress(address.*)) catch 0;
    return toEvmcBytes32(b).*;
}

fn getCodeSize(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.C) usize {
    const host = HostContext.getHostFromContext(context);
    return @intCast(host.getCodeSize(fromEvmcAddress(address.*)) catch 0);
}

fn getCodeHash(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.C) [*c]evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getCodeHash(fromEvmcAddress(address.*)) catch 0);
}

fn copyCode(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    code_offset: usize,
    buffer_data: [*c]u8,
    buffer_size: usize,
) callconv(.C) usize {
    const host = HostContext.getHostFromContext(context);
    return host.copyCode(fromEvmcAddress(address.*), code_offset, buffer_data[0..buffer_size]) catch 0;
}

fn selfDestruct(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    beneficiary: [*c]const evmc.evmc_address,
) callconv(.C) bool {
    const host = HostContext.getHostFromContext(context);
    return host.selfDestruct(fromEvmcAddress(address.*), fromEvmcAddress(beneficiary.*)) catch false;
}

fn call(
    context: ?*evmc.evmc_host_context,
    msg: [*c]const evmc.evmc_message,
) callconv(.C) evmc.evmc_result {
    const host = HostContext.getHostFromContext(context);

    const message = Host.Message{
        .kind = @enumFromInt(msg.*.kind),
        .depth = @intCast(msg.*.depth),
        .gas = msg.*.gas,
        .recipient = fromEvmcAddress(msg.*.recipient),
        .sender = fromEvmcAddress(msg.*.sender),
        .input_data = msg.*.input_data[0..msg.*.input_size],
        .value = fromEvmcBytes32(msg.*.value),
        .is_static = msg.*.flags & evmc.EVMC_STATIC != 0,
        .code_address = fromEvmcAddress(msg.*.code_address),
    };

    const result = host.call(message) catch return evmc.evmc_result{
        .status_code = evmc.EVMC_FAILURE,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .create_address = std.mem.zeroes(evmc.evmc_address),
        .release = null,
        .padding = undefined,
    };

    return evmc.evmc_result{
        .status_code = @intFromEnum(result.status),
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = result.output_data.ptr,
        .output_size = result.output_data.len,
        .create_address = toEvmcAddress(result.create_address),
        .release = null,
        .padding = undefined,
    };
}

fn getTxContext(context: ?*evmc.evmc_host_context) callconv(.C) evmc.evmc_tx_context {
    if (context == null) {
        return std.mem.zeroes(evmc.evmc_tx_context);
    }
    const host = HostContext.getHostFromContext(context);
    const tx_context = host.getTxContext() catch {
        log.warn("getTxContext failed", .{});
        return std.mem.zeroes(evmc.evmc_tx_context);
    };

    return evmc.evmc_tx_context{
        .block_base_fee = toEvmcBytes32(tx_context.base_fee).*,
        .block_coinbase = toEvmcAddress(tx_context.coinbase),
        .block_gas_limit = @intCast(tx_context.gas_limit),
        .block_number = @intCast(tx_context.number),
        .block_prev_randao = toEvmcBytes32(tx_context.prev_randao).*,
        .block_timestamp = @intCast(tx_context.timestamp),
        .chain_id = toEvmcBytes32(tx_context.chain_id).*,
        .tx_gas_price = toEvmcBytes32(tx_context.gas_price).*,
        .tx_origin = toEvmcAddress(tx_context.origin),
    };
}

fn getBlockHash(context: ?*evmc.evmc_host_context, number: i64) callconv(.C) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getBlockHash(@intCast(number)) catch 0).*;
}

fn emitLog(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    data: [*c]const u8,
    data_size: usize,
    topics: [*c]const evmc.evmc_bytes32,
    topics_count: usize,
) callconv(.C) void {
    const host = HostContext.getHostFromContext(context);

    // max 4 topcis
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

fn accessAccount(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.C) evmc.evmc_access_status {
    const host = HostContext.getHostFromContext(context);
    return @intFromEnum(host.accessAccount(fromEvmcAddress(address.*)) catch Host.AccessStatus.cold);
}

fn accessStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.C) evmc.evmc_access_status {
    const host = HostContext.getHostFromContext(context);
    return @intFromEnum(host.accessStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*)) catch Host.AccessStatus.cold);
}

fn getTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
) callconv(.C) evmc.evmc_bytes32 {
    const host = HostContext.getHostFromContext(context);
    return toEvmcBytes32(host.getTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*))).*;
}

fn setTransientStorage(
    context: ?*evmc.evmc_host_context,
    address: [*c]const evmc.evmc_address,
    key: [*c]const evmc.evmc_bytes32,
    value: [*c]const evmc.evmc_bytes32,
) callconv(.C) void {
    const host = HostContext.getHostFromContext(context);
    host.setTransientStorage(fromEvmcAddress(address.*), fromEvmcBytes32(key.*), fromEvmcBytes32(value.*)) catch {
        log.err("setTransientStorage failed", .{});
    };
}
