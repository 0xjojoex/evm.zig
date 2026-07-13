//! Concrete schemas used by the consensus-spec generic SSZ fixtures.
//!
//! These belong to the fixture adapter, not the reusable SSZ library.

const ssz = @import("ssz");

pub const SingleFieldTestStruct = struct {
    A: u8,
};
pub const SingleFieldTestStructSsz = ssz.Container(SingleFieldTestStruct, .{});

pub const SmallTestStruct = struct {
    A: u16,
    B: u16,
};
pub const SmallTestStructSsz = ssz.Container(SmallTestStruct, .{});

pub const FixedTestStruct = struct {
    A: u8,
    B: u64,
    C: u32,
};
pub const FixedTestStructSsz = ssz.Container(FixedTestStruct, .{});

pub const VarTestStruct = struct {
    A: u16,
    B: []const u16,
    C: u8,
};
pub const VarTestStructSsz = ssz.Container(VarTestStruct, .{
    .B = ssz.List(u16, 1024),
});

const VarTestStructPairSsz = ssz.VectorOf(VarTestStructSsz, 2);

pub const ComplexTestStruct = struct {
    A: u16,
    B: []const u16,
    C: u8,
    D: []const u8,
    E: VarTestStruct,
    F: [4]FixedTestStruct,
    G: VarTestStructPairSsz.Value,
};
pub const ComplexTestStructSsz = ssz.Container(ComplexTestStruct, .{
    .B = ssz.List(u16, 128),
    .D = ssz.ByteList(256),
    .E = VarTestStructSsz,
    .G = VarTestStructPairSsz,
});

const ProgressiveVarListSsz = ssz.ProgressiveListOf(VarTestStructSsz);
const NestedProgressiveVarListSsz = ssz.ProgressiveListOf(ProgressiveVarListSsz);

pub const ProgressiveTestStruct = struct {
    A: []const u8,
    B: []const u64,
    C: []const SmallTestStruct,
    D: []const []const VarTestStruct,
};
pub const ProgressiveTestStructSsz = ssz.Container(ProgressiveTestStruct, .{
    .A = ssz.ProgressiveByteList,
    .B = ssz.ProgressiveList(u64),
    .C = ssz.ProgressiveListOf(SmallTestStructSsz),
    .D = NestedProgressiveVarListSsz,
});

pub const BitsStruct = struct {
    A: []const bool,
    B: [2]bool,
    C: [1]bool,
    D: []const bool,
    E: [8]bool,
};
pub const BitsStructSsz = ssz.Container(BitsStruct, .{
    .A = ssz.Bitlist(5),
    .B = ssz.Bitvector(2),
    .C = ssz.Bitvector(1),
    .D = ssz.Bitlist(6),
    .E = ssz.Bitvector(8),
});

pub const ProgressiveBitsStruct = struct {
    A: [256]bool,
    B: []const bool,
    C: []const bool,
    D: [257]bool,
    E: []const bool,
    F: []const bool,
    G: [1280]bool,
    H: []const bool,
    I: []const bool,
    J: [1281]bool,
    K: []const bool,
    L: []const bool,
};
pub const ProgressiveBitsStructSsz = ssz.Container(ProgressiveBitsStruct, .{
    .A = ssz.Bitvector(256),
    .B = ssz.Bitlist(256),
    .C = ssz.ProgressiveBitlist,
    .D = ssz.Bitvector(257),
    .E = ssz.Bitlist(257),
    .F = ssz.ProgressiveBitlist,
    .G = ssz.Bitvector(1280),
    .H = ssz.Bitlist(1280),
    .I = ssz.ProgressiveBitlist,
    .J = ssz.Bitvector(1281),
    .K = ssz.Bitlist(1281),
    .L = ssz.ProgressiveBitlist,
});

pub const ProgressiveSingleFieldContainerTestStruct = struct {
    A: u8,
};
pub const ProgressiveSingleFieldContainerTestStructSsz = ssz.ProgressiveContainer(
    ProgressiveSingleFieldContainerTestStruct,
    [_]bool{true},
    .{},
);

pub const ProgressiveSingleListContainerTestStruct = struct {
    C: []const bool,
};
pub const ProgressiveSingleListContainerTestStructSsz = ssz.ProgressiveContainer(
    ProgressiveSingleListContainerTestStruct,
    [_]bool{ false, false, false, false, true },
    .{ .C = ssz.ProgressiveBitlist },
);

pub const ProgressiveVarTestStruct = struct {
    A: u8,
    B: []const u16,
    C: []const bool,
};
pub const ProgressiveVarTestStructSsz = ssz.ProgressiveContainer(
    ProgressiveVarTestStruct,
    [_]bool{ true, false, true, false, true },
    .{
        .B = ssz.List(u16, 123),
        .C = ssz.ProgressiveBitlist,
    },
);

const ProgressiveSingleFieldListSsz = ssz.ListOf(
    ProgressiveSingleFieldContainerTestStructSsz,
    10,
);
const ProgressiveVarListForFixtureSsz = ssz.ProgressiveListOf(ProgressiveVarTestStructSsz);

pub const ProgressiveComplexTestStruct = struct {
    A: u8,
    B: []const u16,
    C: []const bool,
    D: []const u64,
    E: []const SmallTestStruct,
    F: []const []const VarTestStruct,
    G: []const ProgressiveSingleFieldContainerTestStruct,
    H: []const ProgressiveVarTestStruct,
};
pub const ProgressiveComplexTestStructSsz = ssz.ProgressiveContainer(
    ProgressiveComplexTestStruct,
    [_]bool{
        true,  false, true,  false, true, false, false, false,
        true,  false, false, false, true, true,  false, false,
        false, false, false, false, true, true,
    },
    .{
        .B = ssz.List(u16, 123),
        .C = ssz.ProgressiveBitlist,
        .D = ssz.ProgressiveList(u64),
        .E = ssz.ProgressiveListOf(SmallTestStructSsz),
        .F = NestedProgressiveVarListSsz,
        .G = ProgressiveSingleFieldListSsz,
        .H = ProgressiveVarListForFixtureSsz,
    },
);

pub const CompatibleUnionAValue = union(enum) {
    A: ProgressiveSingleFieldContainerTestStruct,
};
pub const CompatibleUnionASsz = ssz.CompatibleUnion(CompatibleUnionAValue, .{
    .A = .{ .selector = 1, .codec = ProgressiveSingleFieldContainerTestStructSsz },
});

pub const CompatibleUnionBCValue = union(enum) {
    B: ProgressiveSingleListContainerTestStruct,
    C: ProgressiveVarTestStruct,
};
pub const CompatibleUnionBCSsz = ssz.CompatibleUnion(CompatibleUnionBCValue, .{
    .B = .{ .selector = 2, .codec = ProgressiveSingleListContainerTestStructSsz },
    .C = .{ .selector = 3, .codec = ProgressiveVarTestStructSsz },
});

pub const CompatibleUnionABCAValue = union(enum) {
    A1: ProgressiveSingleFieldContainerTestStruct,
    B: ProgressiveSingleListContainerTestStruct,
    C: ProgressiveVarTestStruct,
    A4: ProgressiveSingleFieldContainerTestStruct,
};
pub const CompatibleUnionABCASsz = ssz.CompatibleUnion(CompatibleUnionABCAValue, .{
    .A1 = .{ .selector = 1, .codec = ProgressiveSingleFieldContainerTestStructSsz },
    .B = .{ .selector = 2, .codec = ProgressiveSingleListContainerTestStructSsz },
    .C = .{ .selector = 3, .codec = ProgressiveVarTestStructSsz },
    .A4 = .{ .selector = 4, .codec = ProgressiveSingleFieldContainerTestStructSsz },
});
