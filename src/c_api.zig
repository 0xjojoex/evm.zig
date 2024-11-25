//! Implementation of the EVMC interface for evm.zig.
//! This is a proof of concept and not intended for production use.
const evmc = @cImport({
    @cInclude("evmc.h");
});

const std = @import("std");
const log = std.log.scoped(.evmc);
const evmz = @import("evm.zig");
const Address = evmz.Address;

export fn evmc_create_evmz() ?*evmc.evmc_vm {
    const instance = std.heap.c_allocator.create(Evmz) catch return null;
    instance.* = Evmz.init();
    return &instance.vm;
}

const Evmz = struct {
    vm: evmc.evmc_vm,
    spec: evmz.Spec = evmz.Spec.latest,

    pub fn init() Evmz {
        return Evmz{
            .vm = .{
                .abi_version = evmc.EVMC_ABI_VERSION,
                .name = "evmz",
                .version = "0.0.0",
                .destroy = destroy,
                .execute = execute,
                .get_capabilities = getCapabilities,
                .set_option = setOption,
            },
        };
    }
};

fn checkRevision(rev: evmc.evmc_revision) !void {
    if (try revToSpec(rev) != evmz.Spec.latest) {
        return error.InvalidRevision;
    }
}

fn destroy(vm: [*c]evmc.evmc_vm) callconv(.C) void {
    const self: *Evmz = @ptrCast(@alignCast(vm));
    std.heap.c_allocator.destroy(self);
}

fn getCapabilities(vm: [*c]evmc.struct_evmc_vm) callconv(.C) evmc.evmc_capabilities {
    _ = vm;
    return evmc.EVMC_CAPABILITY_EVM1;
}

fn execute(
    vm: [*c]evmc.evmc_vm,
    host: [*c]const evmc.evmc_host_interface,
    context: ?*evmc.evmc_host_context,
    rev: evmc.evmc_revision,
    msg: [*c]const evmc.evmc_message,
    code: [*c]const u8,
    code_size: usize,
) callconv(.C) evmc.evmc_result {
    const self: *Evmz = @ptrCast(@alignCast(vm));

    checkRevision(rev) catch {
        return evmc.evmc_result{
            .status_code = evmc.EVMC_INTERNAL_ERROR,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = null,
            .output_size = 0,
            .create_address = std.mem.zeroes(evmc.evmc_address),
            .release = release,
            .padding = undefined,
        };
    };

    var host_wrapper = HostWrapper{
        .host_interfcace = host,
        .context = context.?,
    };

    const message = evmz.Host.Message{
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

    var host_ = host_wrapper.toHost();

    var instance = evmz.Evm.init(std.heap.c_allocator, &host_, &message, code[0..code_size], self.spec);
    instance.deinit();

    const result = instance.execute();

    return evmc.evmc_result{
        .status_code = switch (result.status) {
            .success => evmc.EVMC_SUCCESS,
            .revert => evmc.EVMC_REVERT,
            .invalid => evmc.EVMC_INVALID_INSTRUCTION,
            .out_of_gas => evmc.EVMC_OUT_OF_GAS,
            // TODO: more status
            else => evmc.EVMC_FAILURE,
        },
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = result.output_data.ptr,
        .output_size = result.output_data.len,
        // TODO
        .create_address = std.mem.zeroes(evmc.evmc_address),
        .release = release,
        .padding = undefined,
    };
}

// TODO: release the return data
fn release(result: [*c]const evmc.evmc_result) callconv(.C) void {
    _ = result;
}

fn setOption(
    vm: [*c]evmc.evmc_vm,
    name: [*c]const u8,
    value: [*c]const u8,
) callconv(.C) evmc.evmc_set_option_result {
    var self: *Evmz = @ptrCast(@alignCast(vm));

    const name_str = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    const value_str = std.mem.span(@as([*:0]const u8, @ptrCast(value)));

    log.debug("set_option {s} {s}", .{ name, value });
    if (std.mem.eql(u8, name_str, "rev")) {
        const number = std.fmt.parseInt(c_uint, value_str, 10) catch {
            return evmc.EVMC_SET_OPTION_INVALID_VALUE;
        };

        self.spec = revToSpec(number) catch |err| {
            log.err("set_option failed: {}", .{err});
            return evmc.EVMC_SET_OPTION_INVALID_VALUE;
        };
        return evmc.EVMC_SET_OPTION_SUCCESS;
    }

    return evmc.EVMC_SET_OPTION_INVALID_NAME;
}

fn toEvmcAddress(addr: evmz.Address) evmc.evmc_address {
    return evmc.evmc_address{
        .bytes = addr,
    };
}

fn fromEvmcAddress(addr: evmc.evmc_address) evmz.Address {
    return addr.bytes;
}

fn fromEvmcBytes32(b: evmc.evmc_bytes32) u256 {
    return @bitCast(b.bytes);
}

fn toEvmcBytes32(v: u256) [*c]evmc.evmc_bytes32 {
    return @ptrCast(@constCast(&evmc.evmc_bytes32{
        .bytes = @bitCast(v),
    }));
}

const HostWrapper = struct {
    host_interfcace: [*c]const evmc.evmc_host_interface,
    context: *evmc.evmc_host_context,

    const Self = @This();

    pub fn toHost(self: *HostWrapper) evmz.Host {
        return evmz.Host{
            .ptr = self,
            .vtable = &.{
                .accountExists = accountExists,
                .getStorage = getStorage,
                .setStorage = setStorage,
                .getBalance = getBalance,
                .getCodeSize = getCodeSize,
                .getCodeHash = getCodeHash,
                .copyCode = copyCode,
                .emitLog = emitLog,
                .getBlockHash = getBlockHash,
                .getTxContext = getTxContext,
                .accessAccount = accessAccount,
                .accessStorage = accessStorage,
                .call = call,
                .selfDestruct = selfDestruct,
                .getTransientStorage = getTransientStorage,
                .setTransientStorage = setTransientStorage,
            },
        };
    }

    fn accountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.host_interfcace.*.account_exists.?(self.context, &toEvmcAddress(address));
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const value = self.host_interfcace.*.get_storage.?(self.context, &toEvmcAddress(address), toEvmcBytes32(key));
        return fromEvmcBytes32(value);
    }

    fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !evmz.Host.StorageStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const status = self.host_interfcace.*.set_storage.?(self.context, &toEvmcAddress(address), toEvmcBytes32(key), toEvmcBytes32(value));

        return @enumFromInt(status);
    }

    fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const balance = self.host_interfcace.*.get_balance.?(self.context, &toEvmcAddress(address));
        return fromEvmcBytes32(balance);
    }

    fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return @as(u256, self.host_interfcace.*.get_code_size.?(self.context, &toEvmcAddress(address)));
    }

    fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return fromEvmcBytes32(self.host_interfcace.*.get_code_hash.?(self.context, &toEvmcAddress(address)));
    }

    fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.host_interfcace.*.copy_code.?(self.context, &toEvmcAddress(address), code_offset, buffer_data.ptr, buffer_data.len);
    }

    fn emitLog(ptr: *anyopaque, address: Address, topcis: []const u256, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = address;
        _ = topcis;
        _ = data;
        // self.host_interfcace.*.emit_log.?(self.context, toEvmcAddress(address), topcis.ptr, topcis.len, data.ptr, data.len);
    }

    fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (number > std.math.maxInt(i64)) {
            return error.Overflow;
        }
        return fromEvmcBytes32(self.host_interfcace.*.get_block_hash.?(self.context, @intCast(number)));
    }

    fn getTxContext(ptr: *anyopaque) !evmz.Host.TxContext {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const context = self.host_interfcace.*.get_tx_context.?(self.context);
        return evmz.Host.TxContext{
            .base_fee = fromEvmcBytes32(context.block_base_fee),
            .blob_base_fee = fromEvmcBytes32(context.block_base_fee),
            // .blob_hashes = context.blob_hashes.*,
            .blob_hashes = &.{},
            .chain_id = fromEvmcBytes32(context.chain_id),
            .coinbase = fromEvmcAddress(context.block_coinbase),
            .gas_limit = @intCast(context.block_gas_limit),
            .gas_price = fromEvmcBytes32(context.tx_gas_price),
            .number = @intCast(context.block_number),
            .origin = fromEvmcAddress(context.tx_origin),
            .prev_randao = fromEvmcBytes32(context.block_prev_randao),
            .timestamp = @intCast(context.block_timestamp),
        };
    }

    fn accessAccount(ptr: *anyopaque, address: Address) !evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const status = self.host_interfcace.*.access_account.?(self.context, &toEvmcAddress(address));
        return @enumFromInt(status);
    }

    fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const status = self.host_interfcace.*.access_storage.?(self.context, &toEvmcAddress(address), toEvmcBytes32(key));
        return @enumFromInt(status);
    }

    fn call(ptr: *anyopaque, msg: evmz.Host.Message) !evmz.Host.Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const result = self.host_interfcace.*.call.?(self.context, &evmc.evmc_message{
            .kind = @intFromEnum(msg.kind),
            .flags = if (msg.is_static) evmc.EVMC_STATIC else 0,
            .input_data = @ptrCast(msg.input_data.ptr),
            .input_size = msg.input_data.len,
            .depth = msg.depth,
            .gas = msg.gas,
            .recipient = toEvmcAddress(msg.recipient),
            .sender = toEvmcAddress(msg.sender),
            .value = toEvmcBytes32(msg.value).*,
        });

        return evmz.Host.Result{
            .status = @enumFromInt(result.status_code),
            .gas_left = result.gas_left,
            .output_data = result.output_data[0..result.output_size],
            .create_address = fromEvmcAddress(result.create_address),
            .gas_refund = result.gas_refund,
        };
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.host_interfcace.*.selfdestruct.?(self.context, &toEvmcAddress(address), &toEvmcAddress(beneficiary));
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const value = self.host_interfcace.*.get_transient_storage.?(self.context, &toEvmcAddress(address), toEvmcBytes32(key));

        const r = fromEvmcBytes32(value);
        // TODO: fix zero
        if (r == 0) {
            return null;
        }
        return r;
    }

    fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.host_interfcace.*.set_transient_storage.?(self.context, &toEvmcAddress(address), toEvmcBytes32(key), toEvmcBytes32(value));
    }
};

fn revToSpec(rev: evmc.evmc_revision) error{UnmatchedSpec}!evmz.Spec {
    return switch (rev) {
        evmc.EVMC_FRONTIER => .frontier,
        evmc.EVMC_HOMESTEAD => .homestead,
        evmc.EVMC_TANGERINE_WHISTLE => .tangerine_whistle,
        evmc.EVMC_SPURIOUS_DRAGON => .spurious_dragon,
        evmc.EVMC_BYZANTIUM => .byzantium,
        evmc.EVMC_CONSTANTINOPLE => .constantinople,
        evmc.EVMC_PETERSBURG => .petersburg,
        evmc.EVMC_ISTANBUL => .istanbul,
        evmc.EVMC_BERLIN => .berlin,
        evmc.EVMC_LONDON => .london,
        evmc.EVMC_SHANGHAI => .shanghai,
        evmc.EVMC_CANCUN => .cancun,
        evmc.EVMC_PRAGUE => .prague,
        else => return error.UnmatchedSpec,
    };
}
