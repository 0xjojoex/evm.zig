//! EVMC ABI compatibility adapter for evmz.
const std = @import("std");
const evmz = @import("evmz");
const common = @import("./c_api/common.zig");
const evmc = common.evmc;

const Address = evmz.Address;

const log = std.log.scoped(.evmc);

export fn evmc_create_evmz() ?*evmc.evmc_vm {
    const instance = std.heap.c_allocator.create(Evmz) catch return null;
    instance.* = Evmz.init();
    return &instance.vm;
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
                .set_option = setOption,
            },
        };
    }
};

fn destroy(vm: [*c]evmc.evmc_vm) callconv(.c) void {
    const self: *allowzero Evmz = @alignCast(@fieldParentPtr("vm", vm));
    std.heap.c_allocator.destroy(self);
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

    const revision = evmcRevisionToEthereumRevision(rev) catch |err| {
        log.err("execute failed: {}", .{err});
        return evmc.evmc_result{
            .status_code = evmc.EVMC_FAILURE,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = null,
            .output_size = 0,
            .release = release,
        };
    };

    var host_wrapper = ToHost.init(host, context);
    defer host_wrapper.deinit();

    var host_ = host_wrapper.toHost();

    const kind = common.callKindFromEvmc(msg.*.kind) catch |err| {
        log.err("execute failed: {}", .{err});
        return makeResult(evmc.EVMC_FAILURE, 0, 0, &.{});
    };
    const depth = std.math.cast(u16, msg.*.depth) orelse {
        log.err("execute failed: invalid message depth {}", .{msg.*.depth});
        return makeResult(evmc.EVMC_FAILURE, 0, 0, &.{});
    };
    const input_data = common.evmcInputData(msg.*.input_data, msg.*.input_size) catch |err| {
        log.err("execute failed: {}", .{err});
        return makeResult(evmc.EVMC_FAILURE, 0, 0, &.{});
    };

    const message = evmz.Host.Message{
        .kind = kind,
        .depth = depth,
        .gas = msg.*.gas,
        .recipient = fromEvmcAddress(msg.*.recipient),
        .sender = fromEvmcAddress(msg.*.sender),
        .input_data = input_data,
        .value = fromEvmcBytes32(msg.*.value),
        .is_static = msg.*.flags & evmc.EVMC_STATIC != 0,
        .code_address = fromEvmcAddress(msg.*.code_address),
    };

    return switch (revision) {
        inline else => |supported_revision| executeExact(
            @field(evmz.eth.Revision, @tagName(supported_revision)),
            &host_,
            &message,
            code[0..code_size],
        ),
    };
}

// TODO: per revision build by build options
fn executeExact(
    comptime revision: evmz.eth.Revision,
    host: *evmz.Host,
    message: *const evmz.Host.Message,
    code: []const u8,
) evmc.evmc_result {
    const ExactVm = evmz.Vm(evmz.eth.specAt(revision));
    var frame = ExactVm.Interpreter.OwnedCallFrame.init(std.heap.c_allocator, .{
        .host = host,
        .msg = message,
        .code = code,
    }) catch |err| {
        log.err("execute failed: {}", .{err});
        return makeResult(evmc.EVMC_OUT_OF_MEMORY, 0, 0, &.{});
    };
    defer frame.deinit();
    var interpreter = frame.interpreter();
    const result = interpreter.execute() catch |err| {
        log.err("execute failed: {}", .{err});
        const status_code: evmc.evmc_status_code = if (err == error.OutOfMemory)
            evmc.EVMC_OUT_OF_MEMORY
        else
            evmc.EVMC_FAILURE;
        return makeResult(status_code, 0, 0, &.{});
    };

    const status_code = statusToEvmc(result.status);
    const output_data = if (hasOutput(status_code)) result.output_data else &.{};
    return makeResult(status_code, result.gas_left, result.gas_refund, output_data);
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
                .release = null,
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
        .release = release_fn,
    };
}

fn statusToEvmc(status: evmz.Interpreter.Status) evmc.evmc_status_code {
    return switch (status) {
        .success => evmc.EVMC_SUCCESS,
        .revert => evmc.EVMC_REVERT,
        .invalid => evmc.EVMC_INVALID_INSTRUCTION,
        .out_of_gas => evmc.EVMC_OUT_OF_GAS,
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

const ToHost = struct {
    host_interfcace: [*c]const evmc.evmc_host_interface,
    context: ?*evmc.evmc_host_context,
    blob_hashes: [common.max_blob_hashes]u256 = undefined,
    call_output: std.ArrayList(u8) = .empty,

    const Self = @This();

    pub fn init(host_interfcace: [*c]const evmc.evmc_host_interface, context: ?*evmc.evmc_host_context) Self {
        return .{
            .host_interfcace = host_interfcace,
            .context = context,
        };
    }

    pub fn deinit(self: *Self) void {
        self.call_output.deinit(std.heap.c_allocator);
    }

    pub fn toHost(self: *ToHost) evmz.Host {
        return evmz.Host{
            .ptr = self,
            .vtable = &.{
                .accountExists = accountExists,
                .getStorage = getStorage,
                .setStorage = setStorage,
                .loadStorage = loadStorage,
                .storeStorage = storeStorage,
                .getBalance = getBalance,
                .getNonce = getNonce,
                .getCodeSize = getCodeSize,
                .getCodeHash = getCodeHash,
                .copyCode = copyCode,
                .emitLog = emitLog,
                .getBlockHash = getBlockHash,
                .getTxContext = getTxContext,
                .accessAccount = accessAccount,
                .accessStorage = accessStorage,
                .accessDelegatedAccount = accessDelegatedAccount,
                .observeAccountAccess = observeAccountAccess,
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
        return self.host_interfcace.*.account_exists.?(self.context, &evmc_address) != 0;
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
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

        return storageStatusFromEvmc(status);
    }

    fn loadStorage(ptr: *anyopaque, address: Address, key: u256) !evmz.Host.StorageLoadResult {
        return .{
            .access_status = try accessStorage(ptr, address, key),
            .value = try getStorage(ptr, address, key),
        };
    }

    fn storeStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !evmz.Host.StorageStoreResult {
        return .{
            .access_status = try accessStorage(ptr, address, key),
            .storage_status = try setStorage(ptr, address, key, value),
        };
    }

    fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const balance = self.host_interfcace.*.get_balance.?(self.context, &evmc_address);
        return fromEvmcBytes32(balance);
    }

    fn getNonce(ptr: *anyopaque, address: Address) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        return self.host_interfcace.*.get_nonce.?(self.context, &evmc_address);
    }

    fn observeAccountAccess(ptr: *anyopaque, address: Address, _: u16) !void {
        _ = try accessAccount(ptr, address);
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
        return common.fromEvmcTxContext(context, &self.blob_hashes);
    }

    fn accessAccount(ptr: *anyopaque, address: Address) !evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const status = self.host_interfcace.*.access_account.?(self.context, &evmc_address);
        return accessStatusFromEvmc(status);
    }

    fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_key = toEvmcBytes32(key);
        const status = self.host_interfcace.*.access_storage.?(self.context, &evmc_address, &evmc_key);
        return accessStatusFromEvmc(status);
    }

    fn accessDelegatedAccount(ptr: *anyopaque, address: Address) !?evmz.Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const target = try self.delegatedCodeTarget(address) orelse return null;
        const evmc_target = toEvmcAddress(target);
        const status = self.host_interfcace.*.access_account.?(self.context, &evmc_target);
        const access_status = try accessStatusFromEvmc(status);
        return access_status;
    }

    fn call(ptr: *anyopaque, msg: evmz.Host.Message) !evmz.Host.Result {
        if (evmz.Host.precheckResult(msg)) |result| return result;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const recipient = toEvmcAddress(msg.recipient);
        const sender = toEvmcAddress(msg.sender);
        const value = toEvmcBytes32(msg.value);
        var flags: u32 = if (msg.is_static) evmc.EVMC_STATIC else 0;
        var code_address = msg.code_address;
        if (msg.kind != .create and msg.kind != .create2) {
            if (try self.delegatedCodeTarget(msg.code_address)) |target| {
                code_address = target;
                flags |= evmc.EVMC_DELEGATED;
            }
        }
        const evmc_code_address = toEvmcAddress(code_address);
        const result = self.host_interfcace.*.call.?(self.context, &evmc.evmc_message{
            .kind = common.callKindToEvmc(msg.kind),
            .flags = flags,
            .input_data = if (msg.input_data.len == 0) null else @ptrCast(msg.input_data.ptr),
            .input_size = msg.input_data.len,
            .depth = msg.depth,
            .gas = msg.gas,
            .recipient = recipient,
            .sender = sender,
            .value = value,
            .code_address = evmc_code_address,
            .code = null,
            .code_size = 0,
        });
        defer if (result.release) |release_result| release_result(&result);

        const output_data = if (result.output_data == null) &.{} else result.output_data[0..result.output_size];
        try self.call_output.resize(std.heap.c_allocator, output_data.len);
        @memcpy(self.call_output.items, output_data);
        const call_result = evmz.Host.CallResult{
            .status = statusFromEvmc(result.status_code),
            .gas_left = result.gas_left,
            .output_data = self.call_output.items,
            .gas_refund = result.gas_refund,
        };
        return switch (msg.kind) {
            .create, .create2 => evmz.Host.Result.fromCreate(msg.recipient, call_result),
            else => evmz.Host.Result.fromCall(call_result),
        };
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const evmc_address = toEvmcAddress(address);
        const evmc_beneficiary = toEvmcAddress(beneficiary);
        return self.host_interfcace.*.selfdestruct.?(self.context, &evmc_address, &evmc_beneficiary) != 0;
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
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

    fn delegatedCodeTarget(self: *Self, address: Address) !?Address {
        const evmc_address = toEvmcAddress(address);
        const code_size = self.host_interfcace.*.get_code_size.?(self.context, &evmc_address);
        if (code_size != evmz.eip7702.delegation_code_len) return null;

        var code: [evmz.eip7702.delegation_code_len]u8 = undefined;
        const copied = self.host_interfcace.*.copy_code.?(self.context, &evmc_address, 0, &code, code.len);
        if (copied != code.len) return null;
        return evmz.eip7702.delegationTarget(&code);
    }
};

fn storageStatusFromEvmc(status: evmc.evmc_storage_status) !evmz.Host.StorageStatus {
    return switch (status) {
        evmc.EVMC_STORAGE_ASSIGNED => .assigned,
        evmc.EVMC_STORAGE_ADDED => .added,
        evmc.EVMC_STORAGE_DELETED => .deleted,
        evmc.EVMC_STORAGE_MODIFIED => .modified,
        evmc.EVMC_STORAGE_DELETED_ADDED => .deleted_added,
        evmc.EVMC_STORAGE_MODIFIED_DELETED => .modified_deleted,
        evmc.EVMC_STORAGE_DELETED_RESTORED => .deleted_restored,
        evmc.EVMC_STORAGE_ADDED_DELETED => .added_deleted,
        evmc.EVMC_STORAGE_MODIFIED_RESTORED => .modified_restored,
        else => error.InvalidStorageStatus,
    };
}

fn accessStatusFromEvmc(status: evmc.evmc_access_status) !evmz.Host.AccessStatus {
    return switch (status) {
        evmc.EVMC_ACCESS_COLD => .cold,
        evmc.EVMC_ACCESS_WARM => .warm,
        else => error.InvalidAccessStatus,
    };
}

const SupportedRevision = enum {
    frontier,
    homestead,
    tangerine_whistle,
    spurious_dragon,
    byzantium,
    petersburg,
    istanbul,
    berlin,
    london,
    merge,
    shanghai,
    cancun,
    prague,
    osaka,
    amsterdam,
};

fn evmcRevisionToEthereumRevision(rev: evmc.evmc_revision) error{UnmatchedRevision}!SupportedRevision {
    return switch (rev) {
        evmc.EVMC_FRONTIER => .frontier,
        evmc.EVMC_HOMESTEAD => .homestead,
        evmc.EVMC_TANGERINE_WHISTLE => .tangerine_whistle,
        evmc.EVMC_SPURIOUS_DRAGON => .spurious_dragon,
        evmc.EVMC_BYZANTIUM => .byzantium,
        evmc.EVMC_PETERSBURG => .petersburg,
        evmc.EVMC_ISTANBUL => .istanbul,
        evmc.EVMC_BERLIN => .berlin,
        evmc.EVMC_LONDON => .london,
        evmc.EVMC_PARIS => .merge,
        evmc.EVMC_SHANGHAI => .shanghai,
        evmc.EVMC_CANCUN => .cancun,
        evmc.EVMC_PRAGUE => .prague,
        evmc.EVMC_OSAKA => .osaka,
        evmc.EVMC_AMSTERDAM => .amsterdam,
        else => return error.UnmatchedRevision,
    };
}

extern fn evmz_evmc_abi18_smoke(
    host: [*c]const evmc.evmc_host_interface,
    context: ?*evmc.evmc_host_context,
    account: [*c]const evmc.evmc_address,
    beneficiary: [*c]const evmc.evmc_address,
) callconv(.c) c_int;

test "EVMC ABI 18 callbacks cross the real C23 boundary" {
    const t = evmz.t;
    const host2c = @import("./c_api/host2c.zig");
    const account_address = evmz.addr(0x18);
    const beneficiary_address = evmz.addr(0x19);
    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    try mock_host.local_account.put(account_address, .{ .nonce = 7, .balance = 1 });

    var native_host = mock_host.host();
    var bridge = host2c.HostContext.borrowed(&native_host);
    const interface = host2c.getInterface();
    const evmc_address = toEvmcAddress(account_address);
    const evmc_beneficiary = toEvmcAddress(beneficiary_address);

    try std.testing.expectEqual(@as(c_int, 0), evmz_evmc_abi18_smoke(
        &interface,
        bridge.toContext(),
        &evmc_address,
        &evmc_beneficiary,
    ));
}

test "EVMC ABI 18 nonce callback round-trips through both host adapters" {
    const t = evmz.t;
    const host2c = @import("./c_api/host2c.zig");
    const account_address = evmz.addr(0x18);
    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    try mock_host.local_account.put(account_address, .{ .nonce = 7, .balance = 0 });

    var native_host = mock_host.host();
    var bridge = host2c.HostContext.borrowed(&native_host);
    const interface = host2c.getInterface();
    const evmc_address = toEvmcAddress(account_address);
    try std.testing.expectEqual(@as(u64, 7), interface.get_nonce.?(bridge.toContext(), &evmc_address));

    var wrapper = ToHost.init(&interface, bridge.toContext());
    defer wrapper.deinit();
    var round_tripped_host = wrapper.toHost();
    try std.testing.expectEqual(@as(u64, 7), try round_tripped_host.getNonce(account_address));
}

test "EVMC execute returns owned output through mock host" {
    const host2c = @import("./c_api/host2c.zig");
    const mock = @import("./c_api/mock.zig");
    const vm = evmc_create_evmz() orelse return error.OutOfMemory;
    defer vm.*.destroy.?(vm);

    var tx_context = std.mem.zeroes(evmc.evmc_tx_context);
    tx_context.block_gas_limit = 200_000;
    const mock_context = try mock.MockHostContext.create(tx_context);
    defer mock_context.host_context.deinit();
    const context = mock_context.toContext();

    const host = host2c.getInterface();
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

test "EVMC Paris revision maps to Merge revision" {
    try std.testing.expectEqual(SupportedRevision.merge, try evmcRevisionToEthereumRevision(evmc.EVMC_PARIS));
}

test "EVMC execute carries blob hashes through tx context" {
    const host2c = @import("./c_api/host2c.zig");
    const mock = @import("./c_api/mock.zig");
    const vm = evmc_create_evmz() orelse return error.OutOfMemory;
    defer vm.*.destroy.?(vm);

    const blob_hash = (@as(u256, 0x01) << 248) | 0x1234;
    var blob_hashes = [_]evmc.evmc_bytes32{toEvmcBytes32(blob_hash)};
    var tx_context = std.mem.zeroes(evmc.evmc_tx_context);
    tx_context.block_gas_limit = 200_000;
    tx_context.blob_hashes = &blob_hashes;
    tx_context.blob_hashes_count = blob_hashes.len;

    const mock_context = try mock.MockHostContext.create(tx_context);
    defer mock_context.host_context.deinit();
    const context = mock_context.toContext();

    const host = host2c.getInterface();
    var msg = std.mem.zeroes(evmc.evmc_message);
    msg.kind = evmc.EVMC_CALL;
    msg.gas = 100_000;

    const code = [_]u8{
        0x60, 0x00, 0x49, // BLOBHASH index 0.
        0x60, 0x00, 0x52, // MSTORE at offset 0.
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN 32 bytes.
    };

    var result = vm.*.execute.?(vm, &host, context, evmc.EVMC_CANCUN, &msg, &code, code.len);
    defer if (result.release) |release_result| release_result(&result);

    try std.testing.expectEqual(evmc.EVMC_SUCCESS, result.status_code);
    try std.testing.expectEqual(@as(usize, 32), result.output_size);
    try std.testing.expect(result.output_data != null);
    try std.testing.expectEqualSlices(u8, &blob_hashes[0].bytes, result.output_data[0..32]);
}

test "EVMC host wrapper provides required fused storage callbacks" {
    const StorageHostContext = struct {
        const Event = enum { access, get, set };

        events: [4]Event = undefined,
        events_len: usize = 0,
        value: u256 = 7,

        fn fromContext(context: ?*evmc.evmc_host_context) *@This() {
            return @ptrCast(@alignCast(context.?));
        }

        fn record(self: *@This(), event: Event) void {
            self.events[self.events_len] = event;
            self.events_len += 1;
        }

        fn accessStorage(
            context: ?*evmc.evmc_host_context,
            _: [*c]const evmc.evmc_address,
            _: [*c]const evmc.evmc_bytes32,
        ) callconv(.c) evmc.evmc_access_status {
            const self = fromContext(context);
            self.record(.access);
            return evmc.EVMC_ACCESS_COLD;
        }

        fn getStorage(
            context: ?*evmc.evmc_host_context,
            _: [*c]const evmc.evmc_address,
            _: [*c]const evmc.evmc_bytes32,
        ) callconv(.c) evmc.evmc_bytes32 {
            const self = fromContext(context);
            self.record(.get);
            return toEvmcBytes32(self.value);
        }

        fn setStorage(
            context: ?*evmc.evmc_host_context,
            _: [*c]const evmc.evmc_address,
            _: [*c]const evmc.evmc_bytes32,
            value: [*c]const evmc.evmc_bytes32,
        ) callconv(.c) evmc.evmc_storage_status {
            const self = fromContext(context);
            self.record(.set);
            self.value = fromEvmcBytes32(value.*);
            return evmc.EVMC_STORAGE_MODIFIED;
        }
    };

    var context = StorageHostContext{};
    const host_context: ?*evmc.evmc_host_context = @ptrCast(&context);
    const interface = evmc.evmc_host_interface{
        .get_storage = StorageHostContext.getStorage,
        .set_storage = StorageHostContext.setStorage,
        .access_storage = StorageHostContext.accessStorage,
    };

    var wrapper = ToHost.init(&interface, host_context);
    defer wrapper.deinit();
    var host = wrapper.toHost();

    const address = evmz.addr(0xbeef);
    const loaded = try host.loadStorage(address, 3);
    try std.testing.expectEqual(evmz.Host.AccessStatus.cold, loaded.access_status);
    try std.testing.expectEqual(@as(u256, 7), loaded.value);
    try std.testing.expectEqualSlices(StorageHostContext.Event, &.{ .access, .get }, context.events[0..context.events_len]);

    context.events_len = 0;
    const stored = try host.storeStorage(address, 3, 9);
    try std.testing.expectEqual(evmz.Host.AccessStatus.cold, stored.access_status);
    try std.testing.expectEqual(evmz.Host.StorageStatus.modified, stored.storage_status);
    try std.testing.expectEqual(@as(u256, 9), context.value);
    try std.testing.expectEqualSlices(StorageHostContext.Event, &.{ .access, .set }, context.events[0..context.events_len]);
}

test "EVMC host wrapper resolves delegated target and owns call output" {
    const DelegatedHostContext = struct {
        authority: Address,
        target: Address,
        code: [evmz.eip7702.delegation_code_len]u8,
        accessed: ?Address = null,
        last_msg: ?evmc.evmc_message = null,
        output: [2]u8 = .{ 0xaa, 0xbb },

        fn init(authority: Address, target: Address) @This() {
            var self = @This(){
                .authority = authority,
                .target = target,
                .code = undefined,
            };
            evmz.eip7702.writeDelegationCode(&self.code, target);
            return self;
        }

        fn fromContext(context: ?*evmc.evmc_host_context) *@This() {
            return @ptrCast(@alignCast(context.?));
        }

        fn getCodeSize(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) usize {
            const self = fromContext(context);
            const requested = fromEvmcAddress(address.*);
            if (!std.mem.eql(u8, &requested, &self.authority)) return 0;
            return self.code.len;
        }

        fn copyCode(
            context: ?*evmc.evmc_host_context,
            address: [*c]const evmc.evmc_address,
            code_offset: usize,
            buffer_data: [*c]u8,
            buffer_size: usize,
        ) callconv(.c) usize {
            const self = fromContext(context);
            const requested = fromEvmcAddress(address.*);
            if (!std.mem.eql(u8, &requested, &self.authority)) return 0;
            if (code_offset >= self.code.len) return 0;
            const copied = @min(buffer_size, self.code.len - code_offset);
            @memcpy(buffer_data[0..copied], self.code[code_offset..][0..copied]);
            return copied;
        }

        fn accessAccount(context: ?*evmc.evmc_host_context, address: [*c]const evmc.evmc_address) callconv(.c) evmc.evmc_access_status {
            const self = fromContext(context);
            self.accessed = fromEvmcAddress(address.*);
            return evmc.EVMC_ACCESS_COLD;
        }

        fn call(context: ?*evmc.evmc_host_context, msg: [*c]const evmc.evmc_message) callconv(.c) evmc.evmc_result {
            const self = fromContext(context);
            self.last_msg = msg.*;
            return evmc.evmc_result{
                .status_code = evmc.EVMC_SUCCESS,
                .gas_left = msg.*.gas,
                .gas_refund = 0,
                .output_data = &self.output,
                .output_size = self.output.len,
                .release = null,
            };
        }
    };

    const authority = evmz.addr(0x7702);
    const target = evmz.addr(0x1234);
    var context = DelegatedHostContext.init(authority, target);
    const host_context: ?*evmc.evmc_host_context = @ptrCast(&context);
    const interface = evmc.evmc_host_interface{
        .get_code_size = DelegatedHostContext.getCodeSize,
        .copy_code = DelegatedHostContext.copyCode,
        .access_account = DelegatedHostContext.accessAccount,
        .call = DelegatedHostContext.call,
    };

    var wrapper = ToHost.init(&interface, host_context);
    defer wrapper.deinit();
    var host = wrapper.toHost();

    const delegated_access = (try host.accessDelegatedAccount(authority)).?;
    try std.testing.expectEqual(evmz.Host.AccessStatus.cold, delegated_access);
    try std.testing.expectEqualSlices(u8, &target, &context.accessed.?);

    const result = (try host.call(.{
        .depth = 0,
        .kind = .call,
        .gas = 7,
        .recipient = authority,
        .sender = evmz.addr(0x01),
        .input_data = &.{},
        .value = 0,
        .code_address = authority,
    })).expectCall();

    try std.testing.expect(context.last_msg.?.flags & evmc.EVMC_DELEGATED != 0);
    try std.testing.expectEqualSlices(u8, &target, &fromEvmcAddress(context.last_msg.?.code_address));
    context.output[0] = 0xcc;
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, result.output_data);
}
