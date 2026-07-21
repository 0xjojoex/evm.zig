//! Transaction-scoped semantic call capture.
//!
//! The arena records call/create/selfdestruct externalities at their semantic
//! boundaries. It is deliberately independent from opcode-step capture and
//! tracked state.

const std = @import("std");
const Address = @import("../address.zig").Address;

pub const Kind = enum(u8) {
    call,
    staticcall,
    delegatecall,
    callcode,
    create,
    create2,
    selfdestruct,
};

pub const Status = enum(u8) {
    running,
    success,
    revert,
    out_of_gas,
    invalid,
};

pub const ByteRange = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn slice(self: ByteRange, bytes: []const u8) []const u8 {
        const start: usize = self.start;
        const len: usize = self.len;
        return bytes[start .. start + len];
    }
};

pub const Row = struct {
    parent_index: ?u32,
    child_ordinal: u32,
    depth: u16,
    kind: Kind,
    from: Address,
    to: Address,
    code_address: Address,
    value: u256,
    gas: i64,
    gas_used: i64 = 0,
    input: ByteRange,
    output: ByteRange = .{},
    status: Status = .running,

    // Used only while constructing the flat tree.
    next_child_ordinal: u32 = 0,
};

pub const Start = struct {
    depth: u16,
    kind: Kind,
    from: Address,
    to: Address,
    code_address: Address,
    value: u256 = 0,
    gas: i64 = 0,
    input: []const u8 = &.{},
};

pub const Finish = struct {
    status: Status,
    gas_left: i64,
    output: []const u8 = &.{},
};

pub const Token = struct {
    row_index: u32,
};

pub const Span = struct {
    rows: []const Row,
    bytes: []const u8,

    pub fn input(self: Span, row: Row) []const u8 {
        return row.input.slice(self.bytes);
    }

    pub fn output(self: Span, row: Row) []const u8 {
        return row.output.slice(self.bytes);
    }
};

pub const CallArena = struct {
    allocator: ?std.mem.Allocator,
    rows: std.ArrayList(Row) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    active_rows: std.ArrayList(u32) = .empty,
    root_count: u32 = 0,
    operation_open: bool = false,
    completed: bool = false,

    pub fn init(allocator: std.mem.Allocator) CallArena {
        return .{ .allocator = allocator };
    }

    pub fn initBounded(
        row_storage: []Row,
        byte_storage: []u8,
        active_row_storage: []u32,
    ) CallArena {
        return .{
            .allocator = null,
            .rows = .initBuffer(row_storage),
            .bytes = .initBuffer(byte_storage),
            .active_rows = .initBuffer(active_row_storage),
        };
    }

    pub fn deinit(self: *CallArena) void {
        std.debug.assert(!self.operation_open);
        if (self.allocator) |allocator| {
            self.rows.deinit(allocator);
            self.bytes.deinit(allocator);
            self.active_rows.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn begin(self: *CallArena) !void {
        if (self.operation_open) return error.CallCaptureOperationActive;
        self.rows.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.active_rows.clearRetainingCapacity();
        self.root_count = 0;
        self.completed = false;
        self.operation_open = true;
    }

    pub fn finish(self: *CallArena) !Span {
        if (!self.operation_open) return error.CallCaptureOperationNotActive;
        if (self.active_rows.items.len != 0) return error.ActiveCallCaptures;
        self.operation_open = false;
        self.completed = true;
        return self.span();
    }

    pub fn abort(self: *CallArena) !void {
        if (!self.operation_open) return error.CallCaptureOperationNotActive;
        self.rows.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.active_rows.clearRetainingCapacity();
        self.root_count = 0;
        self.operation_open = false;
        self.completed = false;
    }

    pub fn latest(self: *const CallArena) ?Span {
        if (!self.completed) return null;
        return self.span();
    }

    pub fn start(self: *CallArena, event: Start) !Token {
        if (!self.operation_open) return error.CallCaptureOperationNotActive;

        const row_index = std.math.cast(u32, self.rows.items.len) orelse
            return error.CallCaptureIndexOverflow;
        const input_range = try self.rangeForAppend(event.input.len);
        try self.ensureRows(1);
        try self.ensureBytes(event.input.len);
        try self.ensureActiveRows(1);

        const parent_index = self.active_rows.getLastOrNull();
        const child_ordinal = if (parent_index) |parent| blk: {
            const parent_row = &self.rows.items[parent];
            const ordinal = parent_row.next_child_ordinal;
            parent_row.next_child_ordinal = std.math.add(u32, ordinal, 1) catch
                return error.CallCaptureIndexOverflow;
            break :blk ordinal;
        } else blk: {
            const ordinal = self.root_count;
            self.root_count = std.math.add(u32, ordinal, 1) catch
                return error.CallCaptureIndexOverflow;
            break :blk ordinal;
        };

        self.bytes.appendSliceAssumeCapacity(event.input);
        self.rows.appendAssumeCapacity(.{
            .parent_index = parent_index,
            .child_ordinal = child_ordinal,
            .depth = event.depth,
            .kind = event.kind,
            .from = event.from,
            .to = event.to,
            .code_address = event.code_address,
            .value = event.value,
            .gas = event.gas,
            .input = input_range,
        });
        self.active_rows.appendAssumeCapacity(row_index);
        return .{ .row_index = row_index };
    }

    pub fn reserveOutput(self: *CallArena, output_len: usize) !void {
        if (!self.operation_open) return error.CallCaptureOperationNotActive;
        _ = try self.rangeForAppend(output_len);
        try self.ensureBytes(output_len);
    }

    /// Finish is infallible once `reserveOutput` has succeeded for this output.
    pub fn finishReserved(self: *CallArena, token: Token, event: Finish) void {
        std.debug.assert(self.operation_open);
        std.debug.assert(self.active_rows.getLastOrNull() == token.row_index);
        std.debug.assert(self.bytes.capacity - self.bytes.items.len >= event.output.len);

        const output_start = std.math.cast(u32, self.bytes.items.len) orelse unreachable;
        const output_len = std.math.cast(u32, event.output.len) orelse unreachable;
        self.bytes.appendSliceAssumeCapacity(event.output);

        const row = &self.rows.items[token.row_index];
        row.output = .{ .start = output_start, .len = output_len };
        row.status = event.status;
        row.gas_used = if (event.gas_left >= row.gas)
            0
        else
            std.math.sub(i64, row.gas, event.gas_left) catch std.math.maxInt(i64);
        self.active_rows.items.len -= 1;
    }

    pub fn finishCall(self: *CallArena, token: Token, event: Finish) !void {
        try self.reserveOutput(event.output.len);
        self.finishReserved(token, event);
    }

    fn span(self: *const CallArena) Span {
        return .{ .rows = self.rows.items, .bytes = self.bytes.items };
    }

    fn rangeForAppend(self: *const CallArena, len: usize) !ByteRange {
        const byte_start = std.math.cast(u32, self.bytes.items.len) orelse
            return error.CallCaptureIndexOverflow;
        const len_u32 = std.math.cast(u32, len) orelse
            return error.CallCaptureIndexOverflow;
        _ = std.math.add(u32, byte_start, len_u32) catch
            return error.CallCaptureIndexOverflow;
        return .{ .start = byte_start, .len = len_u32 };
    }

    fn ensureRows(self: *CallArena, count: usize) !void {
        if (self.allocator) |allocator| {
            try self.rows.ensureUnusedCapacity(allocator, count);
        } else if (self.rows.capacity - self.rows.items.len < count) {
            return error.CallCaptureCapacityExceeded;
        }
    }

    fn ensureBytes(self: *CallArena, count: usize) !void {
        if (self.allocator) |allocator| {
            try self.bytes.ensureUnusedCapacity(allocator, count);
        } else if (self.bytes.capacity - self.bytes.items.len < count) {
            return error.CallCaptureCapacityExceeded;
        }
    }

    fn ensureActiveRows(self: *CallArena, count: usize) !void {
        if (self.allocator) |allocator| {
            try self.active_rows.ensureUnusedCapacity(allocator, count);
        } else if (self.active_rows.capacity - self.active_rows.items.len < count) {
            return error.CallCaptureCapacityExceeded;
        }
    }
};

test "call arena preserves preorder, parentage, and copied bytes" {
    var arena = CallArena.init(std.testing.allocator);
    defer arena.deinit();
    try arena.begin();

    const root = try arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0x11),
        .to = @splat(0x22),
        .code_address = @splat(0x22),
        .gas = 100,
        .input = &.{ 0xaa, 0xbb },
    });
    const child = try arena.start(.{
        .depth = 1,
        .kind = .staticcall,
        .from = @splat(0x22),
        .to = @splat(0x33),
        .code_address = @splat(0x33),
        .gas = 40,
        .input = &.{0xcc},
    });
    try arena.finishCall(child, .{ .status = .success, .gas_left = 7, .output = &.{0xdd} });
    try arena.finishCall(root, .{ .status = .revert, .gas_left = 3, .output = &.{0xee} });

    const span = try arena.finish();
    try std.testing.expectEqual(@as(usize, 2), span.rows.len);
    try std.testing.expectEqual(@as(?u32, null), span.rows[0].parent_index);
    try std.testing.expectEqual(@as(?u32, 0), span.rows[1].parent_index);
    try std.testing.expectEqual(@as(u32, 0), span.rows[1].child_ordinal);
    try std.testing.expectEqual(@as(i64, 33), span.rows[1].gas_used);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, span.input(span.rows[0]));
    try std.testing.expectEqualSlices(u8, &.{0xdd}, span.output(span.rows[1]));
}

test "bounded call arena reports capacity before partial append" {
    var rows: [1]Row = undefined;
    var bytes: [1]u8 = undefined;
    var active: [1]u32 = undefined;
    var arena = CallArena.initBounded(&rows, &bytes, &active);
    defer arena.deinit();
    try arena.begin();

    try std.testing.expectError(error.CallCaptureCapacityExceeded, arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0),
        .to = @splat(0),
        .code_address = @splat(0),
        .input = &.{ 1, 2 },
    }));
    try std.testing.expectEqual(@as(usize, 0), arena.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), arena.bytes.items.len);
    try arena.abort();
}

test "bounded call arena finishes from reserved storage without allocation" {
    var rows: [1]Row = undefined;
    var bytes: [2]u8 = undefined;
    var active: [1]u32 = undefined;
    var arena = CallArena.initBounded(&rows, &bytes, &active);
    defer arena.deinit();
    try arena.begin();

    const token = try arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0),
        .to = @splat(0),
        .code_address = @splat(0),
        .input = &.{0xaa},
    });
    try arena.reserveOutput(1);
    arena.finishReserved(token, .{
        .status = .success,
        .gas_left = 0,
        .output = &.{0xbb},
    });

    const span = try arena.finish();
    try std.testing.expectEqualSlices(u8, &.{0xaa}, span.input(span.rows[0]));
    try std.testing.expectEqualSlices(u8, &.{0xbb}, span.output(span.rows[0]));
}
