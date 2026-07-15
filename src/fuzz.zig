const std = @import("std");
const rlp = @import("lib.zig");

const max_input_len = 1024;
const max_list_depth = 64;

const RawProperty = struct {
    const empty_input = [_]u8{ 0, 0, 0, 0 };
    const nested_list = [_]u8{ 4, 0, 0, 0, 0xc3, 0xc2, 0xc1, 0x80 };
    const bytes_56 = [_]u8{ 58, 0, 0, 0, 0xb8, 0x38 } ++ [_]u8{0xbb} ** 56;
    const noncanonical_single = [_]u8{ 2, 0, 0, 0, 0x81, 0x00 };

    fn check(smith: *std.testing.Smith) anyerror!void {
        var input_storage: [max_input_len]u8 = undefined;
        const input_len: usize = @intCast(smith.slice(&input_storage));
        const input = input_storage[0..input_len];

        var list_stack: [max_list_depth]rlp.Cursor = undefined;
        rlp.validateExact(input, &list_stack, input.len + 1) catch return;

        const item = try rlp.parseExact(input);
        try std.testing.expectEqualSlices(u8, input, item.encoded());
        try std.testing.expectEqual(
            @intFromPtr(input.ptr),
            @intFromPtr(item.encoded().ptr),
        );

        const encoded_start = @intFromPtr(item.encoded().ptr);
        const payload_start = @intFromPtr(item.payload().ptr);
        try std.testing.expect(payload_start >= encoded_start);
        const payload_offset = payload_start - encoded_start;
        try std.testing.expect(payload_offset <= item.encoded().len);
        try std.testing.expect(
            item.payload().len <= item.encoded().len - payload_offset,
        );

        var output: [max_input_len]u8 = undefined;
        var writer = rlp.Writer.fixed(&output);
        switch (item) {
            .bytes => try writer.bytes(item.payload()),
            .list => try writer.listPayload(item.payload()),
        }
        try std.testing.expectEqualSlices(u8, input, writer.written());
    }
};

const Child = struct {
    enabled: bool,
    amount: u256,
};

const Value = struct {
    nonce: u64,
    balance: u256,
    data: []const u8,
    children: [2]Child,
};

const ValueInput = struct {
    const long_boundary_seed = [_]u8{ 4, 4, 4, 0x02, 4, 4, 0, 0 };
    const arbitrary_seed = [_]u8{ 6, 6, 7, 0x02, 6, 6, 0, 0 } ++
        [_]u8{0xa5} ** 168;

    fn generate(smith: *std.testing.Smith, data_storage: *[64]u8) Value {
        var controls: [8]u8 = undefined;
        smith.bytes(&controls);
        smith.bytes(data_storage);

        return .{
            .nonce = shapedUnsigned(u64, smith.value(u64), controls[0]),
            .balance = shapedUnsigned(u256, smith.value(u256), controls[1]),
            .data = data_storage[0..dataLen(controls[2])],
            .children = .{
                .{
                    .enabled = controls[3] & 0x01 != 0,
                    .amount = shapedUnsigned(u256, smith.value(u256), controls[4]),
                },
                .{
                    .enabled = controls[3] & 0x02 != 0,
                    .amount = shapedUnsigned(u256, smith.value(u256), controls[5]),
                },
            },
        };
    }

    fn shapedUnsigned(comptime T: type, raw_value: T, shape: u8) T {
        return switch (shape % 7) {
            0 => 0,
            1 => 1,
            2 => 0x7f,
            3 => 0x80,
            4 => std.math.maxInt(T),
            5 => @as(T, 1) << (@bitSizeOf(T) - 1),
            6 => raw_value,
            else => unreachable,
        };
    }

    fn dataLen(shape: u8) usize {
        return switch (shape % 8) {
            0 => 0,
            1 => 1,
            2 => 54,
            3 => 55,
            4 => 56,
            5 => 64,
            else => shape % 65,
        };
    }
};

fn checkValueProperty(smith: *std.testing.Smith) anyerror!void {
    var data_storage: [64]u8 = undefined;
    const value = ValueInput.generate(smith, &data_storage);

    const measured_len = try rlp.encodedLen(Value, &value);

    var fixed_storage: [256]u8 = undefined;
    const encoded = try rlp.encode(Value, &fixed_storage, &value);
    try std.testing.expectEqual(measured_len, encoded.len);

    const allocated = try rlp.encodeAlloc(Value, std.testing.allocator, &value);
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqualSlices(u8, encoded, allocated);

    var raw_storage: [256]u8 = undefined;
    const raw_encoded = try encodeRaw(value, &raw_storage);
    try std.testing.expectEqualSlices(u8, encoded, raw_encoded);

    var list_stack: [8]rlp.Cursor = undefined;
    try rlp.validateExact(encoded, &list_stack, 16);

    const decoded = try rlp.decode(Value, encoded);
    try std.testing.expectEqual(value.nonce, decoded.nonce);
    try std.testing.expectEqual(value.balance, decoded.balance);
    try std.testing.expectEqualSlices(u8, value.data, decoded.data);
    try std.testing.expectEqualDeep(value.children, decoded.children);
}

const RuntimePrefix = struct {
    nonce: u64,
    balance: u256,
};

fn emitRuntimeValue(fields: anytype, value: *const Value) rlp.EncodeError!void {
    try fields.encodeFields(RuntimePrefix, value);
    if (value.data.len != 0) try fields.encode([]const u8, value.data);
    try fields.list(emitEnabledChildren, value);
}

fn emitEnabledChildren(fields: anytype, value: *const Value) rlp.EncodeError!void {
    for (value.children) |child| {
        if (child.enabled) try fields.list(emitRuntimeChild, child);
    }
}

fn emitRuntimeChild(fields: anytype, child: Child) rlp.EncodeError!void {
    try fields.encodeFields(Child, child);
}

fn checkEmitterProperty(smith: *std.testing.Smith) anyerror!void {
    var data_storage: [64]u8 = undefined;
    const value = ValueInput.generate(smith, &data_storage);

    const measured_len = try rlp.encodedListLen(emitRuntimeValue, &value);
    var fixed_storage: [256]u8 = undefined;
    const encoded = try rlp.encodeList(emitRuntimeValue, &fixed_storage, &value);
    try std.testing.expectEqual(measured_len, encoded.len);

    const allocated = try rlp.encodeListAlloc(
        emitRuntimeValue,
        std.testing.allocator,
        &value,
    );
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqualSlices(u8, encoded, allocated);

    var raw_storage: [256]u8 = undefined;
    const raw_encoded = try encodeRuntimeRaw(value, &raw_storage);
    try std.testing.expectEqualSlices(u8, encoded, raw_encoded);

    var list_stack: [4]rlp.Cursor = undefined;
    try rlp.validateExact(encoded, &list_stack, 16);
}

const MutationProperty = struct {
    const boundary_seed = [_]u8{ 0xff, 0x00, 0x7f, 0xa5, 0x00, 0x37, 0x01, 0xff } ++
        ValueInput.long_boundary_seed;
    const arbitrary_seed = [_]u8{ 0x34, 0x12, 0x81, 0x42, 0x7f, 0x2a, 0x55, 0xaa } ++
        ValueInput.arbitrary_seed;

    fn check(smith: *std.testing.Smith) anyerror!void {
        var controls: [8]u8 = undefined;
        smith.bytes(&controls);

        var data_storage: [64]u8 = undefined;
        const value = ValueInput.generate(smith, &data_storage);
        var encoded_storage: [256]u8 = undefined;
        const encoded = try rlp.encode(Value, &encoded_storage, &value);

        var trailing_storage: [257]u8 = undefined;
        @memcpy(trailing_storage[0..encoded.len], encoded);
        trailing_storage[encoded.len] = controls[3];
        try std.testing.expectError(
            error.TrailingBytes,
            rlp.parseExact(trailing_storage[0 .. encoded.len + 1]),
        );

        const offset: usize = std.mem.readInt(u16, controls[0..2], .little);
        const truncated_len = offset % encoded.len;
        try expectRejected(encoded[0..truncated_len]);

        try std.testing.expectError(
            error.NonCanonicalSingleByte,
            rlp.parseExact(&.{ 0x81, controls[4] & 0x7f }),
        );

        const short_len: usize = controls[5] % 56;
        var long_bytes_storage: [57]u8 = undefined;
        long_bytes_storage[0] = 0xb8;
        long_bytes_storage[1] = @intCast(short_len);
        @memcpy(long_bytes_storage[2..][0..short_len], data_storage[0..short_len]);
        try std.testing.expectError(
            error.NonCanonicalLength,
            rlp.parseExact(long_bytes_storage[0 .. short_len + 2]),
        );

        var long_list_storage: [57]u8 = undefined;
        long_list_storage[0] = 0xf8;
        long_list_storage[1] = @intCast(short_len);
        @memset(long_list_storage[2..][0..short_len], 0x80);
        try std.testing.expectError(
            error.NonCanonicalLength,
            rlp.parseExact(long_list_storage[0 .. short_len + 2]),
        );

        var leading_zero_bytes: [59]u8 = undefined;
        leading_zero_bytes[0..3].* = .{ 0xb9, 0x00, 0x38 };
        @memcpy(leading_zero_bytes[3..], data_storage[0..56]);
        try std.testing.expectError(
            error.NonCanonicalLength,
            rlp.parseExact(&leading_zero_bytes),
        );

        var leading_zero_list: [59]u8 = undefined;
        leading_zero_list[0..3].* = .{ 0xf9, 0x00, 0x38 };
        @memset(leading_zero_list[3..], 0x80);
        try std.testing.expectError(
            error.NonCanonicalLength,
            rlp.parseExact(&leading_zero_list),
        );

        var mutated_storage: [256]u8 = undefined;
        @memcpy(mutated_storage[0..encoded.len], encoded);
        const mutation_index = (offset + controls[6]) % encoded.len;
        mutated_storage[mutation_index] ^= controls[7] | 1;
        const mutated = mutated_storage[0..encoded.len];

        var list_stack: [max_list_depth]rlp.Cursor = undefined;
        if (rlp.validateExact(mutated, &list_stack, mutated.len + 1)) |_| {
            try expectRawReencoding(mutated);
            if (rlp.decode(Value, mutated)) |decoded| {
                var reencoded_storage: [256]u8 = undefined;
                const reencoded = try rlp.encode(Value, &reencoded_storage, &decoded);
                try std.testing.expectEqualSlices(u8, mutated, reencoded);
            } else |_| {}
        } else |_| {
            if (rlp.decode(Value, mutated)) |_| {
                return error.TypedDecodeAcceptedInvalidRaw;
            } else |_| {}
        }
    }
};

const OwnedChild = struct {
    tag: u16,
    payload: []u8,
};

const OwnedValue = struct {
    children: []const OwnedChild,
};

const OwnedInput = struct {
    const full_seed = [_]u8{ 4, 3, 3, 3, 3, 4, 4, 4, 4, 0xff, 0xff, 0 } ++
        [_]u8{0xa5} ** 96;
    const arbitrary_seed = [_]u8{ 4, 5, 6, 7, 8, 5, 6, 7, 8, 0x42, 0x00, 0 } ++
        [_]u8{0x5a} ** 96;

    fn generate(
        smith: *std.testing.Smith,
        controls: *[12]u8,
        payload_storage: *[4][16]u8,
        children_storage: *[4]OwnedChild,
    ) OwnedValue {
        smith.bytes(controls);
        for (children_storage, 0..) |*child, index| {
            smith.bytes(&payload_storage[index]);
            child.* = .{
                .tag = shapedTag(smith.value(u16), controls[5 + index]),
                .payload = payload_storage[index][0..payloadLen(controls[1 + index])],
            };
        }
        return .{ .children = children_storage[0..childCount(controls[0])] };
    }

    fn childCount(shape: u8) usize {
        return switch (shape % 6) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 3,
            4 => 4,
            else => shape % 5,
        };
    }

    fn payloadLen(shape: u8) usize {
        return switch (shape % 6) {
            0 => 0,
            1 => 1,
            2 => 15,
            3 => 16,
            else => shape % 17,
        };
    }

    fn shapedTag(raw_value: u16, shape: u8) u16 {
        return switch (shape % 6) {
            0 => 0,
            1 => 1,
            2 => 0x7f,
            3 => 0x80,
            4 => std.math.maxInt(u16),
            else => raw_value,
        };
    }
};

fn checkAllocationProperty(smith: *std.testing.Smith) anyerror!void {
    var controls: [12]u8 = undefined;
    var payload_storage: [4][16]u8 = undefined;
    var children_storage: [4]OwnedChild = undefined;
    const value = OwnedInput.generate(
        smith,
        &controls,
        &payload_storage,
        &children_storage,
    );

    var encoded_storage: [256]u8 = undefined;
    const encoded = try rlp.encode(OwnedValue, &encoded_storage, &value);

    const expected_depth: usize = if (value.children.len == 0) 2 else 3;
    const expected_items = 2 + 3 * value.children.len;
    var expected_allocated = @sizeOf(OwnedChild) * value.children.len;
    for (value.children) |child| expected_allocated += child.payload.len;

    var exact_budget = rlp.Budget.init(.{
        .max_depth = expected_depth,
        .max_items = expected_items,
        .max_allocated_bytes = expected_allocated,
    });
    var decoded = try rlp.decodeAllocWithBudget(
        OwnedValue,
        std.testing.allocator,
        encoded,
        &exact_budget,
    );
    defer rlp.deinit(OwnedValue, std.testing.allocator, &decoded);
    try expectOwnedEqual(value, decoded);
    try std.testing.expectEqual(expected_items, exact_budget.visited_items);
    try std.testing.expectEqual(expected_allocated, exact_budget.allocated_bytes);

    var item_budget = rlp.Budget.init(.{ .max_items = expected_items - 1 });
    try expectBudgetError(error.DecodeItemLimitExceeded, encoded, &item_budget);

    var depth_budget = rlp.Budget.init(.{ .max_depth = expected_depth - 1 });
    try expectBudgetError(error.DecodeDepthLimitExceeded, encoded, &depth_budget);

    if (expected_allocated > 0) {
        const selector = std.mem.readInt(u16, controls[9..11], .little);
        var allocation_budget = rlp.Budget.init(.{
            .max_allocated_bytes = @as(usize, selector) % expected_allocated,
        });
        try expectBudgetError(
            error.DecodeAllocationLimitExceeded,
            encoded,
            &allocation_budget,
        );
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeOwned,
        .{encoded},
    );
}

const CombinedProperty = struct {
    const value_zero_seed = [_]u8{0} ** 176;
    const mutation_zero_seed = [_]u8{0} ** 184;
    const owned_zero_seed = [_]u8{0} ** 84;
    const value_boundary_seed = ValueInput.long_boundary_seed ++ [_]u8{0} ** 168;
    const mutation_boundary_seed = MutationProperty.boundary_seed ++ [_]u8{0} ** 168;

    const zero_seed = RawProperty.empty_input ++
        value_zero_seed ++ value_zero_seed ++ mutation_zero_seed ++ owned_zero_seed;
    const arbitrary_seed = RawProperty.nested_list ++
        ValueInput.arbitrary_seed ++ ValueInput.arbitrary_seed ++
        MutationProperty.arbitrary_seed ++ OwnedInput.arbitrary_seed;
    const boundary_seed = RawProperty.bytes_56 ++
        value_boundary_seed ++ value_boundary_seed ++
        mutation_boundary_seed ++ OwnedInput.full_seed;
    const invalid_raw_seed = RawProperty.noncanonical_single ++
        ValueInput.arbitrary_seed ++ ValueInput.arbitrary_seed ++
        MutationProperty.arbitrary_seed ++ OwnedInput.arbitrary_seed;

    const corpus = [_][]const u8{
        &zero_seed,
        &arbitrary_seed,
        &boundary_seed,
        &invalid_raw_seed,
    };

    fn oracle(_: void, smith: *std.testing.Smith) anyerror!void {
        try RawProperty.check(smith);
        try checkValueProperty(smith);
        try checkEmitterProperty(smith);
        try MutationProperty.check(smith);
        try checkAllocationProperty(smith);
    }
};

test "RLP raw, typed, emitter, mutation, and allocation properties" {
    try std.testing.fuzz({}, CombinedProperty.oracle, .{ .corpus = &CombinedProperty.corpus });
}

fn decodeOwned(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var decoded = try rlp.decodeAlloc(OwnedValue, allocator, encoded);
    defer rlp.deinit(OwnedValue, allocator, &decoded);
}

fn expectBudgetError(
    expected: anyerror,
    encoded: []const u8,
    budget: *rlp.Budget,
) !void {
    if (rlp.decodeAllocWithBudget(
        OwnedValue,
        std.testing.allocator,
        encoded,
        budget,
    )) |decoded_value| {
        var decoded = decoded_value;
        defer rlp.deinit(OwnedValue, std.testing.allocator, &decoded);
        return error.ExpectedDecodeBudgetFailure;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

fn expectOwnedEqual(expected: OwnedValue, actual: OwnedValue) !void {
    try std.testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try std.testing.expectEqual(expected_child.tag, actual_child.tag);
        try std.testing.expectEqualSlices(u8, expected_child.payload, actual_child.payload);
    }
}

fn expectRejected(input: []const u8) !void {
    var list_stack: [max_list_depth]rlp.Cursor = undefined;
    if (rlp.validateExact(input, &list_stack, input.len + 1)) |_| {
        return error.ExpectedInvalidRlpMutation;
    } else |_| {}
}

fn expectRawReencoding(input: []const u8) !void {
    const item = try rlp.parseExact(input);
    var output: [max_input_len]u8 = undefined;
    var writer = rlp.Writer.fixed(&output);
    switch (item) {
        .bytes => try writer.bytes(item.payload()),
        .list => try writer.listPayload(item.payload()),
    }
    try std.testing.expectEqualSlices(u8, input, writer.written());
}

fn encodeRaw(value: Value, out: []u8) ![]const u8 {
    var children_payload_storage: [128]u8 = undefined;
    var children_payload = rlp.Writer.fixed(&children_payload_storage);
    for (value.children) |child| {
        var child_payload_storage: [64]u8 = undefined;
        var child_payload = rlp.Writer.fixed(&child_payload_storage);
        try writeRawBool(&child_payload, child.enabled);
        try child_payload.int(u256, child.amount);
        try children_payload.listPayload(child_payload.written());
    }

    var root_payload_storage: [256]u8 = undefined;
    var root_payload = rlp.Writer.fixed(&root_payload_storage);
    try root_payload.int(u64, value.nonce);
    try root_payload.int(u256, value.balance);
    try root_payload.bytes(value.data);
    try root_payload.listPayload(children_payload.written());

    var writer = rlp.Writer.fixed(out);
    try writer.listPayload(root_payload.written());
    return writer.written();
}

fn encodeRuntimeRaw(value: Value, out: []u8) ![]const u8 {
    var children_payload_storage: [128]u8 = undefined;
    var children_payload = rlp.Writer.fixed(&children_payload_storage);
    for (value.children) |child| {
        if (!child.enabled) continue;

        var child_payload_storage: [64]u8 = undefined;
        var child_payload = rlp.Writer.fixed(&child_payload_storage);
        try writeRawBool(&child_payload, child.enabled);
        try child_payload.int(u256, child.amount);
        try children_payload.listPayload(child_payload.written());
    }

    var root_payload_storage: [256]u8 = undefined;
    var root_payload = rlp.Writer.fixed(&root_payload_storage);
    try root_payload.int(u64, value.nonce);
    try root_payload.int(u256, value.balance);
    if (value.data.len != 0) try root_payload.bytes(value.data);
    try root_payload.listPayload(children_payload.written());

    var writer = rlp.Writer.fixed(out);
    try writer.listPayload(root_payload.written());
    return writer.written();
}

fn writeRawBool(writer: *rlp.Writer, value: bool) !void {
    if (value) {
        try writer.bytes(&.{0x01});
    } else {
        try writer.bytes(&.{});
    }
}
