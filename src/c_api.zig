//! Implementation of the EVMC interface for evm.zig.
//! This is a proof of concept and not intended for production use.
const std = @import("std");
const evmz = @import("evm.zig");
const t = @import("t.zig");
const host2c = @import("./c_api/host2c.zig");
const mock = @import("./c_api/mock.zig");
const evmc = @import("./c_api/common.zig").evmc;

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
        ctx.host_context.deinit();
    }
}

export fn evmz_create_mock_host_context(tx_context: ?*evmc.evmc_tx_context) ?*evmc.evmc_host_context {
    const mock_context = MockHostContext.create(if (tx_context) |c| fromEvmcTxContext(c.*) else null) catch return null;
    return mock_context.toContext();
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

fn destroy(vm: [*c]evmc.evmc_vm) callconv(.c) void {
    const self: *allowzero Evmz = @alignCast(@fieldParentPtr("vm", vm));
    std.heap.c_allocator.destroy(self);
}

fn getCapabilities(vm: [*c]evmc.struct_evmc_vm) callconv(.c) evmc.evmc_capabilities {
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
) callconv(.c) evmc.evmc_result {
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
        .input_data = if (msg.*.input_size == 0) &.{} else msg.*.input_data[0..msg.*.input_size],
        .value = fromEvmcBytes32(msg.*.value),
        .is_static = msg.*.flags & evmc.EVMC_STATIC != 0,
        .code_address = fromEvmcAddress(msg.*.code_address),
    };

    var interpreter = evmz.Interpreter.init(std.heap.c_allocator, &host_, &message, code[0..code_size], spec);
    defer interpreter.deinit();
    const result = interpreter.execute();

    const status_code = statusToEvmc(result.status);
    const output_data = if (hasOutput(status_code)) result.output_data else &.{};
    return makeResult(status_code, result.gas_left, result.gas_refund, output_data, std.mem.zeroes(evmc.evmc_address));
}

fn release(result: [*c]const evmc.evmc_result) callconv(.c) void {
    const int = @intFromPtr(result.*.output_data);
    if (int == 0) {
        return;
    }
    const data_slice = @as([*]u8, @ptrCast(@constCast(result.*.output_data)))[0..result.*.output_size];
    std.heap.c_allocator.free(data_slice);
}

fn makeResult(
    status_code: evmc.evmc_status_code,
    gas_left: i64,
    gas_refund: i64,
    output_data: []const u8,
    create_address: evmc.evmc_address,
) evmc.evmc_result {
    var output_ptr: [*c]const u8 = null;
    var output_size: usize = 0;
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
                .padding = undefined,
            };
        };
        @memcpy(output_copy, output_data);
        output_ptr = output_copy.ptr;
        output_size = output_copy.len;
        release_fn = release;
    }

    return evmc.evmc_result{
        .status_code = status_code,
        .gas_left = if (keepsGasLeft(status_code)) gas_left else 0,
        .gas_refund = if (status_code == evmc.EVMC_SUCCESS) gas_refund else 0,
        .output_data = output_ptr,
        .output_size = output_size,
        .create_address = create_address,
        .release = release_fn,
        .padding = undefined,
    };
}

fn statusToEvmc(status: evmz.Interpreter.Status) evmc.evmc_status_code {
    return switch (status) {
        .success => evmc.EVMC_SUCCESS,
        .revert => evmc.EVMC_REVERT,
        .invalid => evmc.EVMC_INVALID_INSTRUCTION,
        .out_of_gas => evmc.EVMC_OUT_OF_GAS,
        .running => evmc.EVMC_FAILURE,
    };
}

fn statusFromEvmc(status_code: evmc.evmc_status_code) evmz.Interpreter.Status {
    return switch (status_code) {
        evmc.EVMC_SUCCESS => .success,
        evmc.EVMC_REVERT => .revert,
        evmc.EVMC_OUT_OF_GAS => .out_of_gas,
        else => .invalid,
    };
}

fn hasOutput(status_code: evmc.evmc_status_code) bool {
    return status_code == evmc.EVMC_SUCCESS or status_code == evmc.EVMC_REVERT;
}

fn keepsGasLeft(status_code: evmc.evmc_status_code) bool {
    return status_code == evmc.EVMC_SUCCESS or status_code == evmc.EVMC_REVERT;
}

fn setOption(
    vm: [*c]evmc.evmc_vm,
    name: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) evmc.evmc_set_option_result {
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
    return std.mem.readInt(u256, &b.bytes, .big);
}

fn toEvmcBytes32(v: u256) evmc.evmc_bytes32 {
    var result = std.mem.zeroes(evmc.evmc_bytes32);
    std.mem.writeInt(u256, &result.bytes, v, .big);
    return result;
}

fn fromEvmcTxContext(tx_context: evmc.evmc_tx_context) evmz.Host.TxContext {
    return evmz.Host.TxContext{
        .base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        .blob_base_fee = fromEvmcBytes32(tx_context.blob_base_fee),
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
        const evmc_address = toEvmcAddress(address);
        return self.host_interfcace.*.account_exists.?(self.context, &evmc_address);
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const value = self.host_interfcace.*.get_storage.?(self.context, &evmc_address, &evmc_key);
        return fromEvmcBytes32(value);
    }

    fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !evmz.Host.StorageStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const evmc_value = toEvmcBytes32(value);
        const status = self.host_interfcace.*.set_storage.?(self.context, &evmc_address, &evmc_key, &evmc_value);

        return @enumFromInt(status);
    }

    fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const balance = self.host_interfcace.*.get_balance.?(self.context, &evmc_address);
        return fromEvmcBytes32(balance);
    }

    fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        return @as(u256, self.host_interfcace.*.get_code_size.?(self.context, &evmc_address));
    }

    fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        return fromEvmcBytes32(self.host_interfcace.*.get_code_hash.?(self.context, &evmc_address));
    }

    fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        return self.host_interfcace.*.copy_code.?(self.context, &evmc_address, code_offset, buffer_data.ptr, buffer_data.len);
    }

    fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        var evmc_topics: [4]evmc.evmc_bytes32 = undefined;
        for (topics, 0..) |topic, i| {
            evmc_topics[i] = toEvmcBytes32(topic);
        }
        self.host_interfcace.*.emit_log.?(
            self.context,
            &evmc_address,
            data.ptr,
            data.len,
            &evmc_topics,
            topics.len,
        );
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
        const evmc_address = toEvmcAddress(address);
        const status = self.host_interfcace.*.access_account.?(self.context, &evmc_address);
        return @enumFromInt(status);
    }

    fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const status = self.host_interfcace.*.access_storage.?(self.context, &evmc_address, &evmc_key);
        return @enumFromInt(status);
    }

    fn call(ptr: *anyopaque, msg: evmz.Host.Message) !evmz.Host.Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const recipient = toEvmcAddress(msg.recipient);
        const sender = toEvmcAddress(msg.sender);
        const value = toEvmcBytes32(msg.value);
        const code_address = toEvmcAddress(msg.code_address);
        const create2_salt = toEvmcBytes32(msg.create2_salt);
        const result = self.host_interfcace.*.call.?(self.context, &evmc.evmc_message{
            .kind = @intFromEnum(msg.kind),
            .flags = if (msg.is_static) evmc.EVMC_STATIC else 0,
            .input_data = if (msg.input_data.len == 0) null else @ptrCast(msg.input_data.ptr),
            .input_size = msg.input_data.len,
            .depth = msg.depth,
            .gas = msg.gas,
            .recipient = recipient,
            .sender = sender,
            .value = value,
            .code_address = code_address,
            .create2_salt = create2_salt,
        });

        const output_data = if (result.output_data == null) &.{} else result.output_data[0..result.output_size];
        return evmz.Host.Result{
            .status = statusFromEvmc(result.status_code),
            .gas_left = result.gas_left,
            .output_data = output_data,
            .create_address = fromEvmcAddress(result.create_address),
            .gas_refund = result.gas_refund,
        };
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_beneficiary = toEvmcAddress(beneficiary);
        return self.host_interfcace.*.selfdestruct.?(self.context, &evmc_address, &evmc_beneficiary);
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const value = self.host_interfcace.*.get_transient_storage.?(self.context, &evmc_address, &evmc_key);

        const r = fromEvmcBytes32(value);
        if (r == 0) {
            return 0;
        }
        return r;
    }

    fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const evmc_value = toEvmcBytes32(value);
        self.host_interfcace.*.set_transient_storage.?(self.context, &evmc_address, &evmc_key, &evmc_value);
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

test "EVMC execute returns owned output through mock host" {
    const vm = evmc_create_evmz() orelse return error.OutOfMemory;
    defer vm.*.destroy.?(vm);

    var tx_context = std.mem.zeroes(evmc.evmc_tx_context);
    tx_context.block_gas_limit = 200_000;
    const context = evmz_create_mock_host_context(&tx_context) orelse return error.OutOfMemory;
    defer evmz_destroy_mock_host_context(context);

    const host = evmz_mock_host_interace();
    var msg = std.mem.zeroes(evmc.evmc_message);
    msg.kind = evmc.EVMC_CALL;
    msg.gas = 100_000;

    const code = [_]u8{
        0x60, 0x2a, 0x60, 0x00, 0x55, // SSTORE 0x2a at slot 0.
        0x60, 0x00, 0x54, // SLOAD slot 0.
        0x60, 0x00, 0x52, // MSTORE at offset 0.
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN 32 bytes.
    };

    var result = vm.*.execute.?(vm, &host, context, evmc.EVMC_CANCUN, &msg, &code, code.len);
    defer if (result.release) |release_result| release_result(&result);

    try std.testing.expectEqual(evmc.EVMC_SUCCESS, result.status_code);
    try std.testing.expectEqual(@as(usize, 32), result.output_size);
    try std.testing.expect(result.output_data != null);
    try std.testing.expectEqual(@as(u8, 0x2a), result.output_data[31]);
}
