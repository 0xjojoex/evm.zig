const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const stateless_report = @import("stateless_report.zig");
const stateless_executor = @import("stateless_executor.zig");
const stateless_metrics = @import("stateless_metrics.zig");

const JsonValue = fixture_common.JsonValue;
const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseBytesFromValue = fixture_common.parseBytesFromValue;

pub const Report = stateless_report.Report;
pub const Target = stateless_executor.Target;

pub const Options = struct {
    test_filter: ?[]const u8 = null,
    limit: usize = 0,
    verbose: bool = false,
    trace_mismatch: bool = false,
    classify_failures: bool = false,
    oracle_differential: bool = false,
    report: ?*Report = null,
    executor: stateless_executor.Options = .{},
    /// When set, one ERE `BenchmarkRun` row per executed block lands here.
    output_folder: ?[]const u8 = null,
    /// Corpus roots, so rows report a source path relative to the one that
    /// contains them.
    source_roots: []const []const u8 = &.{},
};

/// One executor per worker. A guest host is a child process behind a single
/// pipe pair, so it cannot be shared.
pub const Context = struct {
    executor: stateless_executor.Executor,

    pub fn init(io: std.Io, options: Options) !Context {
        return .{ .executor = try stateless_executor.Executor.init(io, options.executor) };
    }

    pub fn deinit(self: *Context) void {
        self.executor.deinit();
    }
};

pub const FailReason = enum(u8) {
    malformed_fixture,
    missing_stateless_output,
    validation_error,
    output_mismatch,
    unexpected_success,
    unexpected_failure,
    oracle_mismatch,
    executor_crash,
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    oracle_compared: usize = 0,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        self.oracle_compared += other.oracle_compared;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| target.* += value;
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }
};

pub fn runFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
    context: *Context,
) !Summary {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var summary = try runSlice(io, allocator, bytes, options, path, context);
    summary.files = 1;
    return summary;
}

pub fn runSlice(
    io: std.Io,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
    path: []const u8,
    context: *Context,
) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var names = stateless_metrics.Names.init(allocator);
    defer names.deinit();

    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }
        try runFixture(io, allocator, path, test_name, entry.value_ptr.*, options, context, &names, &summary);
        if (options.limit > 0 and summary.fixtures >= options.limit) break;
    }
    return summary;
}

/// Runs one top-level stateless fixture selected by its exact EEST id.
pub fn runCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    fixture: JsonValue,
    options: Options,
    context: *Context,
) !Summary {
    var summary = Summary{};
    var names = stateless_metrics.Names.init(allocator);
    defer names.deinit();
    try runFixture(io, allocator, path, test_name, fixture, options, context, &names, &summary);
    return summary;
}

fn runFixture(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    fixture: JsonValue,
    options: Options,
    context: *Context,
    names: *stateless_metrics.Names,
    summary: *Summary,
) !void {
    var reporter = Reporter{ .options = options, .source = path, .test_name = test_name };
    const object = asObject(fixture) orelse {
        try reporter.malformed("expected_fixture_object", null);
        summary.countFail(.malformed_fixture);
        return;
    };
    reporter.revision = if (object.get("network")) |value| jsonString(value) orelse "unknown" else "unknown";
    const chain_id = chain: {
        const config = asObject(object.get("config") orelse break :chain 0) orelse break :chain 0;
        break :chain (try parseOptionalU64(config.get("chainid"))) orelse 0;
    };
    const blocks = asArray(object.get("blocks") orelse {
        try reporter.malformed("missing_blocks", null);
        summary.countFail(.malformed_fixture);
        return;
    }) orelse {
        try reporter.malformed("expected_blocks_array", null);
        summary.countFail(.malformed_fixture);
        return;
    };

    for (blocks.items, 0..) |block_value, block_index| {
        if (options.limit > 0 and summary.fixtures >= options.limit) return;
        reporter.block = block_index;
        const block = asObject(block_value) orelse {
            try reporter.malformed("expected_block_object", null);
            summary.countFail(.malformed_fixture);
            continue;
        };
        const input_value = block.get("statelessInputBytes") orelse {
            summary.skipped += 1;
            continue;
        };
        const input_bytes = parseBytesFromValue(allocator, input_value) catch {
            try reporter.malformed("malformed_stateless_input_bytes", block.get("expectException") == null);
            summary.countFail(.malformed_fixture);
            continue;
        };
        defer allocator.free(input_bytes);
        summary.fixtures += 1;

        const expected_success = block.get("expectException") == null;

        // Parsed before execution: a guest writes into a fixed-width public
        // region, and only the fixture knows how much of it is meaningful.
        const expected_output: ?[]u8 = if (block.get("statelessOutputBytes")) |expected_value|
            parseBytesFromValue(allocator, expected_value) catch {
                try reporter.add(.{
                    .category = .fixture_spec_version_skew,
                    .validation_status = "malformed_stateless_output_bytes",
                    .difference = .fixture_shape,
                    .expected_success = expected_success,
                });
                summary.countFail(.malformed_fixture);
                continue;
            }
        else
            null;
        defer if (expected_output) |bytes| allocator.free(bytes);

        const name = try names.take(test_name, block_index);
        defer allocator.free(name);

        var outcome = context.executor.execute(
            allocator,
            input_bytes,
            if (expected_output) |bytes| bytes.len else 0,
            name,
        ) catch |err| {
            if (options.verbose) std.debug.print("  validation error: {s}\n", .{@errorName(err)});
            if (options.classify_failures) printValidationClassification(path, test_name, block_index, expected_success, err);
            try reporter.add(.{
                .category = if (err == error.OutOfMemory) .malformed_infrastructure_error else .implementation_mismatch,
                .validation_status = @errorName(err),
                .difference = .execution_error,
                .expected_success = expected_success,
            });
            summary.countFail(.validation_error);
            continue;
        };
        defer outcome.deinit(allocator);

        const output_matched = classify: {
            const result = switch (outcome) {
                .crashed => |crashed| {
                    try reporter.add(.{
                        .category = .implementation_mismatch,
                        .validation_status = crashed.reason,
                        .difference = .execution_error,
                        .expected_success = expected_success,
                    });
                    summary.countFail(.executor_crash);
                    break :classify false;
                },
                .completed => |completed| completed.output,
            };

            // Expected-invalid fixtures often contain several independent faults.
            // Their internal rejection priority is not part of the public wire
            // contract, so use focused mutations to compare typed failure status.
            // The oracle is an in-process comparison, so it only says anything
            // about the native target.
            if (options.oracle_differential and expected_success and options.executor.target == .native) {
                switch (try compareOracle(allocator, input_bytes)) {
                    .skipped => {},
                    .matched => summary.oracle_compared += 1,
                    .mismatch => |mismatch| {
                        summary.oracle_compared += 1;
                        printOracleMismatch(path, test_name, block_index, mismatch);
                        try reporter.add(.{
                            .category = .implementation_mismatch,
                            .validation_status = "dense_tracked_mismatch",
                            .difference = .oracle_result,
                            .expected_success = expected_success,
                        });
                        summary.countFail(.oracle_mismatch);
                        break :classify false;
                    },
                }
            }

            if (expected_output) |expected| {
                if (!std.mem.eql(u8, result, expected)) {
                    if (options.verbose) printMismatch(allocator, input_bytes, result, expected, options.trace_mismatch);
                    if (options.classify_failures) printOutputClassification(allocator, path, test_name, block_index, input_bytes, result, expected);
                    try reportOutputMismatch(allocator, reporter, expected_success, input_bytes, result, expected);
                    summary.countFail(.output_mismatch);
                    break :classify false;
                }
                const actual = evmz.stateless.wire.StatelessValidationResult.decode(allocator, result) catch null;
                try reporter.add(.{
                    .category = .pass,
                    .validation_status = if (actual) |value| validationStatus(allocator, input_bytes, value.successful_validation) else "valid",
                    .difference = .none,
                    .expected_success = expected_success,
                    .actual_success = if (actual) |value| value.successful_validation else null,
                });
                summary.passed += 1;
                break :classify true;
            }

            const actual = evmz.stateless.wire.StatelessValidationResult.decode(allocator, result) catch {
                try reporter.add(.{
                    .category = .adapter_wire_mismatch,
                    .validation_status = "actual_decode_error",
                    .difference = .result_encoding,
                    .expected_success = expected_success,
                });
                summary.countFail(.missing_stateless_output);
                break :classify false;
            };
            if (actual.successful_validation and !expected_success) {
                try reporter.add(.{
                    .category = .implementation_mismatch,
                    .validation_status = "valid",
                    .difference = .successful_validation,
                    .expected_success = expected_success,
                    .actual_success = true,
                });
                summary.countFail(.unexpected_success);
                break :classify false;
            }
            if (!actual.successful_validation and expected_success) {
                try reporter.add(.{
                    .category = .implementation_mismatch,
                    .validation_status = validationStatus(allocator, input_bytes, false),
                    .difference = .successful_validation,
                    .expected_success = expected_success,
                    .actual_success = false,
                });
                summary.countFail(.unexpected_failure);
                break :classify false;
            }
            try reporter.add(.{
                .category = .pass,
                .validation_status = validationStatus(allocator, input_bytes, actual.successful_validation),
                .difference = .none,
                .expected_success = expected_success,
                .actual_success = actual.successful_validation,
            });
            summary.passed += 1;
            break :classify true;
        };

        if (options.output_folder) |folder| {
            const source_path = try stateless_metrics.relativeSourcePath(allocator, path, options.source_roots);
            defer allocator.free(source_path);
            try stateless_metrics.write(io, allocator, folder, options.executor.target, name, .{
                .original_test_name = test_name,
                .source_path = source_path,
                .block_index = block_index,
                .network = reporter.revision,
                .chain_id = chain_id,
                .block_number = try blockNumber(block),
                .block_used_gas = try blockUsedGas(block),
            }, outcome, output_matched);
        }
    }
}

fn blockNumber(block: std.json.ObjectMap) !?u64 {
    const header = if (block.get("blockHeader")) |value| asObject(value) else null;
    const value = if (header) |object| object.get("number") orelse block.get("blocknumber") else block.get("blocknumber");
    return parseOptionalU64(value);
}

fn blockUsedGas(block: std.json.ObjectMap) !?u64 {
    const header = asObject(block.get("blockHeader") orelse return null) orelse return null;
    return parseOptionalU64(header.get("gasUsed"));
}

fn parseOptionalU64(value: ?JsonValue) !?u64 {
    const found = value orelse return null;
    const text = jsonString(found) orelse return null;
    const trimmed = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    const base: u8 = if (std.mem.startsWith(u8, text, "0x")) 16 else 10;
    return std.fmt.parseInt(u64, trimmed, base) catch null;
}

const OracleMismatch = struct {
    dense: evmz.eth.block_stf.Result,
    tracked: evmz.eth.block_stf.Result,
};

const OracleComparison = union(enum) {
    skipped,
    matched,
    mismatch: OracleMismatch,
};

fn compareOracle(allocator: std.mem.Allocator, input_bytes: []const u8) !OracleComparison {
    const dense = try evmz.stateless.wire.validateStatelessResultBytes(allocator, input_bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = evmz.stateless.wire.StatelessInput.decodeSchemaPrefixed(scratch, input_bytes) catch
        return .skipped;
    const normalized = evmz.stateless.wire.v1.normalize(scratch, input) catch return .skipped;
    const tracked = evmz.stateless.testing.TrackedValidator(evmz.eth.amsterdam).validate(
        scratch,
        normalized,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BlockTransitionFailed => return error.BlockTransitionFailed,
        else => evmz.eth.block_stf.Result{ .status = .invalid_witness },
    };
    if (oracleResultsEqual(dense, tracked)) return .matched;
    return .{ .mismatch = .{ .dense = dense, .tracked = tracked } };
}

fn oracleResultsEqual(dense: evmz.eth.block_stf.Result, tracked: evmz.eth.block_stf.Result) bool {
    var dense_consensus = dense;
    var tracked_consensus = tracked;
    // Admission can reject before a transaction starts while the sparse oracle
    // discovers the same invalid witness during that transaction. `tx_index`
    // is diagnostic provenance; every consensus-derived result field must match.
    dense_consensus.tx_index = null;
    tracked_consensus.tx_index = null;
    return std.meta.eql(dense_consensus, tracked_consensus);
}

fn printOracleMismatch(
    path: []const u8,
    test_name: []const u8,
    block_index: usize,
    mismatch: OracleMismatch,
) void {
    std.debug.print(
        "oracle mismatch path={s} test={s} block={} dense={s} tracked={s}\n",
        .{
            path,
            test_name,
            block_index,
            @tagName(mismatch.dense.status),
            @tagName(mismatch.tracked.status),
        },
    );
    std.debug.print(
        "  dense tx={?} gas={}/{}/{} state={x} transactions={x} receipts={x} withdrawals={x} bal={x}\n",
        .{
            mismatch.dense.tx_index,
            mismatch.dense.gas_used,
            mismatch.dense.block_gas_used,
            mismatch.dense.block_state_gas_used,
            mismatch.dense.state_root,
            mismatch.dense.transactions_root,
            mismatch.dense.receipts_root,
            mismatch.dense.withdrawals_root,
            mismatch.dense.block_access_list_hash,
        },
    );
    std.debug.print(
        "  tracked tx={?} gas={}/{}/{} state={x} transactions={x} receipts={x} withdrawals={x} bal={x}\n",
        .{
            mismatch.tracked.tx_index,
            mismatch.tracked.gas_used,
            mismatch.tracked.block_gas_used,
            mismatch.tracked.block_state_gas_used,
            mismatch.tracked.state_root,
            mismatch.tracked.transactions_root,
            mismatch.tracked.receipts_root,
            mismatch.tracked.withdrawals_root,
            mismatch.tracked.block_access_list_hash,
        },
    );
}

/// Per-block report context. Source, test, block, and revision are fixed for a
/// record, so call sites only name the part that varies.
const Reporter = struct {
    options: Options,
    source: []const u8,
    test_name: []const u8,
    revision: []const u8 = "unknown",
    block: usize = 0,

    const Entry = struct {
        category: stateless_report.Category,
        validation_status: []const u8,
        difference: stateless_report.Difference,
        expected_success: ?bool = null,
        actual_success: ?bool = null,
    };

    fn add(self: Reporter, entry: Entry) !void {
        const report = self.options.report orelse return;
        try report.add(.{
            .source = self.source,
            .test_name = self.test_name,
            .block = self.block,
            .revision = self.revision,
            .category = entry.category,
            .validation_status = entry.validation_status,
            .difference = entry.difference,
            .expected_success = entry.expected_success,
            .actual_success = entry.actual_success,
        });
    }

    fn malformed(self: Reporter, validation_status: []const u8, expected_success: ?bool) !void {
        return self.add(.{
            .category = .malformed_infrastructure_error,
            .validation_status = validation_status,
            .difference = .fixture_shape,
            .expected_success = expected_success,
        });
    }
};

fn validationStatus(allocator: std.mem.Allocator, input: []const u8, successful: bool) []const u8 {
    if (successful) return "valid";
    const result = evmz.stateless.wire.validateStatelessResultBytes(allocator, input) catch |err| {
        return @errorName(err);
    };
    return @tagName(result.status);
}

fn reportOutputMismatch(
    allocator: std.mem.Allocator,
    reporter: Reporter,
    expected_success: bool,
    input: []const u8,
    actual: []const u8,
    expected: []const u8,
) !void {
    const actual_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, actual) catch {
        return reporter.add(.{
            .category = .adapter_wire_mismatch,
            .validation_status = "actual_decode_error",
            .difference = .result_encoding,
            .expected_success = expected_success,
        });
    };
    const expected_result = evmz.stateless.wire.StatelessValidationResult.decode(allocator, expected) catch {
        return reporter.add(.{
            .category = .fixture_spec_version_skew,
            .validation_status = "expected_decode_error",
            .difference = .result_encoding,
            .expected_success = expected_success,
            .actual_success = actual_result.successful_validation,
        });
    };

    const difference: stateless_report.Difference = if (actual_result.successful_validation != expected_result.successful_validation)
        .successful_validation
    else if (!std.mem.eql(u8, &actual_result.new_payload_request_root, &expected_result.new_payload_request_root))
        .new_payload_request_root
    else if (actual_result.chain_id != expected_result.chain_id)
        .chain_id
    else if (actual_result.schema_id != expected_result.schema_id)
        .schema_id
    else
        .result_encoding;
    try reporter.add(.{
        .category = if (difference == .successful_validation) .implementation_mismatch else .adapter_wire_mismatch,
        .validation_status = validationStatus(allocator, input, actual_result.successful_validation),
        .difference = difference,
        .expected_success = expected_result.successful_validation,
        .actual_success = actual_result.successful_validation,
    });
}

test "stateless zkevm runner compares canonical SSZ bytes" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const output = try evmz.stateless.wire.validateStatelessBytesReusable(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    const input_hex = try hexAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(input_hex);
    const output_hex = try hexAlloc(std.testing.allocator, output);
    defer std.testing.allocator.free(output_hex);
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"smoke":{{"blocks":[{{"statelessInputBytes":"0x{s}","statelessOutputBytes":"0x{s}"}}]}}}}
    , .{ input_hex, output_hex });
    defer std.testing.allocator.free(fixture);

    const options = Options{ .oracle_differential = true };
    var context = try Context.init(std.testing.io, options);
    defer context.deinit();
    const summary = try runSlice(
        std.testing.io,
        std.testing.allocator,
        fixture,
        options,
        "smoke.json",
        &context,
    );
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.oracle_compared);
}

test "oracle parity excludes only diagnostic transaction provenance" {
    const dense = evmz.eth.block_stf.Result{ .status = .invalid_witness };
    var tracked = dense;
    tracked.tx_index = 0;
    try std.testing.expect(oracleResultsEqual(dense, tracked));
    tracked.gas_used = 1;
    try std.testing.expect(!oracleResultsEqual(dense, tracked));
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var printer = GasTracePrinter{};
    var tape = evmz.trace.TraceTape.initGrowable(allocator);
    defer tape.deinit();
    var bal_diff_buffer: [64 * 1024]u8 = undefined;
    var bal_diff_writer: std.Io.Writer = .fixed(&bal_diff_buffer);
    var bal_report = evmz.eth.block_stf.BalDifferentialReport{
        .mismatch_writer = &bal_diff_writer,
    };
    const decoded = evmz.stateless.wire.StatelessInput.decodeSchemaPrefixed(scratch, input) catch |err| {
        std.debug.print("    trace decode failed: {s}\n", .{@errorName(err)});
        return;
    };
    const normalized = evmz.stateless.wire.v1.normalize(scratch, decoded) catch |err| {
        std.debug.print("    trace normalize failed: {s}\n", .{@errorName(err)});
        return;
    };
    _ = evmz.stateless.testing.TrackedValidator(evmz.eth.amsterdam).validateWithCaptureOptions(scratch, normalized, .{
        .observations = printer.observationTarget(),
        .steps = .{
            .tape = &tape,
            .profile = .{ .stack = .omitted },
            .target = printer.traceTarget(),
        },
    }, .{ .bal_differential = &bal_report }) catch |err| {
        std.debug.print("    trace failed: {s}\n", .{@errorName(err)});
        return;
    };
    if (bal_diff_writer.end != 0) {
        std.debug.print("    BAL diff:\n{s}", .{bal_diff_buffer[0..bal_diff_writer.end]});
    }
}

const GasTracePrinter = struct {
    fn observationTarget(self: *@This()) evmz.eth.block_stf.ObservationTarget {
        return .init(self, observe);
    }

    fn traceTarget(self: *@This()) evmz.trace.TraceSpanTarget {
        return evmz.trace.TraceSpanTarget.init(self, consumeTrace);
    }

    fn observe(
        ptr: *anyopaque,
        block_access_index: evmz.eth.bal.BlockAccessIndex,
        observations: evmz.state.TrackedState.ObservationsView,
    ) !void {
        _ = ptr;
        var account_index: u32 = 0;
        while (account_index < observations.accounts.len()) : (account_index += 1) {
            const fact = observations.accounts.at(account_index);
            if (fact.observation.semantic_access) {
                std.debug.print("    trace account index={} addr={x}\n", .{
                    block_access_index,
                    fact.address,
                });
            }
            if (fact.effect.balance_written) printBalance(block_access_index, fact);
            if (fact.effect.nonce_written) printNonce(block_access_index, fact);
            if (fact.effect.code_written) {
                std.debug.print("    trace code index={} addr={x}\n", .{
                    block_access_index,
                    fact.address,
                });
            }
        }

        var storage_index: u32 = 0;
        while (storage_index < observations.storage.len()) : (storage_index += 1) {
            const metadata = observations.storage.metadataAt(storage_index);
            if (!metadata.observation.value_read and !metadata.effect.written) {
                std.debug.print(
                    "    trace storage index={} addr={x} key={x} value=unloaded written=false\n",
                    .{ block_access_index, metadata.address, metadata.key },
                );
                continue;
            }
            const fact = observations.storage.at(storage_index) orelse
                return error.IncompleteStorageObservation;
            std.debug.print(
                "    trace storage index={} addr={x} key={x} previous={x} value={x} written={}\n",
                .{
                    block_access_index,
                    fact.address,
                    fact.key,
                    fact.original,
                    fact.current,
                    fact.effect.written,
                },
            );
        }
    }

    fn printBalance(
        block_access_index: evmz.eth.bal.BlockAccessIndex,
        fact: evmz.state.TrackedState.AccountObservationFact,
    ) void {
        const original = account(fact.original);
        const current = account(fact.current);
        std.debug.print(
            "    trace balance index={} addr={x} previous={x} value={x}\n",
            .{ block_access_index, fact.address, original.balance, current.balance },
        );
    }

    fn printNonce(
        block_access_index: evmz.eth.bal.BlockAccessIndex,
        fact: evmz.state.TrackedState.AccountObservationFact,
    ) void {
        const original = account(fact.original);
        const current = account(fact.current);
        std.debug.print(
            "    trace nonce index={} addr={x} previous={} value={}\n",
            .{ block_access_index, fact.address, original.nonce, current.nonce },
        );
    }

    fn account(value: ?evmz.state.TrackedState.AccountValue) evmz.state.Account {
        return switch (value orelse .absent) {
            .loaded => |loaded| loaded,
            .absent => .{},
            .exists_only => unreachable,
        };
    }

    fn consumeTrace(ptr: *anyopaque, span: evmz.trace.TraceSpan) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var cursor = evmz.trace.TraceCursor.init(span);
        while (try cursor.next()) |event| switch (event) {
            .step_end => |view| self.stepEnd(view),
            .frame_enter, .step_start, .frame_leave => {},
        };
    }

    fn stepEnd(_: *@This(), view: evmz.trace.TraceCursor.StepView) void {
        const decoded_opcode = std.enums.fromInt(evmz.Opcode, view.row.opcode);
        const important = if (decoded_opcode) |opcode| switch (opcode) {
            .BLOCKHASH, .CALL, .SLOAD, .SSTORE, .MLOAD, .MSTORE => true,
            else => false,
        } else false;
        const gas_cost = if (view.row.gas_before > view.row.gas_after)
            view.row.gas_before - view.row.gas_after
        else
            0;
        if (!important and @abs(gas_cost) < 100) return;

        const opcode_name = if (decoded_opcode) |opcode| @tagName(opcode) else "unknown";
        const status = if (view.terminal) @tagName(view.frame.outcome) else "running";
        std.debug.print("    trace step depth={} pc=0x{x} op={s} gas_cost={} gas_left={} status={s}\n", .{
            view.frame.depth,
            view.row.pc,
            opcode_name,
            gas_cost,
            view.row.gas_after,
            status,
        });
    }
};
