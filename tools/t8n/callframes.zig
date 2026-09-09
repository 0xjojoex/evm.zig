//! Geth-compatible call-frame JSONL for the transition-tool boundary.

const std = @import("std");
const evmz = @import("evmz");

const Allocator = std.mem.Allocator;

pub fn encode(allocator: Allocator, span: evmz.trace.CallSpan) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(allocator);

    for (span.rows, 0..) |row, index| {
        while (active.items.len > row.depth) {
            const completed = active.pop().?;
            try writeExit(&output.writer, span, span.rows[completed]);
        }
        if (active.items.len != row.depth) return error.InvalidCallSpan;
        const parent_index = active.getLastOrNull();
        if (row.parent_index != parent_index or row.status == .running or row.gas < 0 or
            row.gas_used < 0)
        {
            return error.InvalidCallSpan;
        }
        try writeEnter(&output.writer, span, row);
        try active.append(allocator, @intCast(index));
    }
    while (active.pop()) |completed| {
        try writeExit(&output.writer, span, span.rows[completed]);
    }
    return output.toOwnedSlice();
}

fn writeEnter(writer: *std.Io.Writer, span: evmz.trace.CallSpan, row: evmz.trace.CallRow) !void {
    try writer.print(
        "{{\"from\":\"0x{x}\",\"to\":\"0x{x}\"",
        .{ row.from, row.to },
    );
    const input = span.input(row);
    if (input.len != 0) try writer.print(",\"input\":\"{x}\"", .{input});
    try writer.print(",\"gas\":\"0x{x}\",\"value\":", .{@as(u64, @intCast(row.gas))});
    if (row.kind == .staticcall) {
        try writer.writeAll("null");
    } else {
        try writer.print("\"0x{x}\"", .{row.value});
    }
    try writer.print(",\"type\":\"{s}\"}}\n", .{kindName(row.kind)});
}

fn writeExit(writer: *std.Io.Writer, span: evmz.trace.CallSpan, row: evmz.trace.CallRow) !void {
    try writer.print(
        "{{\"output\":\"{x}\",\"gasUsed\":\"0x{x}\"",
        .{ normalizedOutput(span, row), @as(u64, @intCast(row.gas_used)) },
    );
    if (errorText(row.status)) |message| {
        try writer.print(",\"error\":\"{s}\"", .{message});
    }
    try writer.writeAll("}\n");
}

fn normalizedOutput(span: evmz.trace.CallSpan, row: evmz.trace.CallRow) []const u8 {
    return switch (row.status) {
        .success, .revert, .code_store_out_of_gas_committed => span.output(row),
        else => &.{},
    };
}

fn kindName(kind: evmz.trace.CallKind) []const u8 {
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

fn errorText(status: evmz.trace.CallStatus) ?[]const u8 {
    return switch (status) {
        .success, .code_store_out_of_gas_committed => null,
        .revert => "execution reverted",
        .out_of_gas => "out of gas",
        .invalid => "invalid execution",
        .call_depth_exceeded => "max call depth exceeded",
        .insufficient_balance => "insufficient balance for transfer",
        .nonce_overflow => "nonce uint64 overflow",
        .invalid_opcode => "invalid opcode",
        .stack_underflow => "stack underflow",
        .stack_overflow => "stack limit reached 1024",
        .invalid_jump => "invalid jump destination",
        .write_protection => "write protection",
        .return_data_out_of_bounds => "return data out of bounds",
        .contract_address_collision => "contract address collision",
        .max_code_size_exceeded, .code_store_out_of_gas => "contract creation code storage out of gas",
        .invalid_code => "invalid code",
        .running => unreachable,
    };
}
