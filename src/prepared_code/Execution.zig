//! One top-level prepared-code lifetime shared by root and nested frames.

const std = @import("std");
const Backend = @import("Backend.zig");
const Bytecode = @import("../code/Bytecode.zig");

const Execution = @This();

pub const ResolvePolicy = struct {
    /// Permit the backend to retain a miss across executions.
    admit: bool = true,
};

backend: ?Backend,
scratch_allocator: std.mem.Allocator,
transient_entries: std.AutoHashMap([32]u8, Bytecode.View),
owned_entries: std.ArrayList(Bytecode),

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
pub fn resolve(
    self: *Execution,
    code_hash: [32]u8,
    raw_code: []const u8,
    policy: ResolvePolicy,
) !Bytecode.View {
    if (raw_code.len == 0) return .empty;
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

/// Resolve executable code from an authenticated hash only when the backend
/// explicitly promises that raw bytes cannot alter code-address semantics.
pub fn lookupAuthenticated(self: *Execution, code_hash: [32]u8) ?Bytecode.View {
    const backend = self.backend orelse return null;
    return backend.lookupAuthenticated(code_hash) catch null;
}

/// Prepare ephemeral executable bytes, such as CREATE initcode, for this
/// top-level execution without consulting or admitting them to the backend.
pub fn prepareTransient(self: *Execution, raw_code: []const u8) !Bytecode.View {
    if (raw_code.len == 0) return .empty;

    var bytecode = Bytecode.prepare(self.scratch_allocator, raw_code) catch |err| switch (err) {
        error.OutOfMemory => return error.PreparedCodeCapacityExceeded,
    };
    errdefer bytecode.deinit(self.scratch_allocator);
    self.owned_entries.append(self.scratch_allocator, bytecode) catch
        return error.PreparedCodeCapacityExceeded;
    return self.owned_entries.items[self.owned_entries.items.len - 1].view();
}

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
    const code_hash = @import("../crypto.zig").keccak256(&raw_code);
    const first = try execution.resolve(code_hash, &raw_code, .{});
    const second = try execution.resolve(code_hash, &raw_code, .{});
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
