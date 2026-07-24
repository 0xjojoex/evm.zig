//! Captured execution facts and passive span consumers.
//!
//! Live step execution has exactly two exact dispatch tables: normal and traced.
//! The traced table writes concrete rows to `TraceTape`; consumer callbacks run only
//! when the completed `TraceSpan` is replayed. Live state and checkpoint facts
//! use the operation-scoped fallible target in `executor/capture_context.zig`.
//!
//! Replayed step events borrow tape storage. Consumers must copy anything they
//! need after the span is resolved.

const std = @import("std");
const address = @import("./address.zig");

pub const tape = @import("./trace/tape.zig");
pub const capture = @import("./trace/capture.zig");
pub const call_arena = @import("./trace/call_arena.zig");
pub const eip3155 = @import("./trace/eip3155.zig");

pub const TraceTapeError = tape.Error;
pub const TraceTape = tape.TraceTape;
pub const CaptureProfile = tape.CaptureProfile;
pub const StackCapture = tape.StackCapture;
pub const MemoryCapture = tape.MemoryCapture;
pub const TraceMark = tape.TraceMark;
pub const TraceSpan = tape.TraceSpan;
pub const TraceCursor = tape.TraceCursor;
pub const TraceOutcome = tape.TraceOutcome;
pub const TraceStepOutcome = tape.StepOutcome;
pub const TraceFrameKind = tape.FrameKind;
pub const TraceFrameOutcome = tape.FrameOutcome;
pub const TraceFrameFinish = tape.FrameFinish;
pub const TraceCapture = capture.TraceCapture;
pub const CallArena = call_arena.CallArena;
pub const CallRow = call_arena.Row;
pub const CallKind = call_arena.Kind;
pub const CallStatus = call_arena.Status;
pub const CallStart = call_arena.Start;
pub const CallFinish = call_arena.Finish;
pub const CallToken = call_arena.Token;
pub const CallSpan = call_arena.Span;

/// Runtime-erased consumer for one completed passive trace span.
///
/// Unlike the former event sink, this cannot observe or influence live opcode
/// execution. Consumers materialize exactly the fields they need through
/// `TraceCursor` before the caller resolves the borrowed span.
pub const TraceSpanTarget = struct {
    ptr: *anyopaque,
    consume_fn: *const fn (*anyopaque, TraceSpan) anyerror!void,

    pub fn init(
        ptr: *anyopaque,
        consume_fn: *const fn (*anyopaque, TraceSpan) anyerror!void,
    ) TraceSpanTarget {
        return .{ .ptr = ptr, .consume_fn = consume_fn };
    }

    pub fn consume(self: TraceSpanTarget, span: TraceSpan) !void {
        try self.consume_fn(self.ptr, span);
    }
};

const Address = address.Address;

/// Account access that survived the instruction's pre-state gas checks.
pub const AccountAccess = struct {
    depth: u16 = 0,
    address: Address,
};

pub const AccountExistsRead = struct {
    depth: u16 = 0,
    address: Address,
    exists: bool,
};

pub const AccountValueRead = struct {
    depth: u16 = 0,
    address: Address,
    value: u256,
};

pub const NonceRead = struct {
    depth: u16 = 0,
    address: Address,
    value: u64,
};

pub const CodeRead = struct {
    depth: u16 = 0,
    address: Address,
    size: usize,
};

pub const SlotValueRead = struct {
    depth: u16 = 0,
    address: Address,
    key: u256,
    value: u256,
};

pub const StateRead = union(enum) {
    account_exists: AccountExistsRead,
    account_has_storage: AccountExistsRead,
    balance: AccountValueRead,
    nonce: NonceRead,
    code: CodeRead,
    storage: SlotValueRead,
    transient_storage: SlotValueRead,

    pub fn withDepth(self: StateRead, event_depth: u16) StateRead {
        var result = self;
        switch (result) {
            inline else => |*payload| payload.depth = event_depth,
        }
        return result;
    }

    pub fn depth(self: StateRead) u16 {
        return switch (self) {
            inline else => |payload| payload.depth,
        };
    }

    pub fn kind(self: StateRead) StateReadKind {
        return std.meta.activeTag(self);
    }
};

pub const StateReadKind = std.meta.Tag(StateRead);

pub const AccountValueWrite = struct {
    depth: u16 = 0,
    address: Address,
    previous: u256,
    value: u256,
};

pub const NonceWrite = struct {
    depth: u16 = 0,
    address: Address,
    previous: u64,
    value: u64,
};

pub const CodeWrite = struct {
    depth: u16 = 0,
    address: Address,
    previous_hash: [32]u8,
    size: usize,
    code: []const u8 = &.{},
};

pub const SlotValueWrite = struct {
    depth: u16 = 0,
    address: Address,
    key: u256,
    previous: u256,
    value: u256,
};

pub const LogWrite = struct {
    depth: u16 = 0,
    address: Address,
    topics_len: usize,
    data_size: usize,
};

pub const AddressWrite = struct {
    depth: u16 = 0,
    address: Address,
};

pub const StorageAccessWrite = struct {
    depth: u16 = 0,
    address: Address,
    key: u256,
};

pub const StateWrite = union(enum) {
    balance: AccountValueWrite,
    nonce: NonceWrite,
    code: CodeWrite,
    storage: SlotValueWrite,
    transient_storage: SlotValueWrite,
    log: LogWrite,
    warm_account: AddressWrite,
    warm_storage: StorageAccessWrite,
    created_contract: AddressWrite,
    selfdestruct: AddressWrite,
    account_deleted: AddressWrite,

    pub fn withDepth(self: StateWrite, event_depth: u16) StateWrite {
        var result = self;
        switch (result) {
            inline else => |*payload| payload.depth = event_depth,
        }
        return result;
    }

    pub fn depth(self: StateWrite) u16 {
        return switch (self) {
            inline else => |payload| payload.depth,
        };
    }

    pub fn kind(self: StateWrite) StateWriteKind {
        return std.meta.activeTag(self);
    }
};

pub const StateWriteKind = std.meta.Tag(StateWrite);

pub const Checkpoint = struct {
    kind: CheckpointKind,
    depth: u16 = 0,
    journal_len: usize,
    logs_len: usize,
};

pub const CheckpointKind = enum(u8) {
    checkpoint,
    commit,
    revert,
};
