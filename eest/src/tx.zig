const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const tx_validation = @import("tx_validation.zig");

const JsonValue = fixture_common.JsonValue;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseStateFork;

pub const Options = struct {
    fork_filter: ?[]const u8 = null,
    test_filter: ?[]const u8 = null,
};

pub const FailReason = enum(u8) {
    unsupported_fork,
    malformed_fixture,
    expected_transaction_exception,
    unexpected_status,
};

pub const Summary = struct {
    fixtures: usize = 0,
    vectors: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.fixtures += other.fixtures;
        self.vectors += other.vectors;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| {
            target.* += value;
        }
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options) !Summary {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    return runSlice(allocator, bytes, options);
}

pub fn runSlice(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }

        summary.fixtures += 1;
        runFixture(allocator, entry.value_ptr.*, options, &summary) catch {
            summary.vectors += 1;
            summary.countFail(.malformed_fixture);
        };
    }

    return summary;
}

fn runFixture(
    allocator: std.mem.Allocator,
    fixture: JsonValue,
    options: Options,
    summary: *Summary,
) !void {
    var fixture_obj = asObject(fixture) orelse return error.MalformedFixture;
    const tx_bytes = try parseBytesFromValue(allocator, fixture_obj.get("txbytes") orelse return error.MalformedFixture);
    defer allocator.free(tx_bytes);

    var result_obj = asObject(fixture_obj.get("result") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    var fork_it = result_obj.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_name = fork_entry.key_ptr.*;
        if (options.fork_filter) |filter| {
            if (!std.ascii.eqlIgnoreCase(fork_name, filter)) continue;
        }

        summary.vectors += 1;
        const revision = parseFork(fork_name) orelse {
            summary.countFail(.unsupported_fork);
            continue;
        };
        runVector(revision, tx_bytes, fork_entry.value_ptr.*, summary) catch {
            summary.countFail(.malformed_fixture);
        };
    }
}

fn runVector(
    revision: evmz.eth.Revision,
    tx_bytes: []const u8,
    result: JsonValue,
    summary: *Summary,
) !void {
    return switch (revision) {
        inline else => |exact_revision| runVectorExact(exact_revision, tx_bytes, result, summary),
    };
}

fn runVectorExact(
    comptime revision: evmz.eth.Revision,
    tx_bytes: []const u8,
    result: JsonValue,
    summary: *Summary,
) !void {
    const result_obj = asObject(result) orelse return error.MalformedFixture;
    const expected_exception = if (result_obj.get("exception")) |value|
        jsonString(value) orelse return error.MalformedFixture
    else
        null;

    const validation_error = evmz.transaction.envelope.Exact(evmz.eth.specAt(revision).transaction).classifyRawTransaction(tx_bytes);
    if (expected_exception) |expected| {
        if (validation_error) |err| {
            if (tx_validation.rawValidationErrorMatchesEest(err, expected)) {
                summary.passed += 1;
                return;
            }
        }
        summary.countFail(.expected_transaction_exception);
        return;
    }

    if (validation_error != null) {
        summary.countFail(.unexpected_status);
        return;
    }
    summary.passed += 1;
}

test "EEST transaction runner matches raw tx exception" {
    const json =
        \\{
        \\  "tests/prague/eip7702_set_code_tx/test_invalid_tx.py::test_empty_authorization_list[fork_Prague-transaction_test]": {
        \\    "result": {
        \\      "Prague": {
        \\        "intrinsicGas": "0x00",
        \\        "exception": "TransactionException.TYPE_4_EMPTY_AUTHORIZATION_LIST"
        \\      }
        \\    },
        \\    "txbytes": "0x04f86401808007830186a09400000000000000000000000000000000000000008080c0c001a04319a2e8066a9beedd85b227bf40cdecfb6134e6c1254f1e680895bc3131df31a059efad54e662f062d9af60acca08efb1d3d312742e381a600aac7c7989f892cc",
        \\    "_info": {}
        \\  }
        \\}
    ;
    const summary = try runSlice(std.testing.allocator, json, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
}
