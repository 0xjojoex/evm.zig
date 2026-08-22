//! Authoritative LIFO storage for the iterative call runtime. Only the newest
//! row executes while older rows are synchronously suspended. Control metadata
//! and interpreter storage share one push/pop lifetime.
const std = @import("std");

const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");
const Memory = @import("../Memory.zig");
const frame_io = @import("../frame_io.zig");
const Stack = @import("../Stack.zig");
const evmz = @import("../evm.zig");
const Checkpoint = @import("../state/checkpoint.zig").Checkpoint;
const CallToken = @import("../trace/call_arena.zig").Token;

const FrameStore = @This();

pub const CreateControl = struct {
    checkpoint_state: Checkpoint,
    address: evmz.Address,
    kind: Host.CallKind,
};

pub const Kind = union(enum) {
    root_call,
    call: Checkpoint,
    create: CreateControl,
};

pub const Control = struct {
    kind: Kind,
    call_capture: ?CallToken = null,
};

frames: std.ArrayList(Interpreter.CallFrame) = .empty,
controls: std.ArrayList(Control) = .empty,
messages: std.ArrayList(Host.Message) = .empty,
stack_words: std.ArrayList(u256) = .empty,
memories: std.ArrayList(Memory.Storage) = .empty,
ios: std.ArrayList(frame_io.Slot) = .empty,
max_rows: usize = 0,
max_stack_base: usize = 0,
max_stack_words: usize = 0,
/// Reserve pointer-bearing metadata before the first acquisition. Memory and
/// I/O rows remain lazy; packed stack words grow independently.
stable_metadata_capacity: ?usize = null,

const no_growth_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = std.mem.Allocator.noAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    },
};

pub fn deinit(self: *FrameStore, allocator: std.mem.Allocator) void {
    while (self.frames.items.len != 0) {
        self.pop();
    }
    for (self.memories.items) |*storage| {
        storage.deinit(allocator);
    }
    self.frames.deinit(allocator);
    self.controls.deinit(allocator);
    self.messages.deinit(allocator);
    self.stack_words.deinit(allocator);
    self.memories.deinit(allocator);
    for (self.ios.items) |*slot| {
        slot.deinit();
    }
    self.ios.deinit(allocator);
    self.* = .{};
}

pub fn push(
    self: *FrameStore,
    allocator: std.mem.Allocator,
    options: Interpreter.Init,
    control_value: Control,
) !usize {
    const index = try self.appendRow(allocator);
    errdefer self.popUninitialized();
    self.controls.appendAssumeCapacity(control_value);

    const stack_base = self.nextStackBase();
    try self.ensureStackRange(allocator, stack_base);
    errdefer self.restoreStackRange(index);

    self.frames.items[index].initRetainingMemoryCapacity(
        allocator,
        options,
        &self.messages.items[index],
        Stack.init(self.stack_words.items, @intCast(stack_base)),
        &self.memories.items[index],
        &self.ios.items[index],
    );

    return index;
}

pub fn len(self: *const FrameStore) usize {
    std.debug.assert(self.frames.items.len == self.controls.items.len);
    std.debug.assert(self.frames.items.len == self.messages.items.len);
    return self.frames.items.len;
}

pub fn frame(self: *FrameStore, index: usize) *Interpreter.CallFrame {
    std.debug.assert(index < self.frames.items.len);
    return &self.frames.items[index];
}

pub fn control(self: *const FrameStore, index: usize) *const Control {
    std.debug.assert(index < self.controls.items.len);
    return &self.controls.items[index];
}

pub fn pop(self: *FrameStore) void {
    const row_count = self.len();
    std.debug.assert(row_count != 0);
    const index = row_count - 1;

    self.frames.items[index].deinitRetainingMemoryCapacity();
    self.frames.items.len = index;
    self.controls.items.len = index;
    self.messages.items.len = index;
    self.restoreStackRange(index);
}

pub fn maxRowCount(self: *const FrameStore) usize {
    return self.max_rows;
}

pub fn metadataPointersStable(self: *const FrameStore) bool {
    const capacity = self.stable_metadata_capacity orelse return false;
    return self.frames.capacity >= capacity and
        self.messages.capacity >= capacity and
        self.memories.capacity >= capacity and
        self.ios.capacity >= capacity;
}

/// Addressable words for the active LIFO frame set, including the active
/// frame's 1,024-word execution headroom.
pub fn activeStackWordCount(self: *const FrameStore) usize {
    return self.stack_words.items.len;
}

pub fn stackWordCapacity(self: *const FrameStore) usize {
    return self.stack_words.capacity;
}

/// Peak count of suspended live words below a pushed active frame.
pub fn maxStackBase(self: *const FrameStore) usize {
    return self.max_stack_base;
}

/// Peak addressable arena window, including active-frame headroom.
pub fn maxStackWordCount(self: *const FrameStore) usize {
    return self.max_stack_words;
}

fn appendRow(self: *FrameStore, allocator: std.mem.Allocator) !usize {
    const index = self.len();
    try self.ensureUnusedCapacity(allocator, 1);

    try self.ensureConstructedRow(allocator, index);
    self.frames.appendAssumeCapacity(undefined);
    self.messages.appendAssumeCapacity(undefined);
    std.debug.assert(index < self.memories.items.len);
    std.debug.assert(index < self.ios.items.len);
    self.max_rows = @max(self.max_rows, self.frames.items.len);
    return index;
}

fn ensureUnusedCapacity(
    self: *FrameStore,
    allocator: std.mem.Allocator,
    additional: usize,
) !void {
    if (self.stable_metadata_capacity) |limit| {
        std.debug.assert(self.frames.items.len + additional <= limit);
        try self.reserveStableMetadataCapacity(allocator);
        try self.controls.ensureUnusedCapacity(allocator, additional);
        std.debug.assert(self.hasUnusedCapacity(additional));
        return;
    }

    const before = self.capacities();
    var done = false;
    defer if (!done and self.capacitiesChanged(before)) self.rebindActiveFrames();

    try self.frames.ensureUnusedCapacity(allocator, additional);
    try self.controls.ensureTotalCapacity(allocator, self.frames.capacity);
    try self.messages.ensureTotalCapacity(allocator, self.frames.capacity);
    try self.memories.ensureTotalCapacity(allocator, self.frames.capacity);
    try self.ios.ensureTotalCapacity(allocator, self.frames.capacity);

    done = true;
    if (self.capacitiesChanged(before)) {
        self.rebindActiveFrames();
    }
}

fn reserveStableMetadataCapacity(self: *FrameStore, allocator: std.mem.Allocator) !void {
    const capacity = self.stable_metadata_capacity orelse return;
    if (self.frames.capacity >= capacity and
        self.messages.capacity >= capacity and
        self.memories.capacity >= capacity and
        self.ios.capacity >= capacity) return;

    std.debug.assert(self.frames.items.len == 0);
    try self.frames.ensureTotalCapacityPrecise(allocator, capacity);
    try self.messages.ensureTotalCapacityPrecise(allocator, capacity);
    try self.memories.ensureTotalCapacityPrecise(allocator, capacity);
    try self.ios.ensureTotalCapacityPrecise(allocator, capacity);
}

fn hasUnusedCapacity(self: *const FrameStore, additional: usize) bool {
    return self.frames.capacity - self.frames.items.len >= additional and
        self.controls.capacity - self.controls.items.len >= additional and
        self.messages.capacity - self.messages.items.len >= additional and
        self.memories.capacity >= self.frames.items.len + additional and
        self.ios.capacity >= self.frames.items.len + additional;
}

/// Construct sidecar rows only when execution first reaches a new depth.
/// Released rows stay initialized for later siblings at the same depth.
fn ensureConstructedRow(self: *FrameStore, allocator: std.mem.Allocator, index: usize) !void {
    std.debug.assert(self.memories.items.len == self.ios.items.len);
    if (index < self.memories.items.len) return;
    std.debug.assert(index == self.memories.items.len);
    std.debug.assert(index < self.memories.capacity);
    std.debug.assert(index < self.ios.capacity);

    self.memories.appendAssumeCapacity(.empty);
    self.ios.appendAssumeCapacity(undefined);
    self.ios.items[index].init(allocator);
}

fn popUninitialized(self: *FrameStore) void {
    std.debug.assert(self.frames.items.len != 0);
    const index = self.frames.items.len - 1;
    self.frames.items.len = index;
    self.controls.items.len = index;
    self.messages.items.len = index;
    self.restoreStackRange(index);
}

fn rebindActiveFrames(self: *FrameStore) void {
    for (0..self.frames.items.len) |index| {
        self.frames.items[index].msg = &self.messages.items[index];
        self.frames.items[index].memory.rebindStorage(&self.memories.items[index]);
        self.frames.items[index].rebindIo(&self.ios.items[index]);
    }
}

fn nextStackBase(self: *const FrameStore) usize {
    if (self.frames.items.len <= 1) return 0;
    const parent = self.frames.items[self.frames.items.len - 2].stack;
    return @as(usize, parent.base_word) + @as(usize, parent.len);
}

fn ensureStackRange(self: *FrameStore, allocator: std.mem.Allocator, base: usize) !void {
    const required = try std.math.add(usize, base, Stack.capacity);
    std.debug.assert(required <= std.math.maxInt(u32));

    const old_ptr = self.stack_words.items.ptr;
    try self.stack_words.ensureTotalCapacity(allocator, required);
    if (self.stack_words.items.ptr != old_ptr) self.rebindSuspendedStackPointers();
    if (self.stack_words.items.len < required) {
        self.stack_words.items.len = required;
    }
    self.max_stack_base = @max(self.max_stack_base, base);
    self.max_stack_words = @max(self.max_stack_words, required);
}

fn restoreStackRange(self: *FrameStore, remaining_frames: usize) void {
    const required = if (remaining_frames == 0)
        0
    else blk: {
        const stack = self.frames.items[remaining_frames - 1].stack;
        break :blk @as(usize, stack.base_word) + Stack.capacity;
    };
    std.debug.assert(required <= self.stack_words.items.len);
    self.stack_words.items.len = required;
}

fn rebindSuspendedStackPointers(self: *FrameStore) void {
    std.debug.assert(self.frames.items.len != 0);
    // appendRow already exposed the new, still-uninitialized tail row.
    for (self.frames.items[0 .. self.frames.items.len - 1]) |*frame_value| {
        frame_value.stack.rebind(self.stack_words.items);
    }
}

const Capacities = struct {
    frames: usize,
    controls: usize,
    messages: usize,
    stack_words: usize,
    memories: usize,
    ios: usize,
};

fn capacities(self: *const FrameStore) Capacities {
    return .{
        .frames = self.frames.capacity,
        .controls = self.controls.capacity,
        .messages = self.messages.capacity,
        .stack_words = self.stack_words.capacity,
        .memories = self.memories.capacity,
        .ios = self.ios.capacity,
    };
}

fn capacitiesChanged(self: *const FrameStore, before: Capacities) bool {
    const after = self.capacities();
    return after.frames != before.frames or
        after.controls != before.controls or
        after.messages != before.messages or
        after.stack_words != before.stack_words or
        after.memories != before.memories or
        after.ios != before.ios;
}

const test_execution_context = evmz.execution.ExecutionContext{
    .chain = .{ .chain_id = 1 },
    .transaction = .{ .origin = evmz.addr(0) },
};

fn pushTestFrame(
    store: *FrameStore,
    allocator: std.mem.Allocator,
    host: *Host,
    msg: *const Host.Message,
) !usize {
    return store.push(allocator, .{
        .host = host,
        .msg = msg,
        .execution_context = &test_execution_context,
        .bytecode = evmz.Bytecode.View.empty,
    }, .{ .kind = .root_call });
}

test "frame store rebinds active rows after growth" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.frames.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.controls.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.messages.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.stack_words.ensureTotalCapacityPrecise(std.testing.allocator, Stack.capacity);
    try store.memories.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.ios.ensureTotalCapacityPrecise(std.testing.allocator, 1);

    var host: Host = undefined;
    var first_msg = evmz.t.defaultMessage();
    first_msg.gas = 100;
    const first = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &first_msg,
    );
    store.frame(first).stack.push(11);
    store.frame(first).stack.push(22);
    store.frame(first).stack.push(33);
    try store.frame(first).memory.expandToFit(0, 32);
    store.frame(first).memory.writeBytes(0, "abc");
    store.frame(first).state = .running;
    const continuation: Interpreter.Action.CallResume = .{
        .gas_limit = 10,
        .out_offset = 4,
        .out_size = 8,
    };
    store.frame(first).suspendWith(.{ .call = .{
        .msg = first_msg,
        .continuation = continuation,
    } });

    var second_msg = evmz.t.defaultMessage();
    second_msg.depth = 1;
    second_msg.gas = 100;
    const second = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &second_msg,
    );
    store.frame(second).stack.push(44);

    try std.testing.expect(store.frame(first).msg == &store.messages.items[first]);
    try std.testing.expect(store.frame(first).suspendedAction().? == &store.ios.items[first].action);
    const rebound_action = store.frame(first).suspendedAction() orelse return error.ExpectedAction;
    const rebound_call = switch (rebound_action.*) {
        .call => |value| value,
        .create => return error.ExpectedCallAction,
    };
    try std.testing.expectEqual(continuation, rebound_call.continuation);
    try std.testing.expectEqual(first_msg.depth, rebound_call.msg.depth);
    try std.testing.expectEqual(@as(u32, 0), store.frame(first).stack.base_word);
    try std.testing.expectEqual(@as(u32, 3), store.frame(second).stack.base_word);
    try std.testing.expectEqual(@intFromPtr(&store.stack_words.items[0]), @intFromPtr(store.frame(first).stack.base));
    try std.testing.expectEqual(@intFromPtr(&store.stack_words.items[3]), @intFromPtr(store.frame(second).stack.base));
    try std.testing.expectEqualSlices(u256, &.{ 11, 22, 33 }, store.frame(first).stack.asSlice());
    try std.testing.expectEqualSlices(u256, &.{44}, store.frame(second).stack.asSlice());
    try std.testing.expect(store.frame(first).memory.bytes == &store.memories.items[first]);
    try std.testing.expectEqualSlices(u8, "abc", store.frame(first).memory.readBytes(0, 3));
    try std.testing.expect(store.frame(first).io == &store.ios.items[first]);
    try std.testing.expectEqual(@as(u16, 0), store.frame(first).msg.depth);
    try std.testing.expectEqual(@as(u16, 1), store.frame(second).msg.depth);

    const sibling_base = store.frame(second).stack.base_word;
    store.pop();
    const sibling = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &second_msg,
    );
    try std.testing.expectEqual(sibling_base, store.frame(sibling).stack.base_word);
    try std.testing.expectEqual(@as(u16, 0), store.frame(sibling).stack.len);
}

test "frame store reuses cleared memory capacity for sibling calls" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    var root_msg = evmz.t.defaultMessage();
    root_msg.gas = 100;
    _ = try pushTestFrame(&store, std.testing.allocator, &host, &root_msg);

    var child_msg = root_msg;
    child_msg.depth = 1;
    const child = try pushTestFrame(&store, std.testing.allocator, &host, &child_msg);
    try store.frame(child).memory.expandToFit(0, 4096);
    store.frame(child).memory.writeBytes(0, "dirty");

    const retained_capacity = store.frame(child).memory.bytes.capacity;
    store.pop();
    try std.testing.expectEqual(@as(usize, 0), store.memories.items[child].items.len);
    try std.testing.expectEqual(retained_capacity, store.memories.items[child].capacity);

    const sibling = try pushTestFrame(&store, no_growth_allocator, &host, &child_msg);
    try store.frame(sibling).memory.expandToFit(0, 4096);
    try std.testing.expect(std.mem.allEqual(
        u8,
        store.frame(sibling).memory.readBytes(0, 4096),
        0,
    ));
}

test "stack arena growth failure leaves the parent row usable" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    var root_msg = evmz.t.defaultMessage();
    root_msg.gas = 100;
    const root = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &root_msg,
    );
    for (0..600) |word| store.frame(root).stack.push(@intCast(word));
    try store.ensureConstructedRow(std.testing.allocator, 1);

    var child_msg = root_msg;
    child_msg.depth = 1;
    try std.testing.expectError(
        error.OutOfMemory,
        pushTestFrame(
            &store,
            no_growth_allocator,
            &host,
            &child_msg,
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expectEqual(@as(usize, Stack.capacity), store.activeStackWordCount());
    try std.testing.expectEqual(@as(u16, 600), store.frame(root).stack.len);
    try std.testing.expectEqual(@as(u256, 0), store.frame(root).stack.asSlice()[0]);
    try std.testing.expectEqual(@as(u256, 599), store.frame(root).stack.asSlice()[599]);
}

test "stable metadata capacity prevents active frame relocation" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.ios.items.len);

    var host: Host = undefined;
    var root_msg = evmz.t.defaultMessage();
    root_msg.gas = 100;
    const root = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &root_msg,
    );
    const root_ptr = store.frame(root);
    try std.testing.expect(store.metadataPointersStable());
    try std.testing.expectEqual(@as(usize, 2), store.frames.capacity);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.ios.items.len);

    var child_msg = root_msg;
    child_msg.depth = 1;
    _ = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &child_msg,
    );
    try std.testing.expect(store.frame(root) == root_ptr);
    try std.testing.expectEqual(@as(usize, 2), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.ios.items.len);

    store.pop();
    _ = try pushTestFrame(
        &store,
        no_growth_allocator,
        &host,
        &child_msg,
    );
    try std.testing.expect(store.frame(root) == root_ptr);
    try std.testing.expectEqual(@as(usize, 2), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.ios.items.len);
}

test "packed stack arena advances by suspended live words" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    var root_msg = evmz.t.defaultMessage();
    root_msg.gas = 100;
    const root = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &root_msg,
    );
    for (0..1000) |word| store.frame(root).stack.push(@intCast(word));

    var child_msg = root_msg;
    child_msg.depth = 1;
    const child = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &child_msg,
    );

    try std.testing.expectEqual(@as(u32, 1000), store.frame(child).stack.base_word);
    try std.testing.expectEqual(@as(usize, 1000), store.maxStackBase());
    try std.testing.expectEqual(@as(usize, 1000 + Stack.capacity), store.activeStackWordCount());
    try std.testing.expectEqual(@as(u256, 0), store.frame(root).stack.asSlice()[0]);
    try std.testing.expectEqual(@as(u256, 500), store.frame(root).stack.asSlice()[500]);
    try std.testing.expectEqual(@as(u256, 999), store.frame(root).stack.asSlice()[999]);
}

test "frame store owns parent returndata and resolves output from frame memory" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    const index = try pushTestFrame(
        &store,
        std.testing.allocator,
        &host,
        &msg,
    );
    const frame_value = store.frame(index);

    try frame_value.replaceReturnData("abc");
    try std.testing.expectEqualSlices(u8, "abc", frame_value.return_data);
    try std.testing.expect(frame_value.return_data.ptr == store.ios.items[index].return_data.buf.ptr);
    try frame_value.replaceReturnData("abcd");
    try std.testing.expectEqualSlices(u8, "abcd", frame_value.return_data);

    try frame_value.memory.expandToFit(0, 32);
    frame_value.memory.writeBytes(0, "xyz");
    frame_value.setOutputRange(0, 3);
    try std.testing.expectEqualSlices(u8, "xyz", frame_value.result().output_data);

    try frame_value.memory.expandToFit(4096, 1);
    try std.testing.expectEqualSlices(u8, "xyz", frame_value.result().output_data);

    store.pop();
    try std.testing.expectEqual(@as(usize, 0), store.ios.items[0].return_data.slice().len);
}
