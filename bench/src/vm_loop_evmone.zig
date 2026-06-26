const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const Host = common.Host;
const c_api = evmz.c_api;
const evmc = c_api.evmc;
const evmc_common = c_api.common;
const host2c = c_api.host2c;

extern fn evmc_create_evmone() ?*evmc.evmc_vm;

pub const Mode = enum {
    baseline,
    advanced,
};

pub const Runner = struct {
    vm: *evmc.evmc_vm,

    pub fn init(mode: Mode) !Runner {
        const vm = evmc_create_evmone() orelse return error.EvmoneCreateFailed;
        errdefer vm.*.destroy.?(vm);

        if (mode == .advanced) {
            const option_result = vm.*.set_option.?(vm, "advanced", "");
            if (option_result != evmc.EVMC_SET_OPTION_SUCCESS) return error.EvmoneOptionFailed;
        }

        return .{ .vm = vm };
    }

    pub fn deinit(self: *Runner) void {
        self.vm.*.destroy.?(self.vm);
    }

    pub fn deployRuntime(
        self: *Runner,
        allocator: std.mem.Allocator,
        host: *Host,
        contract_code: []const u8,
        spec: evmz.Spec,
    ) ![]u8 {
        const result = try self.execute(allocator, host, .create, contract_code, &.{}, spec);
        return result.output_data;
    }

    pub fn timeRuntimeCall(
        self: *Runner,
        allocator: std.mem.Allocator,
        host: *Host,
        runtime_code: []const u8,
        call_data: []const u8,
        spec: evmz.Spec,
    ) !u64 {
        const result = try self.execute(allocator, host, .call, runtime_code, call_data, spec);
        defer allocator.free(result.output_data);
        return result.elapsed_ns;
    }

    fn execute(
        self: *Runner,
        allocator: std.mem.Allocator,
        host: *Host,
        kind: CallKind,
        code: []const u8,
        input: []const u8,
        spec: evmz.Spec,
    ) !ExecutionResult {
        var context = host2c.HostContext.borrowed(host);
        const host_interface = host2c.getInterface();
        var message = std.mem.zeroes(evmc.evmc_message);
        message.kind = switch (kind) {
            .call => evmc.EVMC_CALL,
            .create => evmc.EVMC_CREATE,
        };
        message.gas = common.max_gas;
        message.recipient = evmc_common.toEvmcAddress(common.contract_address);
        message.sender = evmc_common.toEvmcAddress(common.caller_address);
        message.code_address = evmc_common.toEvmcAddress(common.contract_address);
        message.input_data = if (input.len == 0) null else input.ptr;
        message.input_size = input.len;

        const code_ptr: [*c]const u8 = if (code.len == 0) null else code.ptr;
        const start_ns = try common.monotonicNowNs();
        var result = self.vm.*.execute.?(
            self.vm,
            &host_interface,
            context.toContext(),
            revFromSpec(spec),
            &message,
            code_ptr,
            code.len,
        );
        const end_ns = try common.monotonicNowNs();
        defer releaseResult(&result);

        if (result.status_code != evmc.EVMC_SUCCESS) return error.EvmoneExecutionFailed;
        const output = if (result.output_size == 0)
            try allocator.dupe(u8, &.{})
        else
            try allocator.dupe(u8, result.output_data[0..result.output_size]);

        return .{
            .elapsed_ns = end_ns - start_ns,
            .output_data = output,
        };
    }
};

pub fn deployRuntime(
    allocator: std.mem.Allocator,
    host: *Host,
    contract_code: []const u8,
    spec: evmz.Spec,
    mode: Mode,
) ![]u8 {
    var runner = try Runner.init(mode);
    defer runner.deinit();
    return runner.deployRuntime(allocator, host, contract_code, spec);
}

pub fn timeRuntimeCall(
    allocator: std.mem.Allocator,
    host: *Host,
    runtime_code: []const u8,
    call_data: []const u8,
    spec: evmz.Spec,
    mode: Mode,
) !u64 {
    var runner = try Runner.init(mode);
    defer runner.deinit();
    return runner.timeRuntimeCall(allocator, host, runtime_code, call_data, spec);
}

const CallKind = enum {
    call,
    create,
};

const ExecutionResult = struct {
    elapsed_ns: u64,
    output_data: []u8,
};

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
    };
}

test "evmone deploys and runs empty runtime" {
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x0c, 0x60, 0x00, 0x39, 0x60, 0x01, 0x60, 0x00, 0xf3, 0x00 };

    var deploy_host = common.CountingHost.init(std.testing.allocator, .null);
    defer deploy_host.deinit();
    var deploy_host_iface = deploy_host.host();
    const runtime = try deployRuntime(std.testing.allocator, &deploy_host_iface, &init_code, .latest, .baseline);
    defer std.testing.allocator.free(runtime);

    try std.testing.expectEqualSlices(u8, &.{0x00}, runtime);

    var run_host = common.CountingHost.init(std.testing.allocator, .null);
    defer run_host.deinit();
    var run_host_iface = run_host.host();
    _ = try timeRuntimeCall(std.testing.allocator, &run_host_iface, runtime, &.{}, .latest, .baseline);
    try std.testing.expectEqual(@as(u64, 0), run_host.counters.total());
}
