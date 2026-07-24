//! Internal LIFO storage for CallRuntime. Active leases are stack-ordered:
//! only the newest frame executes while older frames are synchronously
//! suspended. Packed stack ranges rely on that scheduler invariant.
const std = @import("std");

const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");
const ExactSpec = @import("../spec.zig").Spec;
const Memory = @import("../Memory.zig");
const frame_io = @import("../frame_io.zig");
const Stack = @import("../Stack.zig");
const evmz = @import("../evm.zig");
const Address = @import("../address.zig").Address;

const FrameStore = @This();

pub const row_bytes =
    @sizeOf(Interpreter.CallFrame) +
    @sizeOf(Host.Message) +
    @sizeOf(Stack.Storage) +
    @sizeOf(Memory.Storage) +
    @sizeOf(frame_io.Slot);

frames: std.ArrayList(Interpreter.CallFrame) = .empty,
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

pub const Lease = struct {
    store: *FrameStore,
    index: usize,

    pub fn deinit(self: *Lease) void {
        self.store.release(self.index);
        self.* = undefined;
    }

    pub fn callFrame(self: *const Lease) *Interpreter.CallFrame {
        return self.store.frame(self.index);
    }

    pub fn interpreter(self: *const Lease, comptime spec: ExactSpec) Interpreter.Interpreter(spec) {
        return Interpreter.Interpreter(spec).init(self.callFrame());
    }
};

pub fn deinit(self: *FrameStore, allocator: std.mem.Allocator) void {
    while (self.frames.items.len != 0) {
        self.release(self.frames.items.len - 1);
    }
    for (self.memories.items) |*storage| {
        storage.deinit(allocator);
    }
    self.frames.deinit(allocator);
    self.messages.deinit(allocator);
    self.stack_words.deinit(allocator);
    self.memories.deinit(allocator);
    for (self.ios.items) |*slot| {
        slot.deinit();
    }
    self.ios.deinit(allocator);
    self.* = .{};
}

pub fn acquire(
    self: *FrameStore,
    store_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    options: Interpreter.Init,
) !Lease {
    const index = try self.appendRow(store_allocator);
    errdefer self.popUninitialized();

    var frame_options = options;
    frame_options.io = &self.ios.items[index];
    const stack_base = self.nextStackBase();
    try self.ensureStackRange(store_allocator, stack_base);
    errdefer self.restoreStackRange(index);

    try self.frames.items[index].init(
        frame_allocator,
        frame_options,
        &self.messages.items[index],
        Stack.init(self.stack_words.items, @intCast(stack_base)),
        &self.memories.items[index],
    );

    return .{
        .store = self,
        .index = index,
    };
}

pub fn frame(self: *FrameStore, index: usize) *Interpreter.CallFrame {
    std.debug.assert(index < self.frames.items.len);
    return &self.frames.items[index];
}

pub fn activeRowCount(self: *const FrameStore) usize {
    return self.frames.items.len;
}

pub fn maxRowCount(self: *const FrameStore) usize {
    return self.max_rows;
}

pub fn rowCapacity(self: *const FrameStore) usize {
    return self.frames.capacity;
}

/// Addressable words for the active LIFO frame set, including the active
/// frame's 1,024-word execution headroom.
pub fn activeStackWordCount(self: *const FrameStore) usize {
    return self.stack_words.items.len;
}

pub fn stackWordCapacity(self: *const FrameStore) usize {
    return self.stack_words.capacity;
}

/// Peak count of suspended live words below an acquired active frame.
pub fn maxStackBase(self: *const FrameStore) usize {
    return self.max_stack_base;
}

/// Peak addressable arena window, including active-frame headroom.
pub fn maxStackWordCount(self: *const FrameStore) usize {
    return self.max_stack_words;
}

pub fn ioRowCapacity(self: *const FrameStore) usize {
    return self.ios.items.len;
}

pub fn memoryRowCapacity(self: *const FrameStore) usize {
    return self.memories.items.len;
}

fn appendRow(self: *FrameStore, allocator: std.mem.Allocator) !usize {
    try self.ensureUnusedCapacity(allocator, 1);

    const index = self.frames.items.len;
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
        std.debug.assert(self.hasUnusedCapacity(additional));
        return;
    }

    const before = self.capacities();
    var done = false;
    defer if (!done and self.capacitiesChanged(before)) self.rebindActiveFrames();

    try self.frames.ensureUnusedCapacity(allocator, additional);
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

    const io = frame_io.Slot.init(allocator);
    self.memories.appendAssumeCapacity(.empty);
    self.ios.appendAssumeCapacity(io);
}

fn release(self: *FrameStore, index: usize) void {
    std.debug.assert(index < self.frames.items.len);
    std.debug.assert(index == self.frames.items.len - 1);

    self.frames.items[index].deinit();
    self.frames.items.len = index;
    self.messages.items.len = index;
    self.restoreStackRange(index);
}

fn popUninitialized(self: *FrameStore) void {
    std.debug.assert(self.frames.items.len != 0);
    const index = self.frames.items.len - 1;
    self.frames.items.len = index;
    self.messages.items.len = index;
    self.restoreStackRange(index);
}

fn rebindActiveFrames(self: *FrameStore) void {
    for (0..self.frames.items.len) |index| {
        self.frames.items[index].msg = &self.messages.items[index];
        self.frames.items[index].memory.rebindStorage(&self.memories.items[index]);
        self.frames.items[index].io = &self.ios.items[index];
        self.frames.items[index].return_data = self.ios.items[index].return_data.slice();
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
    messages: usize,
    stack_words: usize,
    memories: usize,
    ios: usize,
};

fn capacities(self: *const FrameStore) Capacities {
    return .{
        .frames = self.frames.capacity,
        .messages = self.messages.capacity,
        .stack_words = self.stack_words.capacity,
        .memories = self.memories.capacity,
        .ios = self.ios.capacity,
    };
}

fn capacitiesChanged(self: *const FrameStore, before: Capacities) bool {
    const after = self.capacities();
    return after.frames != before.frames or
        after.messages != before.messages or
        after.stack_words != before.stack_words or
        after.memories != before.memories or
        after.ios != before.ios;
}

test "frame store rebinds active rows after growth" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.frames.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.messages.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.stack_words.ensureTotalCapacityPrecise(std.testing.allocator, Stack.capacity);
    try store.memories.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.ios.ensureTotalCapacityPrecise(std.testing.allocator, 1);

    var host: Host = undefined;
    const first_msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var first = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &first_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer first.deinit();
    try first.callFrame().stack.push(11);
    try first.callFrame().stack.push(22);
    try first.callFrame().stack.push(33);
    try first.callFrame().memory.expandToFit(0, 32);
    first.callFrame().memory.writeBytes(0, "abc");

    const second_msg = Host.Message{
        .depth = 1,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var second = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &second_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    try second.callFrame().stack.push(44);

    try std.testing.expect(first.callFrame().msg == &store.messages.items[first.index]);
    try std.testing.expectEqual(@as(u32, 0), first.callFrame().stack.base_word);
    try std.testing.expectEqual(@as(u32, 3), second.callFrame().stack.base_word);
    try std.testing.expectEqual(@intFromPtr(&store.stack_words.items[0]), @intFromPtr(first.callFrame().stack.base));
    try std.testing.expectEqual(@intFromPtr(&store.stack_words.items[3]), @intFromPtr(second.callFrame().stack.base));
    try std.testing.expectEqualSlices(u256, &.{ 11, 22, 33 }, first.callFrame().stack.asSlice());
    try std.testing.expectEqualSlices(u256, &.{44}, second.callFrame().stack.asSlice());
    try std.testing.expect(first.callFrame().memory.bytes == &store.memories.items[first.index]);
    try std.testing.expectEqualSlices(u8, "abc", first.callFrame().memory.readBytes(0, 3));
    try std.testing.expect(first.callFrame().io == &store.ios.items[first.index]);
    try std.testing.expectEqual(@as(u16, 0), first.callFrame().msg.depth);
    try std.testing.expectEqual(@as(u16, 1), second.callFrame().msg.depth);

    const sibling_base = second.callFrame().stack.base_word;
    second.deinit();
    var sibling = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &second_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer sibling.deinit();
    try std.testing.expectEqual(sibling_base, sibling.callFrame().stack.base_word);
    try std.testing.expectEqual(@as(u16, 0), sibling.callFrame().stack.len);
}

test "stack arena growth failure leaves the parent row usable" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    const root_msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var root = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &root_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer root.deinit();
    for (0..600) |word| try root.callFrame().stack.push(@intCast(word));
    try store.ensureConstructedRow(std.testing.allocator, 1);

    var child_msg = root_msg;
    child_msg.depth = 1;
    try std.testing.expectError(error.OutOfMemory, store.acquire(
        no_growth_allocator,
        no_growth_allocator,
        .{
            .host = &host,
            .msg = &child_msg,
            .bytecode = &evmz.Bytecode.empty,
        },
    ));

    try std.testing.expectEqual(@as(usize, 1), store.activeRowCount());
    try std.testing.expectEqual(@as(usize, Stack.capacity), store.activeStackWordCount());
    try std.testing.expectEqual(@as(u16, 600), root.callFrame().stack.len);
    try std.testing.expectEqual(@as(u256, 0), root.callFrame().stack.asSlice()[0]);
    try std.testing.expectEqual(@as(u256, 599), root.callFrame().stack.asSlice()[599]);
}

test "stable metadata capacity prevents active frame relocation" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 0), store.ioRowCapacity());

    var host: Host = undefined;
    const root_msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var root = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &root_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer root.deinit();
    const root_ptr = root.callFrame();
    try std.testing.expectEqual(@as(usize, 2), store.rowCapacity());
    try std.testing.expectEqual(@as(usize, 1), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 1), store.ioRowCapacity());

    var child_msg = root_msg;
    child_msg.depth = 1;
    var child = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &child_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    try std.testing.expect(root.callFrame() == root_ptr);
    try std.testing.expectEqual(@as(usize, 2), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 2), store.ioRowCapacity());

    child.deinit();
    var sibling = try store.acquire(no_growth_allocator, no_growth_allocator, .{
        .host = &host,
        .msg = &child_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer sibling.deinit();
    try std.testing.expect(root.callFrame() == root_ptr);
    try std.testing.expectEqual(@as(usize, 2), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 2), store.ioRowCapacity());
}

test "packed stack arena advances by suspended live words" {
    var store: FrameStore = .{ .stable_metadata_capacity = 2 };
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    const root_msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var root = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &root_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer root.deinit();
    for (0..1000) |word| try root.callFrame().stack.push(@intCast(word));

    var child_msg = root_msg;
    child_msg.depth = 1;
    var child = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &child_msg,
        .bytecode = &evmz.Bytecode.empty,
    });
    defer child.deinit();

    try std.testing.expectEqual(@as(u32, 1000), child.callFrame().stack.base_word);
    try std.testing.expectEqual(@as(usize, 1000), store.maxStackBase());
    try std.testing.expectEqual(@as(usize, 1000 + Stack.capacity), store.activeStackWordCount());
    try std.testing.expectEqual(@as(u256, 0), root.callFrame().stack.asSlice()[0]);
    try std.testing.expectEqual(@as(u256, 500), root.callFrame().stack.asSlice()[500]);
    try std.testing.expectEqual(@as(u256, 999), root.callFrame().stack.asSlice()[999]);
}

test "frame store owns parent returndata and resolves output from frame memory" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    var host: Host = undefined;
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var lease = try store.acquire(std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &evmz.Bytecode.empty,
    });

    try lease.callFrame().replaceReturnData("abc");
    try std.testing.expectEqualSlices(u8, "abc", lease.callFrame().return_data);
    try std.testing.expect(lease.callFrame().return_data.ptr == store.ios.items[lease.index].return_data.buf.ptr);
    try lease.callFrame().replaceReturnData("abcd");
    try std.testing.expectEqualSlices(u8, "abcd", lease.callFrame().return_data);

    _ = try lease.callFrame().memory.expand(0, 32);
    lease.callFrame().memory.writeBytes(0, "xyz");
    lease.callFrame().setOutputRange(0, 3);
    try std.testing.expectEqualSlices(u8, "xyz", lease.callFrame().getResult().output_data);

    _ = try lease.callFrame().memory.expand(4096, 1);
    try std.testing.expectEqualSlices(u8, "xyz", lease.callFrame().getResult().output_data);

    lease.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.ios.items[0].return_data.slice().len);
}
