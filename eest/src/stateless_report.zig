const std = @import("std");

pub const Category = enum {
    pass,
    implementation_mismatch,
    adapter_wire_mismatch,
    unsupported_protocol_shape,
    fixture_spec_version_skew,
    malformed_infrastructure_error,
};

pub const Difference = enum {
    none,
    successful_validation,
    new_payload_request_root,
    chain_config,
    result_encoding,
    fixture_shape,
    execution_error,
};

pub const Record = struct {
    source: []const u8,
    test_name: []const u8,
    block: usize,
    revision: []const u8,
    /// Derived from `test_name` by `add`; callers leave it defaulted.
    family: []const u8 = "unknown",
    category: Category,
    validation_status: []const u8,
    difference: Difference,
    expected_success: ?bool,
    actual_success: ?bool,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Report) void {
        for (self.records.items) |record| {
            self.allocator.free(record.source);
            self.allocator.free(record.test_name);
            self.allocator.free(record.revision);
            self.allocator.free(record.validation_status);
        }
        self.records.deinit(self.allocator);
    }

    /// Takes ownership of the string fields by duplicating them. `family`
    /// borrows the retained `test_name`, so it needs no separate allocation.
    pub fn add(self: *Report, value: Record) !void {
        var record = value;
        record.source = try self.allocator.dupe(u8, value.source);
        errdefer self.allocator.free(record.source);
        record.test_name = try self.allocator.dupe(u8, value.test_name);
        errdefer self.allocator.free(record.test_name);
        record.revision = try self.allocator.dupe(u8, value.revision);
        errdefer self.allocator.free(record.revision);
        record.validation_status = try self.allocator.dupe(u8, value.validation_status);
        errdefer self.allocator.free(record.validation_status);
        record.family = familyFromTest(record.test_name);
        try self.records.append(self.allocator, record);
    }

    pub fn write(self: *Report, io: std.Io, path: []const u8) !void {
        std.sort.heap(Record, self.records.items, {}, recordLessThan);
        const json = try std.json.Stringify.valueAlloc(self.allocator, Document{
            .counts = Counts.fromRecords(self.records.items),
            .records = self.records.items,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }
};

const Counts = struct {
    pass: usize = 0,
    implementation_mismatch: usize = 0,
    adapter_wire_mismatch: usize = 0,
    unsupported_protocol_shape: usize = 0,
    fixture_spec_version_skew: usize = 0,
    malformed_infrastructure_error: usize = 0,

    fn fromRecords(records: []const Record) Counts {
        var counts = Counts{};
        for (records) |record| {
            switch (record.category) {
                .pass => counts.pass += 1,
                .implementation_mismatch => counts.implementation_mismatch += 1,
                .adapter_wire_mismatch => counts.adapter_wire_mismatch += 1,
                .unsupported_protocol_shape => counts.unsupported_protocol_shape += 1,
                .fixture_spec_version_skew => counts.fixture_spec_version_skew += 1,
                .malformed_infrastructure_error => counts.malformed_infrastructure_error += 1,
            }
        }
        return counts;
    }
};

const Document = struct {
    schema_version: u8 = 1,
    counts: Counts,
    records: []const Record,
};

fn familyFromTest(test_name: []const u8) []const u8 {
    var parts = std.mem.splitScalar(u8, test_name, '/');
    if (std.mem.eql(u8, parts.next() orelse return "unknown", "tests")) {
        _ = parts.next();
        return parts.next() orelse "unknown";
    }
    return "unknown";
}

fn recordLessThan(_: void, lhs: Record, rhs: Record) bool {
    const source_order = std.mem.order(u8, lhs.source, rhs.source);
    if (source_order != .eq) return source_order == .lt;
    const test_order = std.mem.order(u8, lhs.test_name, rhs.test_name);
    if (test_order != .eq) return test_order == .lt;
    return lhs.block < rhs.block;
}

test "report output is deterministic and grouped for machines" {
    var report = Report.init(std.testing.allocator);
    defer report.deinit();
    try report.add(.{
        .source = "b.json",
        .test_name = "tests/amsterdam/eip_b/test_b",
        .block = 1,
        .revision = "Amsterdam",
        .category = .implementation_mismatch,
        .validation_status = "state_root_mismatch",
        .difference = .successful_validation,
        .expected_success = true,
        .actual_success = false,
    });
    try report.add(.{
        .source = "a.json",
        .test_name = "tests/amsterdam/eip_a/test_a",
        .block = 0,
        .revision = "Amsterdam",
        .category = .pass,
        .validation_status = "valid",
        .difference = .none,
        .expected_success = true,
        .actual_success = true,
    });

    const counts = Counts.fromRecords(report.records.items);
    try std.testing.expectEqual(@as(usize, 1), counts.pass);
    try std.testing.expectEqual(@as(usize, 1), counts.implementation_mismatch);
    std.sort.heap(Record, report.records.items, {}, recordLessThan);
    try std.testing.expectEqualStrings("a.json", report.records.items[0].source);
    try std.testing.expectEqualStrings("eip_a", report.records.items[0].family);
}
