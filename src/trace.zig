//! Typed execution trace hooks.
//!
//! Trace integration is schema-first. A runtime `Sink` declares the event shape
//! it observes in `Sink.events`; callbacks are consumers, not the source of
//! truth. The VM derives work from the schema so state-only sinks do not force
//! opcode tracing, and step sinks can request only the fields they need.
//!
//! This runtime sink is the flexible integration path for debuggers, tests,
//! CLIs, and embedders. A future comptime-configured VM can reuse the
//! same event vocabulary with a comptime schema for hotter EIP-3155/prover
//! adapters.
//!
//! Step events borrow stack and frame data. Sinks must copy anything they need
//! after the callback returns.

const std = @import("std");
const address = @import("./address.zig");

const Address = address.Address;
const Opcode = @import("./opcode.zig").Opcode;

pub const StepStatus = enum(u8) {
    running,
    success,
    invalid,
    revert,
    out_of_gas,
};

/// Pre-opcode step event.
///
/// Runtime sinks receive meaningful values only for fields declared in
/// `Sink.events.step_start`; omitted fields are zero, null, or empty slices.
pub const StepStart = struct {
    pc: usize,
    opcode: u8,
    decoded_opcode: ?Opcode,
    depth: u16,
    gas_left: i64,
    stack: []const u256,
    memory_size: usize,
    return_data_size: usize,
};

/// Post-opcode step event.
///
/// Runtime sinks receive meaningful values only for fields declared in
/// `Sink.events.step_end`; omitted fields are zero, null, or empty slices.
pub const StepEnd = struct {
    pc: usize,
    pc_next: usize,
    opcode: u8,
    decoded_opcode: ?Opcode,
    depth: u16,
    status: StepStatus,
    gas_left: i64,
    gas_cost: i64,
    stack: []const u256,
    memory_size: usize,
    return_data_size: usize,
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
    size: usize,
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

/// Field-level schema for `StepStart`.
pub const StepStartField = enum(u4) {
    pc,
    opcode,
    decoded_opcode,
    depth,
    gas_left,
    stack,
    memory_size,
    return_data_size,
};

pub const StepStartFields = std.enums.EnumSet(StepStartField);

/// Field-level schema for `StepEnd`.
pub const StepEndField = enum(u4) {
    pc,
    pc_next,
    opcode,
    decoded_opcode,
    depth,
    status,
    gas_left,
    gas_cost,
    stack,
    memory_size,
    return_data_size,
};

pub const StepEndFields = std.enums.EnumSet(StepEndField);

/// Kind-level schema for `StateRead`.
///
/// State read schemas currently select whole union variants. For example,
/// `.initMany(&.{ .storage })` enables storage read events with address, key,
/// value, and depth populated.
pub const StateReadKinds = std.enums.EnumSet(StateReadKind);

/// Kind-level schema for `StateWrite`.
///
/// State write schemas currently select whole union variants. For example,
/// `.initMany(&.{ .storage })` enables storage write events with address, key,
/// previous, value, and depth populated.
pub const StateWriteKinds = std.enums.EnumSet(StateWriteKind);

/// Field-level schema for checkpoint lifecycle events.
pub const CheckpointField = enum(u3) {
    kind,
    depth,
    journal_len,
    logs_len,
};

pub const CheckpointFields = std.enums.EnumSet(CheckpointField);

/// Runtime trace schema.
///
/// This is the public declaration of observed trace shape. Producer code checks
/// these fields before doing expensive work; `Sink` dispatch methods also check
/// them so direct calls cannot bypass the schema.
pub const Events = struct {
    step_start: StepStartFields = .{},
    step_end: StepEndFields = .{},
    state_read: StateReadKinds = .{},
    state_write: StateWriteKinds = .{},
    checkpoint: CheckpointFields = .{},

    pub fn all() Events {
        return .{
            .step_start = StepStartFields.full,
            .step_end = StepEndFields.full,
            .state_read = StateReadKinds.full,
            .state_write = StateWriteKinds.full,
            .checkpoint = CheckpointFields.full,
        };
    }

    pub fn wantsStepStart(self: Events) bool {
        return !self.step_start.eql(.empty);
    }

    pub fn wantsStepEnd(self: Events) bool {
        return !self.step_end.eql(.empty);
    }

    pub fn wantsSteps(self: Events) bool {
        return self.wantsStepStart() or self.wantsStepEnd();
    }

    pub fn wantsDecodedOpcode(self: Events) bool {
        return self.step_start.contains(.decoded_opcode) or self.step_end.contains(.decoded_opcode);
    }

    pub fn wantsStateRead(self: Events, event: StateReadKind) bool {
        return self.state_read.contains(event);
    }

    pub fn wantsStateWrite(self: Events, event: StateWriteKind) bool {
        return self.state_write.contains(event);
    }

    pub fn wantsCheckpoint(self: Events) bool {
        return !self.checkpoint.eql(.empty);
    }
};

/// Runtime trace sink.
///
/// A sink combines an opaque pointer, an observed event schema, and optional
/// callbacks. The schema is authoritative: a callback is invoked only when the
/// matching event or field is declared.
///
/// Minimal state-write recorder shape:
///
/// ```zig
/// var sink = trace.Sink.init(&recorder, .{
///     .state_write = trace.StateWriteKinds.initMany(&.{ .storage }),
/// }, &.{
///     .stateWrite = Recorder.stateWrite,
/// });
/// ```
///
/// Step callbacks receive borrowed stack slices. Copy any data that must live
/// beyond the callback.
pub const Sink = struct {
    ptr: *anyopaque,
    events: Events = .{},
    vtable: *const VTable,
    cached_flags: Flags = .{},

    pub const VTable = struct {
        stepStart: ?*const fn (ptr: *anyopaque, event: StepStart) void = null,
        stepEnd: ?*const fn (ptr: *anyopaque, event: StepEnd) void = null,
        stateRead: ?*const fn (ptr: *anyopaque, event: StateRead) void = null,
        stateWrite: ?*const fn (ptr: *anyopaque, event: StateWrite) void = null,
        checkpoint: ?*const fn (ptr: *anyopaque, event: Checkpoint) void = null,
    };

    pub const Flags = struct {
        configured: bool = false,
        wants_step_start: bool = false,
        wants_step_end: bool = false,
        wants_decoded_opcode: bool = false,
        wants_state_read: bool = false,
        wants_state_write: bool = false,
        wants_checkpoint: bool = false,

        fn from(events: Events, vtable: *const VTable) Flags {
            const wants_step_start = events.wantsStepStart() and vtable.stepStart != null;
            const wants_step_end = events.wantsStepEnd() and vtable.stepEnd != null;
            return .{
                .configured = true,
                .wants_step_start = wants_step_start,
                .wants_step_end = wants_step_end,
                .wants_decoded_opcode = (wants_step_start and events.step_start.contains(.decoded_opcode)) or
                    (wants_step_end and events.step_end.contains(.decoded_opcode)),
                .wants_state_read = !events.state_read.eql(.empty) and vtable.stateRead != null,
                .wants_state_write = !events.state_write.eql(.empty) and vtable.stateWrite != null,
                .wants_checkpoint = events.wantsCheckpoint() and vtable.checkpoint != null,
            };
        }
    };

    pub fn init(ptr: *anyopaque, events: Events, vtable: *const VTable) Sink {
        return .{
            .ptr = ptr,
            .events = events,
            .vtable = vtable,
            .cached_flags = Flags.from(events, vtable),
        };
    }

    pub fn refresh(self: *Sink) void {
        self.cached_flags = Flags.from(self.events, self.vtable);
    }

    pub fn flags(self: *const Sink) Flags {
        if (self.cached_flags.configured) return self.cached_flags;
        return Flags.from(self.events, self.vtable);
    }

    pub fn stepStart(self: *Sink, event: StepStart) void {
        if (!self.flags().wants_step_start) return;
        self.vtable.stepStart.?(self.ptr, event);
    }

    pub fn stepEnd(self: *Sink, event: StepEnd) void {
        if (!self.flags().wants_step_end) return;
        self.vtable.stepEnd.?(self.ptr, event);
    }

    pub fn stateRead(self: *Sink, event: StateRead) void {
        if (!self.wantsStateReadKind(event.kind())) return;
        self.vtable.stateRead.?(self.ptr, event);
    }

    pub fn stateWrite(self: *Sink, event: StateWrite) void {
        if (!self.wantsStateWriteKind(event.kind())) return;
        self.vtable.stateWrite.?(self.ptr, event);
    }

    pub fn checkpoint(self: *Sink, event: Checkpoint) void {
        if (!self.flags().wants_checkpoint) return;
        self.vtable.checkpoint.?(self.ptr, event);
    }

    pub fn wantsStepStart(self: *const Sink) bool {
        return self.flags().wants_step_start;
    }

    pub fn wantsStepEnd(self: *const Sink) bool {
        return self.flags().wants_step_end;
    }

    pub fn wantsSteps(self: *const Sink) bool {
        const sink_flags = self.flags();
        return sink_flags.wants_step_start or sink_flags.wants_step_end;
    }

    pub fn wantsDecodedOpcode(self: *const Sink) bool {
        return self.flags().wants_decoded_opcode;
    }

    pub fn wantsStateReadKind(self: *const Sink, event: StateReadKind) bool {
        return self.flags().wants_state_read and self.events.wantsStateRead(event);
    }

    pub fn wantsStateWriteKind(self: *const Sink, event: StateWriteKind) bool {
        return self.flags().wants_state_write and self.events.wantsStateWrite(event);
    }

    pub fn wantsCheckpoint(self: *const Sink) bool {
        return self.flags().wants_checkpoint;
    }
};

pub const NullSink = struct {
    pub fn sink(self: *NullSink) Sink {
        return Sink.init(self, .{}, &.{});
    }
};

test "null sink accepts borrowed step events" {
    var null_sink = NullSink{};
    var sink_iface = null_sink.sink();

    sink_iface.stepStart(.{
        .pc = 0,
        .opcode = @intFromEnum(Opcode.STOP),
        .decoded_opcode = .STOP,
        .depth = 0,
        .gas_left = 0,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    });
    sink_iface.stepEnd(.{
        .pc = 0,
        .pc_next = 1,
        .opcode = @intFromEnum(Opcode.STOP),
        .decoded_opcode = .STOP,
        .depth = 0,
        .status = .success,
        .gas_left = 0,
        .gas_cost = 0,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    });
    sink_iface.stateRead(.{
        .balance = .{
            .address = address.addr(1),
            .value = 1,
        },
    });
    sink_iface.stateWrite(.{
        .storage = .{
            .address = address.addr(1),
            .key = 2,
            .previous = 0,
            .value = 3,
        },
    });
    sink_iface.checkpoint(.{
        .kind = .checkpoint,
        .journal_len = 1,
        .logs_len = 0,
    });

    try std.testing.expect(true);
}

test "sink callbacks require declared events" {
    var recorder = SinkDispatchRecorder{};
    var sink_iface = recorder.sinkWithoutEvents();

    sink_iface.stepStart(emptyStepStart());
    sink_iface.stepEnd(emptyStepEnd());
    sink_iface.stateWrite(storageWrite(1));
    sink_iface.checkpoint(.{
        .kind = .checkpoint,
        .journal_len = 0,
        .logs_len = 0,
    });

    try std.testing.expectEqual(@as(u8, 0), recorder.step_starts);
    try std.testing.expectEqual(@as(u8, 0), recorder.step_ends);
    try std.testing.expectEqual(@as(u8, 0), recorder.state_writes);
    try std.testing.expectEqual(@as(u8, 0), recorder.checkpoints);
}

test "sink declared events require callbacks" {
    var recorder = SinkDispatchRecorder{};
    var sink_iface = recorder.sinkWithoutCallbacks();

    try std.testing.expect(!sink_iface.wantsStepStart());
    try std.testing.expect(!sink_iface.wantsStateWriteKind(.storage));
    try std.testing.expect(!sink_iface.wantsCheckpoint());

    sink_iface.stepStart(emptyStepStart());
    sink_iface.stateWrite(storageWrite(1));
    sink_iface.checkpoint(.{
        .kind = .checkpoint,
        .journal_len = 0,
        .logs_len = 0,
    });

    try std.testing.expectEqual(@as(u8, 0), recorder.step_starts);
    try std.testing.expectEqual(@as(u8, 0), recorder.state_writes);
    try std.testing.expectEqual(@as(u8, 0), recorder.checkpoints);
}

test "sink state write schema filters kinds" {
    var recorder = SinkDispatchRecorder{};
    var sink_iface = recorder.storageWriteSink();

    sink_iface.stateWrite(.{
        .balance = .{
            .address = @import("./address.zig").addr(1),
            .previous = 0,
            .value = 10,
        },
    });
    sink_iface.stateWrite(storageWrite(2));

    try std.testing.expectEqual(@as(u8, 1), recorder.state_writes);
    try std.testing.expectEqual(StateWriteKind.storage, recorder.last_state_write);
    try std.testing.expectEqual(@as(u256, 2), recorder.last_storage_value);
}

fn emptyStepStart() StepStart {
    return .{
        .pc = 0,
        .opcode = @intFromEnum(Opcode.STOP),
        .decoded_opcode = .STOP,
        .depth = 0,
        .gas_left = 0,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    };
}

fn emptyStepEnd() StepEnd {
    return .{
        .pc = 0,
        .pc_next = 1,
        .opcode = @intFromEnum(Opcode.STOP),
        .decoded_opcode = .STOP,
        .depth = 0,
        .status = .success,
        .gas_left = 0,
        .gas_cost = 0,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    };
}

fn storageWrite(value: u256) StateWrite {
    return .{
        .storage = .{
            .address = address.addr(1),
            .key = 2,
            .previous = 0,
            .value = value,
        },
    };
}

const SinkDispatchRecorder = struct {
    step_starts: u8 = 0,
    step_ends: u8 = 0,
    state_writes: u8 = 0,
    checkpoints: u8 = 0,
    last_state_write: StateWriteKind = .balance,
    last_storage_value: u256 = 0,

    fn sinkWithoutEvents(self: *SinkDispatchRecorder) Sink {
        return Sink.init(self, .{}, &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
            .stateWrite = stateWrite,
            .checkpoint = checkpointEvent,
        });
    }

    fn sinkWithoutCallbacks(self: *SinkDispatchRecorder) Sink {
        return Sink.init(self, .{
            .step_start = StepStartFields.initMany(&.{.pc}),
            .state_write = StateWriteKinds.initMany(&.{.storage}),
            .checkpoint = CheckpointFields.initMany(&.{.kind}),
        }, &.{});
    }

    fn storageWriteSink(self: *SinkDispatchRecorder) Sink {
        return Sink.init(self, .{
            .state_write = StateWriteKinds.initMany(&.{.storage}),
        }, &.{
            .stateWrite = stateWrite,
        });
    }

    fn stepStart(ptr: *anyopaque, event: StepStart) void {
        const self: *SinkDispatchRecorder = @ptrCast(@alignCast(ptr));
        _ = event;
        self.step_starts += 1;
    }

    fn stepEnd(ptr: *anyopaque, event: StepEnd) void {
        const self: *SinkDispatchRecorder = @ptrCast(@alignCast(ptr));
        _ = event;
        self.step_ends += 1;
    }

    fn stateWrite(ptr: *anyopaque, event: StateWrite) void {
        const self: *SinkDispatchRecorder = @ptrCast(@alignCast(ptr));
        self.last_state_write = event.kind();
        self.last_storage_value = switch (event) {
            .storage => |payload| payload.value,
            else => 0,
        };
        self.state_writes += 1;
    }

    fn checkpointEvent(ptr: *anyopaque, event: Checkpoint) void {
        const self: *SinkDispatchRecorder = @ptrCast(@alignCast(ptr));
        _ = event;
        self.checkpoints += 1;
    }
};
