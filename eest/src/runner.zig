//! Shared fixture-tree driver for the EEST commands.
//!
//! Every fixture command walks a path, feeds each `.json` file to its runner
//! module, and folds the per-file summaries. Only the module types differ, so
//! the walk, the bounded worker pool, and the deterministic error report live
//! here once.

const std = @import("std");
const fixture_pool = @import("fixture_pool.zig");

pub fn parseJobs(value: []const u8, max: usize) !usize {
    const jobs = try std.fmt.parseInt(usize, value, 10);
    if (jobs == 0 or jobs > max) return error.InvalidJobs;
    return jobs;
}

/// `module` must expose `Options`, a default-constructible `Summary` with
/// `add`, and `runFile(io, allocator, path, options) !Summary`. A `limit`
/// field on `Options` stops the walk once `Summary.fixtures` reaches it.
pub fn Runner(comptime module: type) type {
    return struct {
        const Options = module.Options;
        const Summary = module.Summary;
        const has_limit = @hasField(Options, "limit");

        pub fn run(
            io: std.Io,
            allocator: std.mem.Allocator,
            path: []const u8,
            options: Options,
            jobs: usize,
        ) !Summary {
            return if (jobs == 1)
                sequential(io, allocator, path, options)
            else
                concurrent(io, allocator, path, options, jobs);
        }

        pub fn sequential(
            io: std.Io,
            allocator: std.mem.Allocator,
            path: []const u8,
            options: Options,
        ) !Summary {
            var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
                error.NotDir => return module.runFile(io, allocator, path, options),
                else => return err,
            };
            defer dir.close(io);

            var total = Summary{};
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                defer allocator.free(child);
                switch (entry.kind) {
                    .directory => total.add(try sequential(io, allocator, child, options)),
                    .file => if (std.mem.endsWith(u8, entry.name, ".json")) {
                        total.add(try module.runFile(io, allocator, child, options));
                    },
                    else => {},
                }
                if (has_limit and options.limit > 0 and total.fixtures >= options.limit) break;
            }
            return total;
        }

        fn concurrent(
            io: std.Io,
            allocator: std.mem.Allocator,
            path: []const u8,
            options: Options,
            jobs: usize,
        ) !Summary {
            var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
                error.NotDir => return module.runFile(io, allocator, path, options),
                else => return err,
            };
            dir.close(io);

            const workers = try allocator.alloc(Worker, jobs);
            defer {
                for (workers) |*worker| worker.deinit();
                allocator.free(workers);
            }
            for (workers) |*worker| worker.* = .{
                .allocator = allocator,
                .arena = .init(allocator),
                .options = options,
            };
            try fixture_pool.runWorkers(io, allocator, path, workers, .{ .suffix = ".json" }, Worker.run);

            var total = Summary{};
            var file_errors: std.ArrayList(FileError) = .empty;
            defer file_errors.deinit(allocator);
            var allocation_error: ?anyerror = null;
            for (workers) |*worker| {
                total.add(worker.summary);
                try file_errors.appendSlice(allocator, worker.file_errors.items);
                if (allocation_error == null) allocation_error = worker.allocation_error;
            }
            std.sort.heap(FileError, file_errors.items, {}, fileErrorLessThan);
            for (file_errors.items) |file_error| {
                std.debug.print("ERROR {s}: {s}\n", .{ file_error.path, @errorName(file_error.err) });
            }
            if (allocation_error) |err| return err;
            if (file_errors.items.len > 0) return file_errors.items[0].err;
            return total;
        }

        const FileError = struct {
            path: []u8,
            err: anyerror,
        };

        fn fileErrorLessThan(_: void, lhs: FileError, rhs: FileError) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }

        const Worker = struct {
            /// Shared across workers. Only owns values that outlive the run:
            /// the queued path and any recorded file error.
            allocator: std.mem.Allocator,
            /// Private per-file scratch. Reading and JSON-parsing a fixture
            /// allocates heavily, and routing that through the shared allocator
            /// serialized every worker on its lock - twelve threads at one core
            /// of throughput. An arena touches the shared allocator only when it
            /// needs a fresh chunk.
            arena: std.heap.ArenaAllocator,
            options: Options,
            summary: Summary = .{},
            file_errors: std.ArrayList(FileError) = .empty,
            allocation_error: ?anyerror = null,

            fn deinit(self: *Worker) void {
                for (self.file_errors.items) |file_error| self.allocator.free(file_error.path);
                self.file_errors.deinit(self.allocator);
                self.arena.deinit();
            }

            fn run(self: *Worker, io: std.Io, queue: *std.Io.Queue([]u8)) std.Io.Cancelable!void {
                while (true) {
                    const path = queue.getOne(io) catch |err| switch (err) {
                        error.Closed => return,
                        error.Canceled => return error.Canceled,
                    };
                    // `Summary` is plain counters, so nothing survives the reset.
                    defer _ = self.arena.reset(.retain_capacity);
                    const summary = module.runFile(io, self.arena.allocator(), path, self.options) catch |err| {
                        self.file_errors.append(self.allocator, .{ .path = path, .err = err }) catch |alloc_err| {
                            if (self.allocation_error == null) self.allocation_error = alloc_err;
                            self.allocator.free(path);
                        };
                        continue;
                    };
                    self.summary.add(summary);
                    self.allocator.free(path);
                }
            }
        };
    };
}

test "jobs parser enforces the caller's memory bound" {
    try std.testing.expectEqual(@as(usize, 1), try parseJobs("1", 16));
    try std.testing.expectEqual(@as(usize, 16), try parseJobs("16", 16));
    try std.testing.expectError(error.InvalidJobs, parseJobs("0", 16));
    try std.testing.expectError(error.InvalidJobs, parseJobs("17", 16));
    try std.testing.expectEqual(@as(usize, 64), try parseJobs("64", 64));
    try std.testing.expectError(error.InvalidJobs, parseJobs("65", 64));
}
