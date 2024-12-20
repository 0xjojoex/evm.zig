//! Implementation of the EVMC interface for evm.zig.
//! This is a proof of concept and not intended for production use.
const evmc = @cImport({
    @cInclude("evmc.h");
});

const std = @import("std");
const evmz = @import("evm.zig");
const t = @import("t.zig");
const host2c = @import("./c_api/host2c.zig");
const mock = @import("./c_api/mock.zig");

const MockHostContext = mock.MockHostContext;

const Address = evmz.Address;

const log = std.log.scoped(.evmc);

export fn evmc_create_evmz() ?*evmc.evmc_vm {
    const instance = std.heap.c_allocator.create(Evmz) catch return null;
    instance.* = Evmz.init();
    return &instance.vm;
}

export fn evmz_destroy_mock_host_context(context: ?*evmc.evmc_host_context) void {
    if (MockHostContext.fromContext(context)) |ctx| {
        ctx.deinit();
        std.heap.c_allocator.destroy(ctx);
    }
}

export fn evmz_create_mock_host_context(tx_context: ?*evmc.evmc_tx_context) ?*evmc.evmc_host_context {
    var mock_host = t.MockHost.init(std.heap.c_allocator, if (tx_context) |c| fromEvmcTxContext(c.*) else null);
    const ctx = std.heap.c_allocator.create(host2c.HostContext) catch {
        return null;
    };
    var mock_context = MockHostContext{
        .mock_host = &mock_host,
    };
    const context = mock_context.toContext();
    ctx.* = context;
    return @ptrCast(@alignCast(ctx.toContext()));
}

// const interface = host2c.getInterface();
export fn evmz_mock_host_interace() evmc.evmc_host_interface {
    return host2c.getInterface();
}

const Evmz = struct {
    vm: evmc.evmc_vm,

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

fn destroy(vm: [*c]evmc.evmc_vm) callconv(.C) void {
    const self: *allowzero Evmz = @alignCast(@fieldParentPtr("vm", vm));
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
    _ = vm;

    const spec = revToSpec(rev) catch |err| {
        log.err("execute failed: {}", .{err});
        return evmc.evmc_result{
            .status_code = evmc.EVMC_FAILURE,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = null,
            .output_size = 0,
            .create_address = std.mem.zeroes(evmc.evmc_address),
            .release = release,
            .padding = undefined,
        };
    };

    var host_wrapper = ToHost.init(host, context);

    var host_ = host_wrapper.toHost();

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

    var interpreter = evmz.Interpreter.init(std.heap.c_allocator, &host_, &message, code[0..code_size], spec);
    defer interpreter.deinit();
    const result = interpreter.execute();

    // Still trying to figure out why init twice made the execution pass
    {
        var interpreter2 = evmz.Interpreter.init(std.heap.c_allocator, &host_, &message, code[0..code_size], spec);
        defer interpreter2.deinit();
    }

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

fn release(result: [*c]const evmc.evmc_result) callconv(.C) void {
    // log.debug("release result {x}\n", .{result.output_data});
    //
    const int = @intFromPtr(result.*.output_data);
    if (int == 0) {
        return;
    }
    const data_slice = @as([*]const u8, @ptrCast(result.*.output_data))[0..result.*.output_size];
    std.heap.c_allocator.free(data_slice);
}

fn setOption(
    vm: [*c]evmc.evmc_vm,
    name: [*c]const u8,
    value: [*c]const u8,
) callconv(.C) evmc.evmc_set_option_result {
    _ = vm;
    _ = name;
    _ = value;
    // const self: *Evmz = @fieldParentPtr("vm", vm);

    // const name_str = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    // const value_str = std.mem.span(@as([*:0]const u8, @ptrCast(value)));

    // log.debug("set_option {s} {s}", .{ name, value });
    // if (std.mem.eql(u8, name_str, "rev")) {
    //     const number = std.fmt.parseInt(c_uint, value_str, 10) catch {
    //         return evmc.EVMC_SET_OPTION_INVALID_VALUE;
    //     };

    //     self.spec = revToSpec(number) catch |err| {
    //         log.err("set_option failed: {}", .{err});
    //         return evmc.EVMC_SET_OPTION_INVALID_VALUE;
    //     };
    //     return evmc.EVMC_SET_OPTION_SUCCESS;
    // }

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

fn fromEvmcTxContext(tx_context: evmc.evmc_tx_context) evmz.Host.TxContext {
    return evmz.Host.TxContext{
        .base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        .blob_base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        // .blob_hashes = tx_context.blob_hashes.*,
        .blob_hashes = &.{},
        .chain_id = fromEvmcBytes32(tx_context.chain_id),
        .coinbase = fromEvmcAddress(tx_context.block_coinbase),
        .gas_limit = @intCast(tx_context.block_gas_limit),
        .gas_price = fromEvmcBytes32(tx_context.tx_gas_price),
        .number = @intCast(tx_context.block_number),
        .origin = fromEvmcAddress(tx_context.tx_origin),
        .prev_randao = fromEvmcBytes32(tx_context.block_prev_randao),
        .timestamp = @intCast(tx_context.block_timestamp),
    };
}

const ToHost = extern struct {
    host_interfcace: [*c]const evmc.evmc_host_interface,
    context: ?*evmc.evmc_host_context,

    comptime {
        std.debug.assert(@alignOf(ToHost) == @alignOf(*evmc.evmc_host_interface));
    }

    const Self = @This();

    pub fn init(host_interfcace: [*c]const evmc.evmc_host_interface, context: ?*evmc.evmc_host_context) Self {
        return .{
            .host_interfcace = host_interfcace,
            .context = context,
        };
    }

    pub fn toHost(self: *ToHost) evmz.Host {
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
        return fromEvmcTxContext(context);
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
        if (r == 0) {
            return 0;
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
