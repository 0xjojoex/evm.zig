//! Test-only compatibility projection for Geth `callTracer` behavior.
//!
//! This is an executable conformance oracle, not part of the `evmz.trace`
//! library surface. It proves that one neutral `CallSpan` contains enough
//! information for Geth-style nested and Parity-style flat representations.
//! Client-specific JSON, error text, filtering, and envelope policy stay here.

const std = @import("std");
const call_arena = @import("../trace/call_arena.zig");

const Address = @import("../address.zig").Address;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    InvalidCallSpan,
    NegativeGas,
    FilteredCallHasChildren,
};

pub const GethContext = struct {
    /// Transaction-scoped callers override the captured message gas with the
    /// declared transaction gas limit. Message-scoped callers leave this null.
    declared_gas: ?u64 = null,
    /// Transaction-scoped callers provide receipt gas used here.
    gas_used: ?u64 = null,
};

pub const GethOptions = struct {
    only_top_call: bool = false,
};

pub const FlatContext = struct {
    block_hash: ?[32]u8 = null,
    block_number: u64 = 0,
    transaction_hash: ?[32]u8 = null,
    transaction_position: u64 = 0,
};

pub const FlatOptions = struct {
    convert_parity_errors: bool = false,
    include_precompiles: bool = false,
    /// The caller resolves the active set for the transaction revision. An
    /// empty set means that no address is treated as a precompile.
    active_precompiles: []const Address = &.{},
};

/// Write one nested object matching Geth callTracer's structural policy.
///
/// The full span is validated before the first byte is written. Writer errors
/// may still leave partial output, as with any streaming serializer.
pub fn writeGeth(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    span: call_arena.Span,
    context: GethContext,
    options: GethOptions,
) Error!void {
    var validation = try Validation.init(allocator, span);
    defer validation.deinit();

    const row_limit: usize = if (options.only_top_call) 1 else span.rows.len;
    var remaining_children = try allocator.alloc(u32, validation.max_relative_depth + 1);
    defer allocator.free(remaining_children);
    const open_rows = try allocator.alloc(u32, validation.max_relative_depth + 1);
    defer allocator.free(open_rows);
    var stack_len: usize = 0;

    for (span.rows[0..row_limit], 0..) |row, row_index| {
        if (row_index != 0 and row.child_ordinal != 0) try writer.writeByte(',');
        try writeGethFrameHead(writer, span, row, row_index == 0, context);

        const child_count = if (options.only_top_call)
            0
        else
            validation.child_counts[row_index];
        if (child_count != 0) {
            try writer.writeAll(",\"calls\":[");
            remaining_children[stack_len] = child_count;
            open_rows[stack_len] = @intCast(row_index);
            stack_len += 1;
            continue;
        }

        try writeGethFrameTail(writer, row);
        try writer.writeByte('}');
        while (stack_len != 0) {
            const remaining = &remaining_children[stack_len - 1];
            remaining.* -= 1;
            if (remaining.* != 0) break;
            try writer.writeByte(']');
            try writeGethFrameTail(writer, span.rows[open_rows[stack_len - 1]]);
            try writer.writeByte('}');
            stack_len -= 1;
        }
    }
    std.debug.assert(stack_len == 0);
}

/// Write the completed span as a flat call array.
///
/// Rows are emitted in preorder. Filtering a CALL/STATICCALL precompile also
/// removes its ordinal, matching Geth flatCallTracer's nested-then-flattened
/// behavior. Precompiles cannot contain child calls.
pub fn writeFlat(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    span: call_arena.Span,
    context: FlatContext,
    options: FlatOptions,
) Error!void {
    var validation = try Validation.init(allocator, span);
    defer validation.deinit();

    const visible_child_counts = try allocator.alloc(u32, span.rows.len);
    defer allocator.free(visible_child_counts);
    @memset(visible_child_counts, 0);

    for (span.rows, 0..) |row, row_index| {
        if (isFilteredPrecompile(row, options)) {
            if (validation.child_counts[row_index] != 0) return error.FilteredCallHasChildren;
            continue;
        }
        if (row.parent_index) |parent_index| {
            visible_child_counts[parent_index] = std.math.add(
                u32,
                visible_child_counts[parent_index],
                1,
            ) catch return error.InvalidCallSpan;
        }
    }

    const path = try allocator.alloc(u32, validation.max_relative_depth);
    defer allocator.free(path);
    const next_child_ordinal = try allocator.alloc(u32, validation.max_relative_depth + 1);
    defer allocator.free(next_child_ordinal);
    @memset(next_child_ordinal, 0);

    try writer.writeByte('[');
    var wrote_frame = false;
    for (span.rows, 0..) |row, row_index| {
        if (isFilteredPrecompile(row, options)) continue;

        const relative_depth: usize = row.depth - validation.root_depth;
        const trace_address = if (relative_depth == 0) path[0..0] else address: {
            const parent_depth = relative_depth - 1;
            path[parent_depth] = next_child_ordinal[parent_depth];
            next_child_ordinal[parent_depth] += 1;
            next_child_ordinal[relative_depth] = 0;
            break :address path[0..relative_depth];
        };

        if (wrote_frame) try writer.writeByte(',');
        wrote_frame = true;
        try writeFlatFrame(
            writer,
            span,
            row,
            visible_child_counts[row_index],
            trace_address,
            context,
            options,
        );
    }
    try writer.writeByte(']');
}

/// Stable normalized Geth text for a retained terminal category.
///
/// Dynamic details such as an invalid opcode byte or stack counts are not
/// retained by the neutral arena, so those categories deliberately use a
/// stable prefix rather than pretending exact formatter data is available.
pub fn gethError(status: call_arena.Status) ?[]const u8 {
    return switch (status) {
        .running, .success, .code_store_out_of_gas_committed => null,
        .revert => "execution reverted",
        .out_of_gas => "out of gas",
        .invalid => "invalid execution",
        .call_depth_exceeded => "max call depth exceeded",
        .insufficient_balance => "insufficient balance for transfer",
        .nonce_overflow => "nonce uint64 overflow",
        .invalid_opcode => "invalid opcode",
        .stack_underflow => "stack underflow",
        .stack_overflow => "stack limit reached",
        .invalid_jump => "invalid jump destination",
        .write_protection => "write protection",
        .return_data_out_of_bounds => "return data out of bounds",
        .contract_address_collision => "contract address collision",
        .max_code_size_exceeded, .code_store_out_of_gas => "contract creation code storage out of gas",
        .invalid_code => "invalid code: must not begin with 0xef",
    };
}

/// Geth v1.17.4 flatCallTracer's optional Parity error conversion, expressed
/// directly from the neutral status so dynamic Geth error text is unnecessary.
pub fn parityError(status: call_arena.Status) ?[]const u8 {
    return switch (status) {
        .running, .success, .code_store_out_of_gas_committed => null,
        .revert => "Reverted",
        .out_of_gas, .max_code_size_exceeded, .code_store_out_of_gas => "Out of gas",
        .invalid_opcode => "Bad instruction",
        .stack_underflow => "Stack underflow",
        .stack_overflow => "Out of stack",
        .invalid_jump => "Bad jump destination",
        .return_data_out_of_bounds => "Out of bounds",
        else => gethError(status),
    };
}

const Validation = struct {
    allocator: std.mem.Allocator,
    child_counts: []u32,
    root_depth: u16,
    max_relative_depth: usize,

    fn init(allocator: std.mem.Allocator, span: call_arena.Span) Error!Validation {
        if (span.rows.len == 0) return error.InvalidCallSpan;
        const root = span.rows[0];
        if (root.parent_index != null or root.child_ordinal != 0) return error.InvalidCallSpan;

        var max_relative_depth: usize = 0;
        for (span.rows) |row| {
            if (row.depth < root.depth or row.status == .running) return error.InvalidCallSpan;
            if (row.gas < 0 or row.gas_used < 0) return error.NegativeGas;
            if (!rangeValid(row.input, span.bytes) or !rangeValid(row.output, span.bytes)) {
                return error.InvalidCallSpan;
            }
            max_relative_depth = @max(max_relative_depth, row.depth - root.depth);
        }

        const child_counts = try allocator.alloc(u32, span.rows.len);
        errdefer allocator.free(child_counts);
        @memset(child_counts, 0);
        const parent_stack = try allocator.alloc(u32, max_relative_depth + 1);
        defer allocator.free(parent_stack);
        parent_stack[0] = 0;

        var previous_relative_depth: usize = 0;
        for (span.rows[1..], 1..) |row, row_index| {
            const relative_depth: usize = row.depth - root.depth;
            if (relative_depth == 0 or relative_depth > previous_relative_depth + 1) {
                return error.InvalidCallSpan;
            }
            const expected_parent = parent_stack[relative_depth - 1];
            const parent_index = row.parent_index orelse return error.InvalidCallSpan;
            if (parent_index != expected_parent or parent_index >= row_index) {
                return error.InvalidCallSpan;
            }
            if (row.child_ordinal != child_counts[parent_index]) return error.InvalidCallSpan;
            child_counts[parent_index] = std.math.add(
                u32,
                child_counts[parent_index],
                1,
            ) catch return error.InvalidCallSpan;
            parent_stack[relative_depth] = @intCast(row_index);
            previous_relative_depth = relative_depth;
        }

        return .{
            .allocator = allocator,
            .child_counts = child_counts,
            .root_depth = root.depth,
            .max_relative_depth = max_relative_depth,
        };
    }

    fn deinit(self: *Validation) void {
        self.allocator.free(self.child_counts);
        self.* = undefined;
    }
};

fn rangeValid(range: call_arena.ByteRange, bytes: []const u8) bool {
    const start: usize = range.start;
    const len: usize = range.len;
    return start <= bytes.len and len <= bytes.len - start;
}

fn writeGethFrameHead(
    writer: *std.Io.Writer,
    span: call_arena.Span,
    row: call_arena.Row,
    is_root: bool,
    context: GethContext,
) std.Io.Writer.Error!void {
    const gas = if (is_root) context.declared_gas orelse @as(u64, @intCast(row.gas)) else @as(u64, @intCast(row.gas));
    const gas_used = if (is_root) context.gas_used orelse @as(u64, @intCast(row.gas_used)) else @as(u64, @intCast(row.gas_used));

    try writer.writeAll("{\"from\":");
    try writeAddress(writer, row.from);
    try writer.print(",\"gas\":\"0x{x}\",\"gasUsed\":\"0x{x}\"", .{ gas, gas_used });
    if (gethTo(row)) |to| {
        try writer.writeAll(",\"to\":");
        try writeAddress(writer, to);
    }
    try writer.writeAll(",\"input\":");
    try writeBytes(writer, span.input(row));

    const output = span.output(row);
    if (output.len != 0 and (gethError(row.status) == null or row.status == .revert)) {
        try writer.writeAll(",\"output\":");
        try writeBytes(writer, output);
    }
    if (gethError(row.status)) |message| {
        try writer.writeAll(",\"error\":");
        try writeString(writer, message);
    }
}

fn writeGethFrameTail(
    writer: *std.Io.Writer,
    row: call_arena.Row,
) std.Io.Writer.Error!void {
    if (row.kind != .staticcall) {
        try writer.writeAll(",\"value\":");
        try writeQuantity(writer, row.value);
    }
    try writer.writeAll(",\"type\":");
    try writeString(writer, gethKind(row.kind));
}

fn writeFlatFrame(
    writer: *std.Io.Writer,
    span: call_arena.Span,
    row: call_arena.Row,
    subtraces: u32,
    trace_address: []const u32,
    context: FlatContext,
    options: FlatOptions,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"action\":");
    try writeFlatAction(writer, span, row);
    if (context.block_hash) |block_hash| {
        try writer.writeAll(",\"blockHash\":");
        try writeBytes(writer, &block_hash);
    }
    try writer.print(",\"blockNumber\":{d}", .{context.block_number});

    const message = if (options.convert_parity_errors)
        parityError(row.status)
    else
        gethError(row.status);
    if (message) |error_message| {
        try writer.writeAll(",\"error\":");
        try writeString(writer, error_message);
    }
    if (hasFlatResult(row)) {
        try writer.writeAll(",\"result\":");
        try writeFlatResult(writer, span, row);
    }
    try writer.print(",\"subtraces\":{d},\"traceAddress\":[", .{subtraces});
    for (trace_address, 0..) |ordinal, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{ordinal});
    }
    try writer.writeByte(']');
    if (context.transaction_hash) |transaction_hash| {
        try writer.writeAll(",\"transactionHash\":");
        try writeBytes(writer, &transaction_hash);
    }
    try writer.print(",\"transactionPosition\":{d},\"type\":", .{context.transaction_position});
    try writeString(writer, flatKind(row.kind));
    try writer.writeByte('}');
}

fn writeFlatAction(
    writer: *std.Io.Writer,
    span: call_arena.Span,
    row: call_arena.Row,
) std.Io.Writer.Error!void {
    switch (row.kind) {
        .call, .staticcall, .delegatecall, .callcode => {
            try writer.writeAll("{\"callType\":");
            try writeString(writer, flatCallKind(row.kind));
            try writer.writeAll(",\"from\":");
            try writeAddress(writer, row.from);
            try writer.print(",\"gas\":\"0x{x}\",\"input\":", .{@as(u64, @intCast(row.gas))});
            try writeBytes(writer, span.input(row));
            try writer.writeAll(",\"to\":");
            try writeAddress(writer, row.to);
            try writer.writeAll(",\"value\":");
            try writeQuantity(writer, row.value);
            try writer.writeByte('}');
        },
        .create, .create2 => {
            try writer.writeAll("{\"creationMethod\":");
            try writeString(writer, flatCallKind(row.kind));
            try writer.writeAll(",\"from\":");
            try writeAddress(writer, row.from);
            try writer.print(",\"gas\":\"0x{x}\",\"init\":", .{@as(u64, @intCast(row.gas))});
            try writeBytes(writer, span.input(row));
            try writer.writeAll(",\"value\":");
            try writeQuantity(writer, row.value);
            try writer.writeByte('}');
        },
        .selfdestruct => {
            try writer.writeAll("{\"address\":");
            try writeAddress(writer, row.from);
            try writer.writeAll(",\"balance\":");
            try writeQuantity(writer, row.value);
            try writer.writeAll(",\"refundAddress\":");
            try writeAddress(writer, row.to);
            try writer.writeByte('}');
        },
    }
}

fn writeFlatResult(
    writer: *std.Io.Writer,
    span: call_arena.Span,
    row: call_arena.Row,
) std.Io.Writer.Error!void {
    switch (row.kind) {
        .create, .create2 => {
            try writer.writeByte('{');
            var needs_comma = false;
            if (row.createdAddress()) |address| {
                try writer.writeAll("\"address\":");
                try writeAddress(writer, address);
                needs_comma = true;
            }
            if (needs_comma) try writer.writeByte(',');
            try writer.writeAll("\"code\":");
            try writeBytes(writer, span.output(row));
            try writer.print(",\"gasUsed\":\"0x{x}\"}}", .{@as(u64, @intCast(row.gas_used))});
        },
        .call, .staticcall, .delegatecall, .callcode => {
            try writer.print("{{\"gasUsed\":\"0x{x}\",\"output\":", .{@as(u64, @intCast(row.gas_used))});
            try writeBytes(writer, span.output(row));
            try writer.writeByte('}');
        },
        .selfdestruct => unreachable,
    }
}

fn hasFlatResult(row: call_arena.Row) bool {
    if (row.kind == .selfdestruct) return false;
    return gethError(row.status) == null or row.status == .revert;
}

fn gethTo(row: call_arena.Row) ?Address {
    return switch (row.kind) {
        .create, .create2 => row.createdAddress(),
        else => row.to,
    };
}

fn isFilteredPrecompile(row: call_arena.Row, options: FlatOptions) bool {
    if (options.include_precompiles or row.parent_index == null) return false;
    if (row.kind != .call and row.kind != .staticcall) return false;
    for (options.active_precompiles) |address| {
        if (std.mem.eql(u8, &address, &row.to)) return true;
    }
    return false;
}

fn gethKind(kind: call_arena.Kind) []const u8 {
    return switch (kind) {
        .call => "CALL",
        .staticcall => "STATICCALL",
        .delegatecall => "DELEGATECALL",
        .callcode => "CALLCODE",
        .create => "CREATE",
        .create2 => "CREATE2",
        .selfdestruct => "SELFDESTRUCT",
    };
}

fn flatCallKind(kind: call_arena.Kind) []const u8 {
    return switch (kind) {
        .call => "call",
        .staticcall => "staticcall",
        .delegatecall => "delegatecall",
        .callcode => "callcode",
        .create => "create",
        .create2 => "create2",
        .selfdestruct => unreachable,
    };
}

fn flatKind(kind: call_arena.Kind) []const u8 {
    return switch (kind) {
        .create, .create2 => "create",
        .selfdestruct => "suicide",
        else => "call",
    };
}

fn writeAddress(writer: *std.Io.Writer, address: Address) std.Io.Writer.Error!void {
    try writeBytes(writer, &address);
}

fn writeBytes(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("\"0x");
    try writer.print("{x}", .{bytes});
    try writer.writeByte('"');
}

fn writeQuantity(writer: *std.Io.Writer, value: u256) std.Io.Writer.Error!void {
    try writer.print("\"0x{x}\"", .{value});
}

fn writeString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}

test "nested Geth projection preserves tree order and root gas context" {
    var arena = call_arena.CallArena.init(std.testing.allocator);
    defer arena.deinit();
    try arena.begin();

    const root = try arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0x11),
        .to = @splat(0x22),
        .code_address = @splat(0x22),
        .value = 3,
        .gas = 100,
        .input = &.{0xaa},
    });
    const child = try arena.start(.{
        .depth = 1,
        .kind = .staticcall,
        .from = @splat(0x22),
        .to = @splat(0x33),
        .code_address = @splat(0x33),
        .gas = 40,
        .input = &.{0xbb},
    });
    try arena.finishCall(child, .{ .status = .revert, .gas_left = 7, .output = &.{0xcc} });
    try arena.finishCall(root, .{ .status = .success, .gas_left = 10 });
    const span = try arena.finish();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeGeth(std.testing.allocator, &output.writer, span, .{
        .declared_gas = 120,
        .gas_used = 99,
    }, .{});
    try std.testing.expectEqualStrings(
        "{\"from\":\"0x1111111111111111111111111111111111111111\",\"gas\":\"0x78\",\"gasUsed\":\"0x63\",\"to\":\"0x2222222222222222222222222222222222222222\",\"input\":\"0xaa\",\"calls\":[{\"from\":\"0x2222222222222222222222222222222222222222\",\"gas\":\"0x28\",\"gasUsed\":\"0x21\",\"to\":\"0x3333333333333333333333333333333333333333\",\"input\":\"0xbb\",\"output\":\"0xcc\",\"error\":\"execution reverted\",\"type\":\"STATICCALL\"}],\"value\":\"0x3\",\"type\":\"CALL\"}",
        output.written(),
    );
}

test "nested Geth projection hides failed create destination and supports only top call" {
    var arena = call_arena.CallArena.init(std.testing.allocator);
    defer arena.deinit();
    try arena.begin();
    const root = try arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0x11),
        .to = @splat(0x22),
        .code_address = @splat(0x22),
        .gas = 100,
    });
    const create = try arena.start(.{
        .depth = 1,
        .kind = .create,
        .from = @splat(0x22),
        .to = @splat(0x44),
        .code_address = @splat(0x44),
        .gas = 50,
    });
    try arena.finishCall(create, .{ .status = .contract_address_collision, .gas_left = 0 });
    try arena.finishCall(root, .{ .status = .success, .gas_left = 25 });
    const span = try arena.finish();

    var full: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer full.deinit();
    try writeGeth(std.testing.allocator, &full.writer, span, .{}, .{});
    try std.testing.expect(std.mem.indexOf(u8, full.written(), "\"type\":\"CREATE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.written(), "4444444444444444444444444444444444444444") == null);

    var top: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer top.deinit();
    try writeGeth(std.testing.allocator, &top.writer, span, .{}, .{ .only_top_call = true });
    try std.testing.expect(std.mem.indexOf(u8, top.written(), "\"calls\"") == null);
}

test "flat projection filters precompiles and compresses trace addresses" {
    var arena = call_arena.CallArena.init(std.testing.allocator);
    defer arena.deinit();
    try arena.begin();
    const root = try arena.start(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0x11),
        .to = @splat(0x22),
        .code_address = @splat(0x22),
        .gas = 100,
    });
    const precompile = try arena.start(.{
        .depth = 1,
        .kind = .call,
        .from = @splat(0x22),
        .to = @splat(0x04),
        .code_address = @splat(0x04),
        .gas = 10,
    });
    try arena.finishCall(precompile, .{ .status = .success, .gas_left = 5 });
    const child = try arena.start(.{
        .depth = 1,
        .kind = .call,
        .from = @splat(0x22),
        .to = @splat(0x33),
        .code_address = @splat(0x33),
        .gas = 30,
    });
    const selfdestruct = try arena.start(.{
        .depth = 2,
        .kind = .selfdestruct,
        .from = @splat(0x33),
        .to = @splat(0x44),
        .code_address = @splat(0x33),
        .value = 9,
    });
    try arena.finishCall(selfdestruct, .{ .status = .success, .gas_left = 0 });
    try arena.finishCall(child, .{ .status = .success, .gas_left = 10 });
    try arena.finishCall(root, .{ .status = .success, .gas_left = 20 });
    const span = try arena.finish();

    const active_precompiles = [_]Address{@splat(0x04)};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeFlat(std.testing.allocator, &output.writer, span, .{
        .block_number = 7,
        .transaction_position = 2,
    }, .{ .active_precompiles = &active_precompiles });

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "0404040404040404040404040404040404040404") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"subtraces\":1,\"traceAddress\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"subtraces\":1,\"traceAddress\":[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"subtraces\":0,\"traceAddress\":[0,0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"type\":\"suicide\"") != null);
}

test "flat projection converts typed failures without dynamic Geth text" {
    try std.testing.expectEqualStrings("invalid opcode", gethError(.invalid_opcode).?);
    try std.testing.expectEqualStrings("Bad instruction", parityError(.invalid_opcode).?);
    try std.testing.expectEqualStrings("Out of stack", parityError(.stack_overflow).?);
    try std.testing.expectEqualStrings("contract address collision", parityError(.contract_address_collision).?);
    try std.testing.expectEqual(@as(?[]const u8, null), parityError(.code_store_out_of_gas_committed));
}

test "projection validates the whole span before writing" {
    const rows = [_]call_arena.Row{.{
        .parent_index = null,
        .child_ordinal = 0,
        .depth = 0,
        .kind = .call,
        .from = @splat(0),
        .to = @splat(0),
        .code_address = @splat(0),
        .value = 0,
        .gas = 1,
        .input = .{},
        .status = .running,
    }};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.InvalidCallSpan,
        writeGeth(std.testing.allocator, &output.writer, .{ .rows = &rows, .bytes = &.{} }, .{}, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), output.written().len);

    const depth_jump = [_]call_arena.Row{
        .{
            .parent_index = null,
            .child_ordinal = 0,
            .depth = 0,
            .kind = .call,
            .from = @splat(0),
            .to = @splat(0),
            .code_address = @splat(0),
            .value = 0,
            .gas = 1,
            .input = .{},
            .status = .success,
        },
        .{
            .parent_index = 0,
            .child_ordinal = 0,
            .depth = 2,
            .kind = .call,
            .from = @splat(0),
            .to = @splat(0),
            .code_address = @splat(0),
            .value = 0,
            .gas = 1,
            .input = .{},
            .status = .success,
        },
    };
    try std.testing.expectError(
        error.InvalidCallSpan,
        writeGeth(
            std.testing.allocator,
            &output.writer,
            .{ .rows = &depth_jump, .bytes = &.{} },
            .{},
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
