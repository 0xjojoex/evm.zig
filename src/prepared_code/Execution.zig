//! One top-level prepared-code lifetime shared by root and nested frames.

const std = @import("std");
const Backend = @import("Backend.zig");
const Bytecode = @import("../code/Bytecode.zig");

const Execution = @This();

pub const ResolvePolicy = struct {
    /// Permit the backend to retain a miss across executions.
    admit: bool = true,
};

/// Largest value `resolve` treats as a dense code index. Anything above it
/// means "no index": the caller passes its `CodeRef` bit pattern unchanged,
/// so a memo hit never spends instructions classifying it.
pub const max_index: u32 = std.math.maxInt(u32) - 2;
/// A value above `max_index`, for callers that resolve by hash alone.
pub const no_index: u32 = std.math.maxInt(u32);

backend: ?Backend,
scratch_allocator: std.mem.Allocator,
transient_entries: std.AutoHashMap([32]u8, Bytecode.View),
owned_entries: std.ArrayList(Bytecode),
/// Two remembered hash to view resolutions with round-robin eviction.
/// Two slots for commonly shape for delegatecall proxy patterns.
///
/// Nested calls resolve the same one or two code hashes on every frame;
/// remembering them skips the hash-map probe. Entries die with this execution,
/// so a view can never outlive the scratch storage it points into.
/// Keys stay `[32]u8`: a by-value parameter sits on compiler-aligned stack storage,
/// so the byte-wise compare already lowers to word compares and a pre-assembled word
/// key measured slower.
memo_hashes: [2][32]u8 = undefined,
memo_views: [2]Bytecode.View = undefined,
memo_valid: [2]bool = .{ false, false },
memo_victim: u1 = 0,

/// Backend startup failure disables only the optimization for this execution.
pub fn init(scratch_allocator: std.mem.Allocator, maybe_backend: ?Backend) Execution {
    const active_backend = if (maybe_backend) |backend| active: {
        backend.beginExecution() catch break :active null;
        break :active backend;
    } else null;

    return .{
        .backend = active_backend,
        .scratch_allocator = scratch_allocator,
        .transient_entries = std.AutoHashMap([32]u8, Bytecode.View).init(scratch_allocator),
        .owned_entries = .empty,
    };
}

pub fn deinit(self: *Execution) void {
    if (self.backend) |backend| backend.endExecution();
    self.transient_entries.deinit();
    var index = self.owned_entries.items.len;
    while (index > 0) {
        index -= 1;
        self.owned_entries.items[index].deinit(self.scratch_allocator);
    }
    self.owned_entries.deinit(self.scratch_allocator);
    self.* = undefined;
}

/// Resolve one canonical code view to an immutable execution-ready artifact.
///
/// Backend failures and admission refusal fall back to transient preparation;
/// `CodeHashMismatch` remains a correctness error. Every successful resolution
/// returns the one representation accepted by the interpreter.
pub inline fn resolve(
    self: *Execution,
    code_hash: [32]u8,
    raw_code: []const u8,
    index: u32,
    policy: ResolvePolicy,
) !Bytecode.View {
    if (raw_code.len == 0) return .empty;
    inline for (0..2) |entry| {
        if (self.memo_valid[entry] and
            std.mem.eql(u8, &self.memo_hashes[entry], &code_hash))
        {
            return self.memo_views[entry];
        }
    }
    const bytecode = try self.resolveUncached(code_hash, raw_code, index, policy);
    const victim = self.memo_victim;
    self.memo_hashes[victim] = code_hash;
    self.memo_views[victim] = bytecode;
    self.memo_valid[victim] = true;
    self.memo_victim +%= 1;
    return bytecode;
}

/// Indexed views try the backend's indexed lane first. The backend owns any
/// hash-based deduplication on admission; this execution's hash map is only
/// needed when indexed resolution cannot serve the view.
fn resolveUncached(
    self: *Execution,
    code_hash: [32]u8,
    raw_code: []const u8,
    index: u32,
    policy: ResolvePolicy,
) !Bytecode.View {
    if (index <= max_index) {
        if (self.backend) |backend| {
            if (backend.supportsIndexed()) {
                if (backend.lookupIndexed(index, code_hash)) |bytecode| return bytecode;
                if (policy.admit) {
                    const admitted = backend.admitIndexed(index, code_hash, raw_code) catch |err| switch (err) {
                        error.CodeHashMismatch => return err,
                        else => null,
                    };
                    if (admitted) |bytecode| return bytecode;
                }
            }
        }
    }

    if (self.transient_entries.get(code_hash)) |bytecode| return bytecode;

    if (self.backend) |backend| {
        if (backend.lookup(code_hash) catch null) |bytecode| return bytecode;
    }

    if (policy.admit) {
        if (self.backend) |backend| {
            const admitted = backend.admit(code_hash, raw_code) catch |err| switch (err) {
                error.CodeHashMismatch => return err,
                else => null,
            };
            if (admitted) |bytecode| return bytecode;
        }
    }

    const bytecode = try self.prepareTransient(raw_code);
    self.transient_entries.putNoClobber(code_hash, bytecode) catch return bytecode;
    return bytecode;
}

/// Prepare ephemeral executable bytes, such as CREATE initcode, for this
/// top-level execution without consulting or admitting them to the backend.
pub fn prepareTransient(self: *Execution, raw_code: []const u8) !Bytecode.View {
    if (raw_code.len == 0) return .empty;

    var bytecode = Bytecode.init(self.scratch_allocator, raw_code) catch |err| switch (err) {
        error.OutOfMemory => return error.PreparedCodeCapacityExceeded,
    };
    errdefer bytecode.deinit(self.scratch_allocator);
    self.owned_entries.append(self.scratch_allocator, bytecode) catch
        return error.PreparedCodeCapacityExceeded;
    return self.owned_entries.items[self.owned_entries.items.len - 1].view();
}

const crypto = @import("../crypto.zig");

test "backend failure falls back to one transient artifact" {
    const FailingBackend = struct {
        fn backend(self: *@This()) Backend {
            return .{ .ptr = self, .vtable = &.{
                .beginExecution = beginExecution,
                .endExecution = endExecution,
                .lookup = lookup,
                .admit = admit,
            } };
        }

        fn beginExecution(ptr: *anyopaque) !void {
            _ = ptr;
            return error.BackendUnavailable;
        }

        fn endExecution(ptr: *anyopaque) void {
            _ = ptr;
            unreachable;
        }

        fn lookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
            _ = ptr;
            _ = code_hash;
            unreachable;
        }

        fn admit(ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
            _ = ptr;
            _ = code_hash;
            _ = raw_code;
            unreachable;
        }
    };

    var failing = FailingBackend{};
    var execution = Execution.init(std.testing.allocator, failing.backend());
    defer execution.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const code_hash = crypto.keccak256(&raw_code);
    const first = try execution.resolve(code_hash, &raw_code, no_index, .{});
    const second = try execution.resolve(code_hash, &raw_code, no_index, .{});
    try std.testing.expectEqual(first.bytes.ptr, second.bytes.ptr);
}

test "bounded preparation reports capacity exhaustion without raw fallback" {
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var execution = Execution.init(fixed.allocator(), null);
    defer execution.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    try std.testing.expectError(
        error.PreparedCodeCapacityExceeded,
        execution.prepareTransient(&raw_code),
    );
}

test "resolve memo returns stable views across alternation and eviction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var execution = Execution.init(arena.allocator(), null);
    defer execution.deinit();

    const codes = [_][]const u8{
        &.{ 0x60, 0x01, 0x00 },
        &.{ 0x60, 0x02, 0x00 },
        &.{ 0x60, 0x03, 0x00 },
    };
    var hashes: [3][32]u8 = undefined;
    var first: [3]Bytecode.View = undefined;
    for (codes, 0..) |code, index| {
        std.crypto.hash.sha3.Keccak256.hash(code, &hashes[index], .{});
        first[index] = try execution.resolve(hashes[index], code, no_index, .{});
    }
    // Alternation plus eviction revisits: every hit must return the same
    // prepared artifact bytes the first resolution produced.
    const sequence = [_]usize{ 0, 1, 0, 1, 2, 0, 1, 2, 2, 0 };
    for (sequence) |index| {
        const view = try execution.resolve(hashes[index], codes[index], no_index, .{});
        try std.testing.expectEqual(first[index].bytes.ptr, view.bytes.ptr);
        try std.testing.expectEqualSlices(u8, first[index].bytes, view.bytes);
    }
}

test "indexed views resolve through the indexed lane and never reach the hash lane" {
    const IndexedBackend = struct {
        indexed_lookups: usize = 0,
        indexed_admits: usize = 0,
        retained_index: ?u32 = null,
        retained: ?Bytecode = null,

        fn backend(self: *@This()) Backend {
            return .{ .ptr = self, .vtable = &.{
                .beginExecution = beginExecution,
                .endExecution = endExecution,
                .lookup = lookup,
                .admit = admit,
                .lookupIndexed = lookupIndexed,
                .admitIndexed = admitIndexed,
            } };
        }

        fn beginExecution(ptr: *anyopaque) !void {
            _ = ptr;
        }

        fn endExecution(ptr: *anyopaque) void {
            _ = ptr;
        }

        fn lookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
            _ = ptr;
            _ = code_hash;
            return error.HashLaneTouched;
        }

        fn admit(ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
            _ = ptr;
            _ = code_hash;
            _ = raw_code;
            return error.HashLaneTouched;
        }

        fn lookupIndexed(ptr: *anyopaque, index: u32, code_hash: [32]u8) ?Bytecode.View {
            _ = code_hash;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.indexed_lookups += 1;
            if (self.retained_index != index) return null;
            return self.retained.?.view();
        }

        fn admitIndexed(ptr: *anyopaque, index: u32, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
            _ = code_hash;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.indexed_admits += 1;
            self.retained = try Bytecode.init(std.testing.allocator, raw_code);
            self.retained_index = index;
            return self.retained.?.view();
        }
    };

    var indexed = IndexedBackend{};
    defer if (indexed.retained) |*bytecode| bytecode.deinit(std.testing.allocator);
    var execution = Execution.init(std.testing.allocator, indexed.backend());
    defer execution.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const code_hash = crypto.keccak256(&raw_code);
    const admitted = try execution.resolve(code_hash, &raw_code, 5, .{});
    try std.testing.expectEqual(@as(usize, 1), indexed.indexed_lookups);
    try std.testing.expectEqual(@as(usize, 1), indexed.indexed_admits);

    // Memo hit: no backend traffic at all.
    const memoized = try execution.resolve(code_hash, &raw_code, 5, .{});
    try std.testing.expectEqual(admitted.bytes.ptr, memoized.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), indexed.indexed_lookups);

    // Evict the memo with two other hashes, then come back through the
    // indexed lookup rather than admission or the hash lane.
    const other_a = [_]u8{ 0x60, 0x02, 0x00 };
    const other_b = [_]u8{ 0x60, 0x03, 0x00 };
    // Ref-less views must not consult the hash lane of a backend that
    // reports the error above, so they fall back to transient preparation.
    _ = try execution.resolve(crypto.keccak256(&other_a), &other_a, no_index, .{ .admit = false });
    _ = try execution.resolve(crypto.keccak256(&other_b), &other_b, no_index, .{ .admit = false });
    const looked_up = try execution.resolve(code_hash, &raw_code, 5, .{});
    try std.testing.expectEqual(admitted.bytes.ptr, looked_up.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 2), indexed.indexed_lookups);
    try std.testing.expectEqual(@as(usize, 1), indexed.indexed_admits);
    try std.testing.expectEqual(@as(usize, 2), execution.transient_entries.count());
}
