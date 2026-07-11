// TODO: file name should be FrameStore
const std = @import("std");

const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");
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
stacks: std.ArrayList(Stack.Storage) = .empty,
memories: std.ArrayList(Memory.Storage) = .empty,
ios: std.ArrayList(frame_io.Slot) = .empty,
max_rows: usize = 0,
capacity_limit: ?usize = null,
io_bytes_per_frame: ?usize = null,
memory_bytes_per_frame: ?usize = null,

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

    pub fn interpreter(self: *const Lease, comptime Protocol: type) Interpreter.For(Protocol) {
        return Interpreter.For(Protocol).init(self.callFrame());
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
    self.stacks.deinit(allocator);
    self.memories.deinit(allocator);
    for (self.ios.items) |*slot| {
        slot.deinit();
    }
    self.ios.deinit(allocator);
    self.* = .{};
}

pub fn reserveExact(
    self: *FrameStore,
    allocator: std.mem.Allocator,
    capacity: usize,
    io_bytes_per_frame: ?usize,
    memory_bytes_per_frame: ?usize,
) !void {
    if (self.frames.items.len != 0) return error.ActiveFramesInFrameStore;

    try self.frames.ensureTotalCapacityPrecise(allocator, capacity);
    try self.messages.ensureTotalCapacityPrecise(allocator, capacity);
    try self.stacks.ensureTotalCapacityPrecise(allocator, capacity);
    try self.ensureMemorySlotCapacity(allocator, capacity);
    try self.configureMemorySlots(allocator, capacity, memory_bytes_per_frame);
    self.memory_bytes_per_frame = memory_bytes_per_frame;
    self.io_bytes_per_frame = io_bytes_per_frame;
    try self.ensureIoSlotCapacity(allocator, capacity);
    try self.configureIoSlots(capacity, io_bytes_per_frame);
    self.capacity_limit = capacity;
}

pub fn setGrowable(self: *FrameStore, allocator: std.mem.Allocator) !void {
    if (self.frames.items.len != 0) return error.ActiveFramesInFrameStore;
    self.capacity_limit = null;
    self.io_bytes_per_frame = null;
    self.memory_bytes_per_frame = null;
    for (self.memories.items) |*storage| {
        storage.deinit(allocator);
        storage.* = .empty;
    }
    for (self.ios.items) |*slot| {
        slot.setGrowable();
    }
}

pub fn acquire(
    self: *FrameStore,
    comptime Protocol: type,
    store_allocator: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    options: Interpreter.InitFor(Protocol),
) !Lease {
    const index = try self.appendRow(store_allocator);
    errdefer self.popUninitialized();

    var frame_options = options;
    frame_options.io = &self.ios.items[index];
    if (self.memory_bytes_per_frame != null) {
        frame_options.memory_allocator = no_growth_allocator;
        frame_options.memory_retain_capacity = true;
    }
    try self.frames.items[index].initFor(
        Protocol,
        frame_allocator,
        frame_options,
        &self.messages.items[index],
        &self.stacks.items[index],
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

pub fn ioRowCapacity(self: *const FrameStore) usize {
    return self.ios.items.len;
}

pub fn memoryRowCapacity(self: *const FrameStore) usize {
    return self.memories.items.len;
}

pub fn isBounded(self: *const FrameStore) bool {
    return self.capacity_limit != null;
}

pub fn capacityLimit(self: *const FrameStore) ?usize {
    return self.capacity_limit;
}

fn appendRow(self: *FrameStore, allocator: std.mem.Allocator) !usize {
    try self.ensureUnusedCapacity(allocator, 1);

    const index = self.frames.items.len;
    self.frames.appendAssumeCapacity(undefined);
    self.messages.appendAssumeCapacity(undefined);
    self.stacks.appendAssumeCapacity(undefined);
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
    if (self.capacity_limit) |limit| {
        if (self.frames.items.len + additional > limit) return error.FrameCapacityExceeded;
        if (!self.hasUnusedCapacity(additional)) return error.FrameCapacityExceeded;
        return;
    }

    const before = self.capacities();
    var done = false;
    defer if (!done and self.capacitiesChanged(before)) self.rebindActiveFrames();

    try self.frames.ensureUnusedCapacity(allocator, additional);
    try self.messages.ensureUnusedCapacity(allocator, additional);
    try self.stacks.ensureUnusedCapacity(allocator, additional);
    try self.ensureMemorySlotCapacity(allocator, self.frames.capacity);
    try self.ensureIoSlotCapacity(allocator, self.frames.capacity);

    done = true;
    if (self.capacitiesChanged(before)) {
        self.rebindActiveFrames();
    }
}

fn hasUnusedCapacity(self: *const FrameStore, additional: usize) bool {
    return self.frames.capacity - self.frames.items.len >= additional and
        self.messages.capacity - self.messages.items.len >= additional and
        self.stacks.capacity - self.stacks.items.len >= additional and
        self.memories.items.len >= self.frames.items.len + additional and
        self.ios.items.len >= self.frames.items.len + additional;
}

fn release(self: *FrameStore, index: usize) void {
    std.debug.assert(index < self.frames.items.len);
    std.debug.assert(index == self.frames.items.len - 1);

    if (self.memory_bytes_per_frame != null) {
        self.frames.items[index].deinitRetainingMemoryCapacity();
    } else {
        self.frames.items[index].deinit();
    }
    self.frames.items.len = index;
    self.messages.items.len = index;
    self.stacks.items.len = index;
}

fn popUninitialized(self: *FrameStore) void {
    std.debug.assert(self.frames.items.len != 0);
    const index = self.frames.items.len - 1;
    self.frames.items.len = index;
    self.messages.items.len = index;
    self.stacks.items.len = index;
}

fn rebindActiveFrames(self: *FrameStore) void {
    for (0..self.frames.items.len) |index| {
        self.frames.items[index].msg = &self.messages.items[index];
        self.frames.items[index].stack.slots = &self.stacks.items[index];
        self.frames.items[index].memory.rebindStorage(&self.memories.items[index]);
        self.frames.items[index].io = &self.ios.items[index];
        self.frames.items[index].return_data = self.ios.items[index].return_data.slice();
        self.frames.items[index].output_data = self.ios.items[index].output_data.slice();
    }
}

fn ensureIoSlotCapacity(self: *FrameStore, allocator: std.mem.Allocator, capacity: usize) !void {
    if (self.ios.items.len >= capacity) return;

    try self.ios.ensureTotalCapacityPrecise(allocator, capacity);
    while (self.ios.items.len < capacity) {
        const slot = if (self.io_bytes_per_frame) |bytes_per_frame|
            try frame_io.Slot.initBounded(allocator, bytes_per_frame)
        else
            frame_io.Slot.initGrowable(allocator);
        self.ios.appendAssumeCapacity(slot);
    }
}

fn ensureMemorySlotCapacity(self: *FrameStore, allocator: std.mem.Allocator, capacity: usize) !void {
    if (self.memories.items.len >= capacity) return;

    try self.memories.ensureTotalCapacityPrecise(allocator, capacity);
    while (self.memories.items.len < capacity) {
        self.memories.appendAssumeCapacity(.empty);
    }
}

fn configureMemorySlots(
    self: *FrameStore,
    allocator: std.mem.Allocator,
    capacity: usize,
    memory_bytes_per_frame: ?usize,
) !void {
    for (self.memories.items[0..capacity]) |*storage| {
        storage.deinit(allocator);
        storage.* = .empty;
        if (memory_bytes_per_frame) |bytes_per_frame| {
            try Memory.reserveCapacity(storage, allocator, bytes_per_frame);
        }
    }
}

fn configureIoSlots(self: *FrameStore, capacity: usize, io_bytes_per_frame: ?usize) !void {
    for (self.ios.items[0..capacity]) |*slot| {
        if (io_bytes_per_frame) |bytes_per_frame| {
            try slot.setBounded(bytes_per_frame);
        } else {
            slot.setGrowable();
        }
    }
}

const Capacities = struct {
    frames: usize,
    messages: usize,
    stacks: usize,
    memories: usize,
    ios: usize,
};

fn capacities(self: *const FrameStore) Capacities {
    return .{
        .frames = self.frames.capacity,
        .messages = self.messages.capacity,
        .stacks = self.stacks.capacity,
        .memories = self.memories.capacity,
        .ios = self.ios.capacity,
    };
}

fn capacitiesChanged(self: *const FrameStore, before: Capacities) bool {
    const after = self.capacities();
    return after.frames != before.frames or
        after.messages != before.messages or
        after.stacks != before.stacks or
        after.memories != before.memories or
        after.ios != before.ios;
}

test "frame store rebinds active rows after growth" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.frames.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.messages.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.stacks.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.memories.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    try store.ensureIoSlotCapacity(std.testing.allocator, 1);

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
    var first = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &first_msg,
        .revision = .latest,
    });
    defer first.deinit();
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
    var second = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &second_msg,
        .revision = .latest,
    });
    defer second.deinit();

    try std.testing.expect(first.callFrame().msg == &store.messages.items[first.index]);
    try std.testing.expect(first.callFrame().stack.slots == &store.stacks.items[first.index]);
    try std.testing.expect(first.callFrame().memory.bytes == &store.memories.items[first.index]);
    try std.testing.expectEqualSlices(u8, "abc", first.callFrame().memory.readBytes(0, 3));
    try std.testing.expect(first.callFrame().io == &store.ios.items[first.index]);
    try std.testing.expectEqual(@as(u16, 0), first.callFrame().msg.depth);
    try std.testing.expectEqual(@as(u16, 1), second.callFrame().msg.depth);
}

test "bounded frame store uses reserved rows without growth" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.reserveExact(std.testing.allocator, 2, 3, null);
    try std.testing.expect(store.isBounded());
    try std.testing.expectEqual(@as(?usize, 2), store.capacityLimit());
    try std.testing.expectEqual(@as(usize, 2), store.rowCapacity());
    try std.testing.expectEqual(@as(usize, 2), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 2), store.ioRowCapacity());
    try std.testing.expectEqual(@as(usize, 3), store.ios.items[0].return_data.capacity());
    try std.testing.expectEqual(@as(usize, 3), store.ios.items[0].output_data.capacity());

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
    var first = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &first_msg,
        .revision = .latest,
    });
    defer first.deinit();

    const second_msg = Host.Message{
        .depth = 1,
        .kind = .call,
        .gas = 100,
        .recipient = std.mem.zeroes(Address),
        .sender = std.mem.zeroes(Address),
        .input_data = &.{},
        .value = 0,
    };
    var second = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &second_msg,
        .revision = .latest,
    });
    defer second.deinit();

    try std.testing.expectError(error.FrameCapacityExceeded, store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &second_msg,
        .revision = .latest,
    }));
    try std.testing.expectEqual(@as(usize, 2), store.rowCapacity());
}

test "frame store io slot owns frame output and parent returndata without frame allocation" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.reserveExact(std.testing.allocator, 1, 3, null);

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
    var lease = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .revision = .latest,
    });

    try lease.callFrame().replaceReturnData("abc");
    try std.testing.expectEqualSlices(u8, "abc", lease.callFrame().return_data);
    try std.testing.expect(lease.callFrame().return_data.ptr == store.ios.items[lease.index].return_data.buf.ptr);
    try std.testing.expectError(error.FrameIoCapacityExceeded, lease.callFrame().replaceReturnData("abcd"));
    try std.testing.expectEqualSlices(u8, "abc", lease.callFrame().return_data);

    try lease.callFrame().replaceOutputData("xyz");
    try std.testing.expectEqualSlices(u8, "xyz", lease.callFrame().output_data);
    try std.testing.expect(lease.callFrame().output_data.ptr != store.ios.items[lease.index].output_data.buf.ptr);
    _ = try lease.callFrame().stabilizeOutputData();
    try std.testing.expect(lease.callFrame().output_data.ptr == store.ios.items[lease.index].output_data.buf.ptr);
    try lease.callFrame().replaceOutputData("xyzz");
    try std.testing.expectError(error.FrameIoCapacityExceeded, lease.callFrame().stabilizeOutputData());
    try std.testing.expectEqualSlices(u8, "xyz", store.ios.items[lease.index].output_data.slice());

    lease.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.ios.items[0].return_data.slice().len);
    try std.testing.expectEqual(@as(usize, 0), store.ios.items[0].output_data.slice().len);
}

test "bounded frame store reconfigures retained growable io slots" {
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

    var growable = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .revision = .latest,
    });
    try growable.callFrame().replaceReturnData("abcd");
    growable.deinit();

    try store.reserveExact(std.testing.allocator, 1, 3, null);
    try std.testing.expectEqual(@as(usize, 3), store.ios.items[0].return_data.capacity());
    try std.testing.expectEqual(@as(usize, 3), store.ios.items[0].output_data.capacity());

    var bounded = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .revision = .latest,
    });
    try std.testing.expectError(error.FrameIoCapacityExceeded, bounded.callFrame().replaceReturnData("abcd"));
    bounded.deinit();
}

test "bounded frame store reuses reserved evm memory without allocator growth" {
    var store: FrameStore = .{};
    defer store.deinit(std.testing.allocator);

    try store.reserveExact(std.testing.allocator, 1, null, 32);
    try std.testing.expectEqual(@as(usize, 1), store.memoryRowCapacity());
    try std.testing.expectEqual(@as(usize, 32), store.memories.items[0].capacity);

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

    var first = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .revision = .latest,
    });
    try first.callFrame().memory.expandToFit(0, 32);
    try std.testing.expectError(error.OutOfMemory, first.callFrame().memory.expandToFit(32, 32));
    first.deinit();

    try std.testing.expectEqual(@as(usize, 32), store.memories.items[0].capacity);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items[0].items.len);

    var second = try store.acquire(evmz.Evm.Protocol, std.testing.allocator, std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .revision = .latest,
    });
    defer second.deinit();
    try second.callFrame().memory.expandToFit(0, 32);
    try std.testing.expect(second.callFrame().memory.bytes == &store.memories.items[second.index]);
}
