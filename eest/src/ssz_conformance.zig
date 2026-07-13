const std = @import("std");
const snappy = @import("snappyz");
const ssz = @import("ssz");
const schemas = @import("ssz_fixture_schemas.zig");
const static_schemas = @import("ssz_static.zig");

const max_fixture_size = 256 * 1024 * 1024;
const fixture_bit_lengths = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 511, 512, 513 };
const fixture_vector_lengths = [_]usize{ 1, 2, 3, 4, 5, 8, 16, 31, 512, 513 };

pub const FailureReason = enum {
    valid_rejected,
    invalid_accepted,
    roundtrip_mismatch,
    root_mismatch,
};

pub const Result = union(enum) {
    passed,
    skipped,
    failed: FailureReason,
};

const FixtureType = union(enum) {
    boolean,
    uint8,
    uint16,
    uint32,
    uint64,
    uint128,
    uint256,
    bitvector: usize,
    bitlist: usize,
    basic_vector: BasicVector,
    progressive_bitlist,
    basic_progressive_list: BasicElement,
    container: ContainerSchema,
    progressive_container: ProgressiveContainerSchema,
    compatible_union: CompatibleUnionSchema,
};

const ContainerSchema = enum {
    bits,
    complex,
    fixed,
    progressive_bits,
    progressive,
    single_field,
    small,
    variable,
};

const ProgressiveContainerSchema = enum {
    complex,
    single_field,
    single_list,
    variable,
};

const CompatibleUnionSchema = enum {
    a,
    abca,
    bc,
};

const BasicElement = enum {
    boolean,
    uint8,
    uint16,
    uint32,
    uint64,
    uint128,
    uint256,
};

const BasicVector = struct {
    element: BasicElement,
    length: usize,
};

const Expectation = struct {
    valid: bool,
    root: ?ssz.Root,
};

const StaticFixture = struct {
    preset: static_schemas.Preset,
    fork: static_schemas.Fork,
    handler: []const u8,
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    if (try staticFixture(path)) |fixture| {
        const expectation = Expectation{
            .valid = true,
            .root = try expectedRoot(io, allocator, path, "roots.yaml"),
        };
        const serialized = try readFixture(io, allocator, path);
        defer allocator.free(serialized);
        return runStaticFixture(allocator, fixture, serialized, expectation);
    }

    const fixture_type = try fixtureType(path) orelse return .skipped;
    const valid = try expectedValidity(path);
    const expectation = Expectation{
        .valid = valid,
        .root = if (valid) try expectedRoot(io, allocator, path, "meta.yaml") else null,
    };
    const serialized = try readFixture(io, allocator, path);
    defer allocator.free(serialized);

    return runGenericFixture(allocator, fixture_type, serialized, expectation);
}

fn readFixture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const compressed = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_fixture_size));
    defer allocator.free(compressed);
    return snappy.decodeWithMax(allocator, compressed, max_fixture_size);
}

fn runGenericFixture(
    allocator: std.mem.Allocator,
    fixture_type: FixtureType,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    return switch (fixture_type) {
        .boolean => runFixed(bool, serialized, expectation),
        .uint8 => runFixed(u8, serialized, expectation),
        .uint16 => runFixed(u16, serialized, expectation),
        .uint32 => runFixed(u32, serialized, expectation),
        .uint64 => runFixed(u64, serialized, expectation),
        .uint128 => runFixed(u128, serialized, expectation),
        .uint256 => runFixed(u256, serialized, expectation),
        .bitvector => |length| try runBitvector(allocator, length, serialized, expectation),
        .bitlist => |limit| try runBitlist(allocator, limit, serialized, expectation),
        .basic_vector => |vector| runBasicVector(vector, serialized, expectation),
        .progressive_bitlist => try runCodec(allocator, ssz.ProgressiveBitlist, serialized, expectation),
        .basic_progressive_list => |element| try runBasicProgressiveList(
            allocator,
            element,
            serialized,
            expectation,
        ),
        .container => |schema| try runContainer(allocator, schema, serialized, expectation),
        .progressive_container => |schema| try runProgressiveContainer(
            allocator,
            schema,
            serialized,
            expectation,
        ),
        .compatible_union => |schema| try runCompatibleUnion(
            allocator,
            schema,
            serialized,
            expectation,
        ),
    };
}

fn runStaticFixture(
    allocator: std.mem.Allocator,
    fixture: StaticFixture,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    inline for (std.meta.fields(static_schemas.Preset)) |preset_field| {
        const preset: static_schemas.Preset = @enumFromInt(preset_field.value);
        if (fixture.preset == preset) {
            const PresetSchemas = @field(static_schemas, preset_field.name);
            inline for (std.meta.fields(static_schemas.Fork)) |fork_field| {
                const fork: static_schemas.Fork = @enumFromInt(fork_field.value);
                if (fixture.fork == fork) {
                    return runStaticModule(
                        allocator,
                        @field(PresetSchemas, fork_field.name),
                        fixture.handler,
                        serialized,
                        expectation,
                    );
                }
            }
        }
    }
    unreachable;
}

fn runStaticModule(
    allocator: std.mem.Allocator,
    comptime Module: type,
    handler_name: []const u8,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    inline for (Module.handlers) |handler| {
        if (std.mem.eql(u8, handler_name, handler.name)) {
            return runCodec(allocator, handler.codec, serialized, expectation);
        }
    }
    return error.UnsupportedStaticFixtureType;
}

fn runContainer(
    allocator: std.mem.Allocator,
    schema: ContainerSchema,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    return switch (schema) {
        .bits => runCodec(allocator, schemas.BitsStructSsz, serialized, expectation),
        .complex => runCodec(allocator, schemas.ComplexTestStructSsz, serialized, expectation),
        .fixed => runCodec(allocator, schemas.FixedTestStructSsz, serialized, expectation),
        .progressive_bits => runCodec(allocator, schemas.ProgressiveBitsStructSsz, serialized, expectation),
        .progressive => runCodec(allocator, schemas.ProgressiveTestStructSsz, serialized, expectation),
        .single_field => runCodec(allocator, schemas.SingleFieldTestStructSsz, serialized, expectation),
        .small => runCodec(allocator, schemas.SmallTestStructSsz, serialized, expectation),
        .variable => runCodec(allocator, schemas.VarTestStructSsz, serialized, expectation),
    };
}

fn runProgressiveContainer(
    allocator: std.mem.Allocator,
    schema: ProgressiveContainerSchema,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    return switch (schema) {
        .complex => runCodec(allocator, schemas.ProgressiveComplexTestStructSsz, serialized, expectation),
        .single_field => runCodec(
            allocator,
            schemas.ProgressiveSingleFieldContainerTestStructSsz,
            serialized,
            expectation,
        ),
        .single_list => runCodec(
            allocator,
            schemas.ProgressiveSingleListContainerTestStructSsz,
            serialized,
            expectation,
        ),
        .variable => runCodec(allocator, schemas.ProgressiveVarTestStructSsz, serialized, expectation),
    };
}

fn runCompatibleUnion(
    allocator: std.mem.Allocator,
    schema: CompatibleUnionSchema,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    return switch (schema) {
        .a => runCodec(allocator, schemas.CompatibleUnionASsz, serialized, expectation),
        .abca => runCodec(allocator, schemas.CompatibleUnionABCASsz, serialized, expectation),
        .bc => runCodec(allocator, schemas.CompatibleUnionBCSsz, serialized, expectation),
    };
}

fn runBasicProgressiveList(
    allocator: std.mem.Allocator,
    element: BasicElement,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    return switch (element) {
        .boolean => runCodec(allocator, ssz.ProgressiveList(bool), serialized, expectation),
        .uint8 => runCodec(allocator, ssz.ProgressiveList(u8), serialized, expectation),
        .uint16 => runCodec(allocator, ssz.ProgressiveList(u16), serialized, expectation),
        .uint32 => runCodec(allocator, ssz.ProgressiveList(u32), serialized, expectation),
        .uint64 => runCodec(allocator, ssz.ProgressiveList(u64), serialized, expectation),
        .uint128 => runCodec(allocator, ssz.ProgressiveList(u128), serialized, expectation),
        .uint256 => runCodec(allocator, ssz.ProgressiveList(u256), serialized, expectation),
    };
}

fn runBasicVector(vector: BasicVector, serialized: []const u8, expectation: Expectation) Result {
    if (vector.length == 0) {
        return if (expectation.valid) .{ .failed = .valid_rejected } else .passed;
    }
    inline for (fixture_vector_lengths) |supported| {
        if (vector.length == supported) {
            return switch (vector.element) {
                .boolean => runFixed([supported]bool, serialized, expectation),
                .uint8 => runFixed([supported]u8, serialized, expectation),
                .uint16 => runFixed([supported]u16, serialized, expectation),
                .uint32 => runFixed([supported]u32, serialized, expectation),
                .uint64 => runFixed([supported]u64, serialized, expectation),
                .uint128 => runFixed([supported]u128, serialized, expectation),
                .uint256 => runFixed([supported]u256, serialized, expectation),
            };
        }
    }
    return .skipped;
}

fn runFixed(comptime T: type, serialized: []const u8, expectation: Expectation) Result {
    if (!expectation.valid) {
        if (ssz.decodeSlice(T, serialized)) |_| {
            return .{ .failed = .invalid_accepted };
        } else |_| {
            return .passed;
        }
    }

    const decoded = ssz.decodeSlice(T, serialized) catch
        return .{ .failed = .valid_rejected };
    const encoded = ssz.encode(decoded);
    if (!std.mem.eql(u8, serialized, &encoded)) {
        return .{ .failed = .roundtrip_mismatch };
    }
    const actual_root = ssz.hashTreeRoot(ssz.Fixed(T), decoded) catch
        return .{ .failed = .valid_rejected };
    if (!std.mem.eql(u8, &actual_root, &expectation.root.?)) {
        printRootMismatch(expectation.root.?, actual_root);
        return .{ .failed = .root_mismatch };
    }
    return .passed;
}

fn runCodec(
    allocator: std.mem.Allocator,
    comptime Codec: type,
    serialized: []const u8,
    expectation: Expectation,
) !Result {
    if (!expectation.valid) {
        Codec.validate(serialized) catch return .passed;
        return .{ .failed = .invalid_accepted };
    }

    var decoded = ssz.decodeOwned(Codec, allocator, serialized) catch
        return .{ .failed = .valid_rejected };
    defer ssz.deinitOwned(Codec, allocator, &decoded);
    const len = Codec.encodedLen(decoded) catch
        return .{ .failed = .valid_rejected };
    const encoded = try allocator.alloc(u8, len);
    defer allocator.free(encoded);
    const actual = Codec.encode(encoded, decoded) catch
        return .{ .failed = .valid_rejected };
    if (!std.mem.eql(u8, serialized, actual)) {
        return .{ .failed = .roundtrip_mismatch };
    }
    const actual_root = ssz.hashTreeRoot(Codec, decoded) catch
        return .{ .failed = .valid_rejected };
    if (!std.mem.eql(u8, &actual_root, &expectation.root.?)) {
        printRootMismatch(expectation.root.?, actual_root);
        return .{ .failed = .root_mismatch };
    }
    return .passed;
}

fn printRootMismatch(expected: ssz.Root, actual: ssz.Root) void {
    std.debug.print(
        "root expected=0x{x} actual=0x{x}\n",
        .{ &expected, &actual },
    );
}

fn runBitvector(allocator: std.mem.Allocator, length: usize, serialized: []const u8, expectation: Expectation) !Result {
    if (length == 0) {
        return if (expectation.valid) .{ .failed = .valid_rejected } else .passed;
    }
    inline for (fixture_bit_lengths) |supported| {
        if (length == supported) {
            return runCodec(allocator, ssz.Bitvector(supported), serialized, expectation);
        }
    }
    return .skipped;
}

fn runBitlist(allocator: std.mem.Allocator, limit: usize, serialized: []const u8, expectation: Expectation) !Result {
    inline for (fixture_bit_lengths) |supported| {
        if (limit == supported) {
            return runCodec(allocator, ssz.Bitlist(supported), serialized, expectation);
        }
    }
    return .skipped;
}

fn fixtureType(path: []const u8) !?FixtureType {
    if (hasPathComponent(path, "boolean")) return .boolean;
    if (hasPathComponent(path, "bitvector")) {
        return .{ .bitvector = try caseParameter(path, "bitvec_") };
    }
    if (hasPathComponent(path, "bitlist")) {
        return .{ .bitlist = try caseParameter(path, "bitlist_") };
    }
    if (hasPathComponent(path, "basic_vector")) {
        return .{ .basic_vector = try basicVectorDeclaration(path) };
    }
    if (hasPathComponent(path, "progressive_bitlist")) return .progressive_bitlist;
    if (hasPathComponent(path, "basic_progressive_list")) {
        return .{ .basic_progressive_list = try progressiveListElement(path) };
    }
    if (hasPathComponent(path, "progressive_containers")) {
        return .{ .progressive_container = try progressiveContainerSchema(path) };
    }
    if (hasPathComponent(path, "compatible_unions")) {
        return .{ .compatible_union = try compatibleUnionSchema(path) };
    }
    if (hasPathComponent(path, "containers")) {
        return .{ .container = try containerSchema(path) };
    }
    if (!hasPathComponent(path, "uints")) return null;

    const case_dir = std.fs.path.dirname(path) orelse return error.MalformedFixturePath;
    const case_name = std.fs.path.basename(case_dir);
    if (std.mem.startsWith(u8, case_name, "uint_8_")) return .uint8;
    if (std.mem.startsWith(u8, case_name, "uint_16_")) return .uint16;
    if (std.mem.startsWith(u8, case_name, "uint_32_")) return .uint32;
    if (std.mem.startsWith(u8, case_name, "uint_64_")) return .uint64;
    if (std.mem.startsWith(u8, case_name, "uint_128_")) return .uint128;
    if (std.mem.startsWith(u8, case_name, "uint_256_")) return .uint256;
    return error.MalformedFixturePath;
}

fn staticFixture(path: []const u8) !?StaticFixture {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    var previous_previous: ?[]const u8 = null;
    var previous: ?[]const u8 = null;
    while (components.next()) |component| {
        if (!std.mem.eql(u8, component, "ssz_static")) {
            previous_previous = previous;
            previous = component;
            continue;
        }
        const preset_name = previous_previous orelse return error.MalformedFixturePath;
        const fork_name = previous orelse return error.MalformedFixturePath;
        const handler = components.next() orelse return error.MalformedFixturePath;
        return .{
            .preset = std.meta.stringToEnum(static_schemas.Preset, preset_name) orelse
                return error.MalformedFixturePath,
            .fork = std.meta.stringToEnum(static_schemas.Fork, fork_name) orelse
                return error.MalformedFixturePath,
            .handler = handler,
        };
    }
    return null;
}

fn containerSchema(path: []const u8) !ContainerSchema {
    const name = try fixtureCaseName(path);
    if (std.mem.startsWith(u8, name, "BitsStruct_")) return .bits;
    if (std.mem.startsWith(u8, name, "ComplexTestStruct_")) return .complex;
    if (std.mem.startsWith(u8, name, "FixedTestStruct_")) return .fixed;
    if (std.mem.startsWith(u8, name, "ProgressiveBitsStruct_")) return .progressive_bits;
    if (std.mem.startsWith(u8, name, "ProgressiveTestStruct_")) return .progressive;
    if (std.mem.startsWith(u8, name, "SingleFieldTestStruct_")) return .single_field;
    if (std.mem.startsWith(u8, name, "SmallTestStruct_")) return .small;
    if (std.mem.startsWith(u8, name, "VarTestStruct_")) return .variable;
    return error.MalformedFixturePath;
}

fn progressiveContainerSchema(path: []const u8) !ProgressiveContainerSchema {
    const name = try fixtureCaseName(path);
    if (std.mem.startsWith(u8, name, "ProgressiveComplexTestStruct_")) return .complex;
    if (std.mem.startsWith(u8, name, "ProgressiveSingleFieldContainerTestStruct_")) return .single_field;
    if (std.mem.startsWith(u8, name, "ProgressiveSingleListContainerTestStruct_")) return .single_list;
    if (std.mem.startsWith(u8, name, "ProgressiveVarTestStruct_")) return .variable;
    return error.MalformedFixturePath;
}

fn compatibleUnionSchema(path: []const u8) !CompatibleUnionSchema {
    const name = try fixtureCaseName(path);
    if (std.mem.startsWith(u8, name, "CompatibleUnionABCA_")) return .abca;
    if (std.mem.startsWith(u8, name, "CompatibleUnionA_")) return .a;
    if (std.mem.startsWith(u8, name, "CompatibleUnionBC_")) return .bc;
    return error.MalformedFixturePath;
}

fn fixtureCaseName(path: []const u8) ![]const u8 {
    const case_dir = std.fs.path.dirname(path) orelse return error.MalformedFixturePath;
    return std.fs.path.basename(case_dir);
}

fn progressiveListElement(path: []const u8) !BasicElement {
    const case_dir = std.fs.path.dirname(path) orelse return error.MalformedFixturePath;
    const case_name = std.fs.path.basename(case_dir);
    const prefix = "proglist_";
    if (!std.mem.startsWith(u8, case_name, prefix)) return error.MalformedFixturePath;
    const suffix = case_name[prefix.len..];
    const type_end = std.mem.indexOfScalar(u8, suffix, '_') orelse return error.MalformedFixturePath;
    return parseBasicElement(suffix[0..type_end]) orelse error.MalformedFixturePath;
}

fn basicVectorDeclaration(path: []const u8) !BasicVector {
    const case_dir = std.fs.path.dirname(path) orelse return error.MalformedFixturePath;
    const case_name = std.fs.path.basename(case_dir);
    const prefix = "vec_";
    if (!std.mem.startsWith(u8, case_name, prefix)) return error.MalformedFixturePath;
    const suffix = case_name[prefix.len..];
    const type_end = std.mem.indexOfScalar(u8, suffix, '_') orelse return error.MalformedFixturePath;
    const element = parseBasicElement(suffix[0..type_end]) orelse return error.MalformedFixturePath;
    const length_suffix = suffix[type_end + 1 ..];
    const length_end = std.mem.indexOfScalar(u8, length_suffix, '_') orelse length_suffix.len;
    if (length_end == 0) return error.MalformedFixturePath;
    return .{
        .element = element,
        .length = std.fmt.parseInt(usize, length_suffix[0..length_end], 10) catch
            return error.MalformedFixturePath,
    };
}

fn parseBasicElement(name: []const u8) ?BasicElement {
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "uint8")) return .uint8;
    if (std.mem.eql(u8, name, "uint16")) return .uint16;
    if (std.mem.eql(u8, name, "uint32")) return .uint32;
    if (std.mem.eql(u8, name, "uint64")) return .uint64;
    if (std.mem.eql(u8, name, "uint128")) return .uint128;
    if (std.mem.eql(u8, name, "uint256")) return .uint256;
    return null;
}

fn caseParameter(path: []const u8, prefix: []const u8) !usize {
    const case_dir = std.fs.path.dirname(path) orelse return error.MalformedFixturePath;
    const case_name = std.fs.path.basename(case_dir);
    if (!std.mem.startsWith(u8, case_name, prefix)) return error.MalformedFixturePath;
    const suffix = case_name[prefix.len..];
    const end = std.mem.indexOfScalar(u8, suffix, '_') orelse suffix.len;
    if (end == 0) return error.MalformedFixturePath;
    return std.fmt.parseInt(usize, suffix[0..end], 10) catch error.MalformedFixturePath;
}

fn expectedValidity(path: []const u8) !bool {
    if (hasPathComponent(path, "valid")) return true;
    if (hasPathComponent(path, "invalid")) return false;
    return error.MalformedFixturePath;
}

fn expectedRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    serialized_path: []const u8,
    metadata_name: []const u8,
) !ssz.Root {
    const case_dir = std.fs.path.dirname(serialized_path) orelse return error.MalformedFixturePath;
    const meta_path = try std.fs.path.join(allocator, &.{ case_dir, metadata_name });
    defer allocator.free(meta_path);
    const meta = try std.Io.Dir.cwd().readFileAlloc(io, meta_path, allocator, .limited(4096));
    defer allocator.free(meta);

    var lines = std.mem.splitScalar(u8, meta, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "root:")) continue;
        const quoted = std.mem.trim(u8, line["root:".len..], " \t'\"");
        if (!std.mem.startsWith(u8, quoted, "0x") or quoted.len != 66) {
            return error.InvalidRootMetadata;
        }
        var root: ssz.Root = undefined;
        _ = std.fmt.hexToBytes(&root, quoted[2..]) catch return error.InvalidRootMetadata;
        return root;
    }
    return error.MissingRootMetadata;
}

fn hasPathComponent(path: []const u8, expected: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, expected)) return true;
    }
    return false;
}

test "SSZ conformance classifies boolean and uint fixture paths" {
    try std.testing.expectEqual(
        FixtureType.boolean,
        (try fixtureType("ssz_generic/boolean/valid/true/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType.uint256,
        (try fixtureType("ssz_generic/uints/invalid/uint_256_one_byte_shorter/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .container = .complex },
        (try fixtureType("ssz_generic/containers/valid/ComplexTestStruct_zero/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .bitvector = 513 },
        (try fixtureType("ssz_generic/bitvector/valid/bitvec_513_random/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .bitlist = 8 },
        (try fixtureType("ssz_generic/bitlist/valid/bitlist_8_empty/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqualDeep(
        FixtureType{ .basic_vector = .{ .element = .uint256, .length = 513 } },
        (try fixtureType("ssz_generic/basic_vector/valid/vec_uint256_513_random/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType.progressive_bitlist,
        (try fixtureType("ssz_generic/progressive_bitlist/valid/progbitlist_nil_0/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .basic_progressive_list = .uint128 },
        (try fixtureType("ssz_generic/basic_progressive_list/valid/proglist_uint128_random_86/serialized.ssz_snappy")).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .progressive_container = .single_list },
        (try fixtureType(
            "ssz_generic/progressive_containers/valid/ProgressiveSingleListContainerTestStruct_nil/serialized.ssz_snappy",
        )).?,
    );
    try std.testing.expectEqual(
        FixtureType{ .compatible_union = .abca },
        (try fixtureType(
            "ssz_generic/compatible_unions/valid/CompatibleUnionABCA_zero_selector_1/serialized.ssz_snappy",
        )).?,
    );
}

test "SSZ conformance classifies preset static fixture paths" {
    try std.testing.expectEqualDeep(
        StaticFixture{
            .preset = .minimal,
            .fork = .heze,
            .handler = "BeaconState",
        },
        (try staticFixture(
            "minimal/heze/ssz_static/BeaconState/ssz_random/case_0/serialized.ssz_snappy",
        )).?,
    );
    try std.testing.expectEqual(
        @as(?StaticFixture, null),
        try staticFixture("ssz_generic/boolean/valid/true/serialized.ssz_snappy"),
    );
}

test "SSZ conformance accepts canonical values and rejects malformed values" {
    var true_root: ssz.Root = @splat(0);
    true_root[0] = 1;
    var number_root: ssz.Root = @splat(0);
    number_root[0] = 0x34;
    number_root[1] = 0x12;

    try std.testing.expectEqual(
        Result.passed,
        runFixed(bool, &.{1}, .{ .valid = true, .root = true_root }),
    );
    try std.testing.expectEqual(
        Result.passed,
        runFixed(bool, &.{2}, .{ .valid = false, .root = null }),
    );
    try std.testing.expectEqual(
        Result.passed,
        runFixed(u16, &.{ 0x34, 0x12 }, .{ .valid = true, .root = number_root }),
    );
    try std.testing.expectEqual(
        Result.passed,
        runFixed(u16, &.{0x34}, .{ .valid = false, .root = null }),
    );
}

test "SSZ conformance decodes raw Snappy fixture blocks" {
    const compressed = [_]u8{ 1, 0, 1 };
    const serialized = try snappy.decodeWithMax(std.testing.allocator, &compressed, 1);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqualSlices(u8, &.{1}, serialized);
}
