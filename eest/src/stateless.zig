const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");

const JsonValue = fixture_common.JsonValue;
const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const parseBytesFromValue = fixture_common.parseBytesFromValue;

pub const Options = struct {
    test_filter: ?[]const u8 = null,
    limit: usize = 0,
    verbose: bool = false,
    trace_mismatch: bool = false,
    classify_failures: bool = false,
    ere_public: bool = false,
};

pub const FailReason = enum(u8) {
    malformed_fixture,
    missing_stateless_output,
    validation_error,
    output_mismatch,
    public_values_mismatch,
    unexpected_success,
    unexpected_failure,
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| target.* += value;
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options) !Summary {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var summary = try runSlice(allocator, bytes, options, path);
    summary.files = 1;
    return summary;
}

pub fn runSlice(allocator: std.mem.Allocator, bytes: []const u8, options: Options, path: []const u8) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }
        try runFixture(allocator, path, test_name, entry.value_ptr.*, options, &summary);
        if (options.limit > 0 and summary.fixtures >= options.limit) break;
    }
    return summary;
}

fn runFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    fixture: JsonValue,
    options: Options,
    summary: *Summary,
) !void {
    const object = asObject(fixture) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    const blocks = asArray(object.get("blocks") orelse {
        summary.countFail(.malformed_fixture);
        return;
    }) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };

    for (blocks.items, 0..) |block_value, block_index| {
        if (options.limit > 0 and summary.fixtures >= options.limit) return;
        const block = asObject(block_value) orelse {
            summary.countFail(.malformed_fixture);
            continue;
        };
        const input_value = block.get("statelessInputBytes") orelse {
            summary.skipped += 1;
            continue;
        };
        const input_bytes = parseBytesFromValue(allocator, input_value) catch {
            summary.countFail(.malformed_fixture);
            continue;
        };
        defer allocator.free(input_bytes);
        summary.fixtures += 1;

        const expected_success = block.get("expectException") == null;
        const result = evmz.stateless.ere.runStatelessValidator(allocator, input_bytes) catch |err| {
            if (options.verbose) std.debug.print("  validation error: {s}\n", .{@errorName(err)});
            if (options.classify_failures) printValidationClassification(path, test_name, block_index, expected_success, err);
            summary.countFail(.validation_error);
            continue;
        };
        defer result.deinit(allocator);

        if (block.get("statelessOutputBytes")) |expected_value| {
            const expected_output = parseBytesFromValue(allocator, expected_value) catch {
                summary.countFail(.malformed_fixture);
                continue;
            };
            defer allocator.free(expected_output);
            if (options.ere_public) {
                const expected_public = evmz.stateless.ere.outputPublicValues(expected_output);
                if (!std.mem.eql(u8, &result.public_values, &expected_public)) {
                    if (options.verbose) printPublicMismatch(allocator, input_bytes, result.output, expected_output, result.public_values, expected_public, options.trace_mismatch);
                    summary.countFail(.public_values_mismatch);
                    continue;
                }
            } else {
                if (!std.mem.eql(u8, result.output, expected_output)) {
                    if (options.verbose) printMismatch(allocator, input_bytes, result.output, expected_output, options.trace_mismatch);
                    if (options.classify_failures) printOutputClassification(allocator, path, test_name, block_index, input_bytes, result.output, expected_output);
                    summary.countFail(.output_mismatch);
                    continue;
                }
            }
            summary.passed += 1;
            continue;
        }

        const actual = evmz.stateless.wire.StatelessValidationResult.decode(allocator, result.output) catch {
            summary.countFail(.missing_stateless_output);
            continue;
        };
        if (actual.successful_validation and !expected_success) {
            summary.countFail(.unexpected_success);
        } else if (!actual.successful_validation and expected_success) {
            summary.countFail(.unexpected_failure);
        } else {
            summary.passed += 1;
        }
    }
}

test "stateless zkevm runner compares canonical SSZ bytes" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const output = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    const input_hex = try hexAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(input_hex);
    const output_hex = try hexAlloc(std.testing.allocator, output);
    defer std.testing.allocator.free(output_hex);
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"smoke":{{"blocks":[{{"statelessInputBytes":"0x{s}","statelessOutputBytes":"0x{s}"}}]}}}}
    , .{ input_hex, output_hex });
    defer std.testing.allocator.free(fixture);

    const summary = try runSlice(std.testing.allocator, fixture, .{}, "smoke.json");
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    const ere_summary = try runSlice(std.testing.allocator, fixture, .{ .ere_public = true }, "smoke.json");
    try std.testing.expectEqual(@as(usize, 1), ere_summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), ere_summary.passed);
    try std.testing.expectEqual(@as(usize, 0), ere_summary.failed);
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn printValidationClassification(
    path: []const u8,
    test_name: []const u8,
    block_index: usize,
    expected_success: bool,
    err: anyerror,
) void {
    std.debug.print("classify\tvalidation_error\terror={s}\tpath={s}\ttest={s}\tblock={}\texpected_success={}\n", .{
        @errorName(err),
        path,
        test_name,
        block_index,
        expected_success,
    });
}

fn printOutputClassification(
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    block_index: usize,
    input: []const u8,
    actual: []const u8,
    expected: []const u8,
) void {
    const actual_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, actual) catch {
        printOutputClassificationLine("actual_decode_error", "unknown", null, path, test_name, block_index, null, null);
        return;
    };
    const expected_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, expected) catch {
        printOutputClassificationLine("expected_decode_error", "unknown", null, path, test_name, block_index, actual_result.successful_validation, null);
        return;
    };

    const roots_equal = std.mem.eql(u8, &actual_result.new_payload_request_root, &expected_result.new_payload_request_root);
    const shape: []const u8 = if (actual_result.successful_validation != expected_result.successful_validation)
        if (actual_result.successful_validation) "unexpected_success" else "unexpected_failure"
    else if (!roots_equal)
        "request_root_mismatch"
    else
        "result_encoding_mismatch";

    if (!actual_result.successful_validation) {
        const native = evmz.stateless.wire.validateStatelessResultBytes(allocator, input) catch |err| {
            printOutputClassificationLine(shape, @errorName(err), null, path, test_name, block_index, actual_result.successful_validation, expected_result.successful_validation);
            return;
        };
        printOutputClassificationLine(shape, @tagName(native.status), native.tx_index, path, test_name, block_index, actual_result.successful_validation, expected_result.successful_validation);
    } else {
        printOutputClassificationLine(shape, "valid", null, path, test_name, block_index, actual_result.successful_validation, expected_result.successful_validation);
    }
}

fn printOutputClassificationLine(
    shape: []const u8,
    status: []const u8,
    tx_index: ?usize,
    path: []const u8,
    test_name: []const u8,
    block_index: usize,
    actual_success: ?bool,
    expected_success: ?bool,
) void {
    std.debug.print("classify\toutput_mismatch\tshape={s}\tstatus={s}\ttx_index=", .{ shape, status });
    if (tx_index) |index| {
        std.debug.print("{}", .{index});
    } else {
        std.debug.print("none", .{});
    }
    std.debug.print("\tpath={s}\ttest={s}\tblock={}", .{ path, test_name, block_index });
    if (actual_success) |success| {
        std.debug.print("\tactual_success={}", .{success});
    } else {
        std.debug.print("\tactual_success=unknown", .{});
    }
    if (expected_success) |success| {
        std.debug.print("\texpected_success={}", .{success});
    } else {
        std.debug.print("\texpected_success=unknown", .{});
    }
    std.debug.print("\n", .{});
}

fn printMismatch(allocator: std.mem.Allocator, input: []const u8, actual: []const u8, expected: []const u8, trace_mismatch: bool) void {
    const actual_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, actual) catch null;
    const expected_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, expected) catch null;
    std.debug.print("  mismatch: actual_len={} expected_len={}\n", .{ actual.len, expected.len });
    if (actual_result) |result| {
        std.debug.print("    actual success={} root={x}\n", .{ result.successful_validation, result.new_payload_request_root });
        if (!result.successful_validation) {
            const native = evmz.stateless.wire.validateStatelessResultBytes(allocator, input) catch null;
            if (native) |value| {
                std.debug.print("    actual status={s}\n", .{@tagName(value.status)});
                std.debug.print("    state={x} tx={x} receipts={x} withdrawals={x}\n", .{
                    value.state_root,
                    value.transactions_root,
                    value.receipts_root,
                    value.withdrawals_root,
                });
                std.debug.print("    gas_used={} block_gas_used={} blob_gas_used={}\n", .{
                    value.gas_used,
                    value.block_gas_used,
                    value.blob_gas_used,
                });
                if (trace_mismatch) printTrace(allocator, input);
            }
        }
    }
    if (expected_result) |result| {
        std.debug.print("    expect success={} root={x}\n", .{ result.successful_validation, result.new_payload_request_root });
    }
}

fn printTrace(allocator: std.mem.Allocator, input: []const u8) void {
    var printer = GasTracePrinter{};
    var sink = printer.sink();
    _ = evmz.stateless.wire.validateStatelessResultBytesWithTrace(allocator, input, &sink) catch |err| {
        std.debug.print("    trace failed: {s}\n", .{@errorName(err)});
        return;
    };
}

const GasTracePrinter = struct {
    fn sink(self: *@This()) evmz.trace.Sink {
        return evmz.trace.Sink.init(self, .{
            .step_end = evmz.trace.StepEndFields.initMany(&.{ .pc, .opcode, .decoded_opcode, .depth, .status, .gas_left, .gas_cost }),
            .state_write = evmz.trace.StateWriteKinds.initMany(&.{ .balance, .nonce, .storage, .warm_account, .warm_storage }),
        }, &.{
            .stepEnd = stepEnd,
            .stateWrite = stateWrite,
        });
    }

    fn stepEnd(ptr: *anyopaque, event: evmz.trace.StepEnd) void {
        _ = ptr;
        const important = if (event.decoded_opcode) |opcode| switch (opcode) {
            .BLOCKHASH, .CALL, .SLOAD, .SSTORE, .MLOAD, .MSTORE => true,
            else => false,
        } else false;
        if (!important and @abs(event.gas_cost) < 100) return;

        const opcode_name = if (event.decoded_opcode) |opcode| @tagName(opcode) else "unknown";
        std.debug.print("    trace step depth={} pc=0x{x} op={s} gas_cost={} gas_left={} status={s}\n", .{
            event.depth,
            event.pc,
            opcode_name,
            event.gas_cost,
            event.gas_left,
            @tagName(event.status),
        });
    }

    fn stateWrite(ptr: *anyopaque, event: evmz.trace.StateWrite) void {
        _ = ptr;
        switch (event) {
            .balance => |write| std.debug.print("    trace balance depth={} addr={x} previous={x} value={x}\n", .{
                write.depth,
                write.address,
                write.previous,
                write.value,
            }),
            .nonce => |write| std.debug.print("    trace nonce depth={} addr={x} previous={} value={}\n", .{
                write.depth,
                write.address,
                write.previous,
                write.value,
            }),
            .storage => |write| std.debug.print("    trace storage depth={} addr={x} key={x} previous={x} value={x}\n", .{
                write.depth,
                write.address,
                write.key,
                write.previous,
                write.value,
            }),
            .warm_account => |write| std.debug.print("    trace warm_account depth={} addr={x}\n", .{
                write.depth,
                write.address,
            }),
            .warm_storage => |write| std.debug.print("    trace warm_storage depth={} addr={x} key={x}\n", .{
                write.depth,
                write.address,
                write.key,
            }),
            else => {},
        }
    }
};

fn printPublicMismatch(
    allocator: std.mem.Allocator,
    input: []const u8,
    actual_output: []const u8,
    expected_output: []const u8,
    actual_public: evmz.stateless.ere.PublicValues,
    expected_public: evmz.stateless.ere.PublicValues,
    trace_mismatch: bool,
) void {
    std.debug.print("  public mismatch: actual={x} expected={x}\n", .{ actual_public, expected_public });
    printMismatch(allocator, input, actual_output, expected_output, trace_mismatch);
}
