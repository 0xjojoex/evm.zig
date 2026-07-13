//! SSZ encoding and decoding.
//!
//! This package is independent from evmz build profiles. Canonical SSZ
//! Merkleization uses stdlib SHA-256 by default and accepts an explicit
//! implementation context for accelerated environments.

const basic = @import("basic.zig");
const vector = @import("vector.zig");
const list = @import("list.zig");
const union_codec = @import("union.zig");
const container = @import("container.zig");
const merkle = @import("merkle.zig");
const allocated = @import("allocated.zig");
const mapped = @import("mapped.zig");
const bitfield = @import("bitfield.zig");
const codec = @import("codec.zig");

pub const Error = basic.Error;
pub const encodedSize = basic.encodedSize;
pub const encode = basic.encode;
pub const encodeInto = basic.encodeInto;
pub const decode = basic.decode;
pub const decodeSlice = basic.decodeSlice;
pub const Fixed = basic.Fixed;
pub const IntEnum = basic.IntEnum;

pub const ByteVector = vector.ByteVector;
pub const VectorOf = vector.VectorOf;
pub const VectorSliceOf = vector.VectorSliceOf;

pub const Alloc = allocated.Alloc;
pub const Mapped = mapped.Mapped;

pub const ByteList = list.ByteList;
pub const ProgressiveByteList = list.ProgressiveByteList;
pub const List = list.List;
pub const ProgressiveList = list.ProgressiveList;
pub const OptionalList = list.OptionalList;
pub const ListOf = list.ListOf;
pub const ProgressiveListOf = list.ProgressiveListOf;

pub const Bitvector = bitfield.Bitvector;
pub const Bitlist = bitfield.Bitlist;
pub const ProgressiveBitlist = bitfield.ProgressiveBitlist;

pub const None = union_codec.None;
pub const Union = union_codec.Union;
pub const CompatibleUnion = union_codec.CompatibleUnion;

pub const Container = container.Container;
pub const codecFor = container.codecFor;
pub const ProgressiveContainer = container.ProgressiveContainer;

pub const encodeAlloc = codec.encodeAlloc;
pub const decodeOwned = codec.decodeOwned;
pub const deinitOwned = codec.deinitOwned;

pub const Root = merkle.Root;
pub const zero_roots = merkle.zero_roots;
pub const precomputed_zero_root_count = merkle.precomputed_zero_root_count;
pub const declaredTreeDepth = merkle.declaredTreeDepth;
pub const TreePath = merkle.TreePath;
pub const TreeNode = merkle.TreeNode;
pub const StdSha256Context = merkle.StdSha256Context;
pub const Merkleizer = merkle.Merkleizer;
pub const hashTreeRoot = merkle.hashTreeRoot;
pub const walkTree = merkle.walkTree;
