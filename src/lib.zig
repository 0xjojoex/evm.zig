//! Strict raw, value-first, and reusable Recursive Length Prefix codecs.

const raw = @import("raw.zig");
const decoder = @import("decoder.zig");
const codec = @import("codec.zig");
const emitter = @import("emitter.zig");

pub const ParseError = raw.ParseError;
pub const ValidationError = raw.ValidationError;
pub const EncodeError = codec.EncodeError;
pub const DecodeError = codec.DecodeError;

pub const Writer = raw.Writer;
pub const Item = raw.Item;
pub const Kind = raw.Kind;
pub const Cursor = raw.Cursor;
pub const max_length_prefix_bytes = raw.max_length_prefix_bytes;
pub const listPrefix = raw.listPrefix;
pub const parseExact = raw.parseExact;
pub const validateExact = raw.validateExact;

pub const Limits = decoder.Limits;
pub const Budget = decoder.Budget;
pub const Decoder = decoder.Decoder;

pub const Encoder = codec.Encoder;
pub const encodedLen = codec.encodedLen;
pub const encodedLenAs = codec.encodedLenAs;
pub const encode = codec.encode;
pub const encodeAs = codec.encodeAs;
pub const encodeAlloc = codec.encodeAlloc;
pub const encodeAllocAs = codec.encodeAllocAs;
pub const encodeToWriter = codec.encodeToWriter;
pub const encodeToWriterAs = codec.encodeToWriterAs;
pub const encodedListLen = emitter.encodedListLen;
pub const encodeList = emitter.encodeList;
pub const encodeListAlloc = emitter.encodeListAlloc;
pub const decode = codec.decode;
pub const decodeAs = codec.decodeAs;
pub const decodeWithBudget = codec.decodeWithBudget;
pub const decodeWithBudgetAs = codec.decodeWithBudgetAs;
pub const decodeAlloc = codec.decodeAlloc;
pub const decodeAllocAs = codec.decodeAllocAs;
pub const decodeAllocWithBudget = codec.decodeAllocWithBudget;
pub const decodeAllocWithBudgetAs = codec.decodeAllocWithBudgetAs;
pub const deinit = codec.deinit;
pub const deinitAs = codec.deinitAs;

pub const FixedBytes = codec.FixedBytes;
pub const OptionalFixedBytes = codec.OptionalFixedBytes;
pub const Raw = codec.Raw;
pub const Struct = codec.Struct;
pub const ArrayOf = codec.ArrayOf;
pub const ListOf = codec.ListOf;
pub const BoundedListOf = codec.BoundedListOf;
pub const Mapped = codec.Mapped;
pub const Field = codec.Field;
