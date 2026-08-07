//! Versioned stateless guest wire contracts.
//!
//! Guest input is `schema_id || payload`. `-Dstateless-schema=0x1501` (repeatable)
//! picks which ids a build decodes; the router below is generated from that list
//! at comptime, so a single-schema build compiles a single call and pays for one
//! specialized `Validator`. Unknown or malformed ids are a compile error, not a
//! runtime surprise.
//!
//! The router only dispatches on raw bytes, since that is the only place a
//! schema id exists. The typed API (`StatelessInput`, `smokeInput`) stays bound
//! to `primary`; reach through `schemas` or a schema module directly for the rest.

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("./wire/schema.zig");
const block_stf = @import("../eth/block_stf.zig");

pub const v1 = @import("./wire/v1.zig");
const v1_smoke = @import("./wire/v1_smoke.zig");

/// Every schema evmz implements. A build enables a subset of these.
const known = [_]type{v1};

/// Schemas this build decodes, in `-Dstateless-schema` order.
pub const schemas = resolve(build_options.stateless_schemas);

/// Backs the typed API, and absorbs prefixes no enabled schema claims — decoding
/// fails there and becomes the wire's failure result, as it did before routing.
pub const primary = schemas[0];

pub const Error = blk: {
    var set = schemas[0].Error;
    for (schemas[1..]) |Schema| set = set || Schema.Error;
    break :blk set;
};

pub const ProtocolFork = schema.ProtocolFork;
pub const schema_id_size = schema.id_size;
pub const schema_fork = primary.schema_fork;
pub const schema_revision = primary.schema_revision;
pub const schema_id = primary.schema_id;
pub const StatelessInput = primary.StatelessInput;
pub const StatelessValidationResult = primary.StatelessValidationResult;

pub const smokeInput = v1_smoke.smokeInput;
pub const smokeInputBytes = v1_smoke.smokeInputBytes;

/// Validates one guest invocation. Scratch and output share the caller-owned
/// invocation lifetime and are released together after the output is consumed.
pub fn validateStatelessBytes(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    inline for (schemas[1..]) |Schema| {
        if (claims(Schema, bytes)) return Schema.validateStatelessBytes(allocator, bytes);
    }
    return primary.validateStatelessBytes(allocator, bytes);
}

/// Releases validation scratch before returning output owned by `allocator`.
/// Invocation-scoped callers should use `validateStatelessBytes` directly.
pub fn validateStatelessBytesReusable(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    inline for (schemas[1..]) |Schema| {
        if (claims(Schema, bytes)) return Schema.validateStatelessBytesReusable(allocator, bytes);
    }
    return primary.validateStatelessBytesReusable(allocator, bytes);
}

pub fn validateStatelessStatusBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!block_stf.Status {
    return (try validateStatelessResultBytes(allocator, bytes)).status;
}

pub fn validateStatelessResultBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!block_stf.Result {
    inline for (schemas[1..]) |Schema| {
        if (claims(Schema, bytes)) return Schema.validateStatelessResultBytes(allocator, bytes);
    }
    return primary.validateStatelessResultBytes(allocator, bytes);
}

pub fn validateStatelessResultBytesWithCapture(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    capture: ?block_stf.ExecutionCapture,
) Error!block_stf.Result {
    inline for (schemas[1..]) |Schema| {
        if (claims(Schema, bytes)) return Schema.validateStatelessResultBytesWithCapture(allocator, bytes, capture);
    }
    return primary.validateStatelessResultBytesWithCapture(allocator, bytes, capture);
}

fn claims(comptime Schema: type, bytes: []const u8) bool {
    return (schema.readId(bytes) catch return false) == Schema.schema_id;
}

/// Resolves `-Dstateless-schema` ids to schema modules; an empty list enables
/// every known schema. Guest builds should pin explicitly so a new schema does
/// not silently compile a second `Validator` into the ELF.
fn resolve(comptime ids: []const []const u8) [if (ids.len == 0) known.len else ids.len]type {
    comptime {
        for (known, 0..) |Schema, i| {
            if (Schema.schema_id != schema.id(Schema.schema_fork, Schema.schema_revision)) {
                @compileError(@typeName(Schema) ++ " schema_id does not match its fork and revision");
            }
            for (known[0..i]) |Earlier| {
                if (Earlier.schema_id == Schema.schema_id) @compileError("two schemas claim " ++ hex(Schema.schema_id));
            }
        }
        if (ids.len == 0) return known;

        var out: [ids.len]type = undefined;
        for (ids, 0..) |text, i| {
            const wanted = std.fmt.parseInt(u16, text, 0) catch
                @compileError("-Dstateless-schema=" ++ text ++ " is not a schema id; expected e.g. 0x1501");
            out[i] = find(wanted) orelse
                @compileError("-Dstateless-schema=" ++ text ++ " is not implemented; known ids: " ++ knownIds());
            for (out[0..i]) |Earlier| {
                if (Earlier == out[i]) @compileError("-Dstateless-schema=" ++ text ++ " given twice");
            }
        }
        return out;
    }
}

fn find(comptime wanted: u16) ?type {
    for (known) |Schema| {
        if (Schema.schema_id == wanted) return Schema;
    }
    return null;
}

fn hex(comptime id: u16) []const u8 {
    return std.fmt.comptimePrint("0x{x:0>4}", .{id});
}

fn knownIds() []const u8 {
    comptime {
        var text: []const u8 = "";
        for (known, 0..) |Schema, i| text = text ++ (if (i == 0) "" else ", ") ++ hex(Schema.schema_id);
        return text;
    }
}

test {
    _ = v1;
    _ = @import("./wire/v1_test.zig");
}

// Referencing the router here is what forces `resolve` to be analyzed, so a bad
// `-Dstateless-schema` fails the build instead of being lazily skipped.
test "router enables exactly the schemas the build asked for" {
    try std.testing.expectEqual(primary.schema_id, schema_id);
    inline for (schemas) |Schema| {
        try std.testing.expectEqual(Schema.schema_id, schema.id(Schema.schema_fork, Schema.schema_revision));
    }
}

test "router dispatches schema-prefixed bytes to the schema that claims them" {
    const bytes = try smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    const output = try validateStatelessBytesReusable(std.testing.allocator, bytes);
    defer std.testing.allocator.free(output);

    const result = try StatelessValidationResult.decode(std.testing.allocator, output);
    try std.testing.expect(result.successful_validation);
    try std.testing.expectEqual(block_stf.Status.valid, (try validateStatelessResultBytes(std.testing.allocator, bytes)).status);
}

test "router hands prefixes nothing claims to the primary schema" {
    const bytes = try smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    bytes[0] = 0xff;

    const output = try validateStatelessBytesReusable(std.testing.allocator, bytes);
    defer std.testing.allocator.free(output);

    const result = try StatelessValidationResult.decode(std.testing.allocator, output);
    try std.testing.expect(!result.successful_validation);
}

test "reusable validation releases scratch before allocating output" {
    const bytes = try smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const backing = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);

    const output = try validateStatelessBytesReusable(fixed.allocator(), bytes);
    try std.testing.expect(fixed.isLastAllocation(output));
    fixed.allocator().free(output);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}
