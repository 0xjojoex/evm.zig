//! Target-specific inline layout diagnostics. No runtime allocation.

const std = @import("std");

pub const Options = struct {
    /// Supply a measured peak count when evaluating a real collection.
    count: usize = 1,
    /// A modeling assumption, not a detected hardware property.
    cache_line_bytes: usize = 64,
};

/// Prints a comptime-built report to stderr without making compilation fail.
pub fn dump(comptime T: type, comptime options: Options) void {
    std.debug.print("{s}", .{comptime report(T, options)});
}

/// Returns a report in physical field order. Byte ranges are half-open.
/// Packed structs use bit ranges and backing-storage slack instead of summing
/// standalone field sizes. Comptime fields have no storage and are omitted.
/// Only inline storage is counted, never pointees or collection capacity.
pub fn report(comptime T: type, comptime options: Options) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        const info = switch (@typeInfo(T)) {
            .@"struct" => |info| info,
            else => @compileError("expected struct"),
        };
        std.debug.assert(options.cache_line_bytes > 0);
        const packed_layout = info.layout == .@"packed";
        const unit: usize = if (packed_layout) 1 else 8;
        const size = @sizeOf(T);
        const storage = size * 8 / unit;

        // Auto-layout structs need not follow declaration order.
        var order: [info.fields.len]usize = undefined;
        var len: usize = 0;
        for (info.fields, 0..) |field, index| {
            if (field.is_comptime) continue;
            var pos = len;
            while (pos > 0 and
                @bitOffsetOf(T, info.fields[order[pos - 1]].name) > @bitOffsetOf(T, field.name))
            {
                order[pos] = order[pos - 1];
                pos -= 1;
            }
            order[pos] = index;
            len += 1;
        }

        var text: []const u8 = std.fmt.comptimePrint(
            "\n{s}\n  layout={s} size={d} B align={d} B stride={d} B\n" ++
                "  physical order; ranges in {s}\n" ++
                "  {s:>6} {s:>6} {s:>6} {s:>5}  {s}\n",
            .{
                @typeName(T),                           @tagName(info.layout), size,  @alignOf(T), size,
                if (packed_layout) "bits" else "bytes", "start",               "end", "size",      "align",
                "field: type",
            },
        );
        var cursor: usize = 0;
        var field_storage: usize = 0;
        for (order[0..len]) |index| {
            const field = info.fields[index];
            const start = @bitOffsetOf(T, field.name) / unit;
            const width = if (packed_layout) @bitSizeOf(field.type) else @sizeOf(field.type);
            if (width > 0 and start > cursor) {
                text = text ++ gap(cursor, start, "<padding>");
            }
            text = text ++ std.fmt.comptimePrint("  {d:>6} {d:>6} {d:>6} ", .{
                start, start + width, width,
            });
            text = text ++ if (packed_layout)
                "    -"
            else
                std.fmt.comptimePrint("{d:>5}", .{field.alignment orelse @alignOf(field.type)});
            text = text ++ std.fmt.comptimePrint("  {s}: {s}", .{ field.name, @typeName(field.type) });
            if (!packed_layout) {
                switch (@typeInfo(field.type)) {
                    .optional => |optional| {
                        text = text ++ std.fmt.comptimePrint(" [optional growth: {d} B]", .{
                            @sizeOf(field.type) - @sizeOf(optional.child),
                        });
                    },
                    .pointer => text = text ++ " [pointee excluded]",
                    else => {},
                }
            }
            text = text ++ "\n";
            field_storage += width;
            if (width > 0) cursor = @max(cursor, start + width);
        }
        if (cursor < storage) {
            text = text ++ gap(cursor, storage, if (packed_layout) "<backing slack>" else "<tail padding>");
        }
        const padding = storage - field_storage;
        const percent: f64 = if (storage == 0) 0 else 100 * @as(f64, @floatFromInt(padding)) / @as(f64, @floatFromInt(storage));
        text = text ++ std.fmt.comptimePrint(
            "  field storage={d} {s}; {s}={d} {s} ({d:.2}%)\n" ++
                "  count={d}: inline={d} B; {s}={d} {s}\n",
            .{
                field_storage,                                           if (packed_layout) "bits" else "B",
                if (packed_layout) "backing slack" else "outer padding", padding,
                if (packed_layout) "bits" else "B",                      percent,
                options.count,                                           size * options.count,
                if (packed_layout) "backing slack" else "outer padding", padding * options.count,
                if (packed_layout) "bits" else "B",
            },
        );
        if (!packed_layout) {
            text = text ++ std.fmt.comptimePrint(
                "  separate field arrays: {d} B before capacity/alignment overhead\n",
                .{field_storage * options.count},
            );
        }
        const line = options.cache_line_bytes;
        const total = size * options.count;
        text = text ++ std.fmt.comptimePrint(
            "  {d} B line model: {d} whole rows/line; {d} lines/row; {d} lines/array\n",
            .{ line, if (size == 0) 0 else line / size, try std.math.divCeil(usize, size, line), try std.math.divCeil(usize, total, line) },
        );
        break :blk text;
    };
}

fn gap(comptime start: usize, comptime end: usize, comptime label: []const u8) []const u8 {
    return std.fmt.comptimePrint("  {d:>6} {d:>6} {d:>6}     -  {s}\n", .{
        start, end, end - start, label,
    });
}
