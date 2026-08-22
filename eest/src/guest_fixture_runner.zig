//! Fixture-tree driver for the persistent zkVM guest command.
//!
//! The native state, block, and zkEVM adapters run under execution-specs. This
//! driver remains because each guest worker must retain its host process and
//! compiled ROM while it consumes many fixture files.

const std = @import("std");
const fixture_pool = @import("fixture_pool.zig");

/// `module` must expose `Options`, a default-constructible `Summary` with
/// `add`, and `runFile(io, allocator, path, options) !Summary`. A `limit`
/// field on `Options` stops the walk once `Summary.fixtures` reaches it.
///
/// A module may also declare `Context` with `init(io, options)` and `deinit`,
/// in which case `runFile` takes a trailing `*Context`. Every worker owns one,
/// so a context may hold state that cannot be shared across threads - a guest
/// host child process caching its ROM, for instance.
pub fn Runner(comptime module: type) type {
    return struct {
        const Options = module.Options;
        const Summary = module.Summary;
        const has_limit = @hasField(Options, "limit");
        const has_context = @hasDecl(module, "Context");
        const Context = if (has_context) module.Context else void;

        fn initContext(io: std.Io, options: Options) !Context {
            return if (has_context) try module.Context.init(io, options) else {};
        }

        fn deinitContext(context: *Context) void {
            if (has_context) context.deinit();
        }

        fn runFile(
            io: std.Io,
            allocator: std.mem.Allocator,
            path: []const u8,
            options: Options,
            context: *Context,
        ) !Summary {
            return if (has_context)
                module.runFile(io, allocator, path, options, context)
            else
                module.runFile(io, allocator, path, options);
        }

        /// Every root shares one set of contexts. A guest context owns a host
        /// child that converts the ELF to a ROM at startup, so recreating them
        /// per root would pay that cost once per corpus batch.
        pub fn run(
            io: std.Io,
            allocator: std.mem.Allocator,
            roots: []const []const u8,
            options: Options,
            jobs: usize,
        ) !Summary {
            return if (jobs == 1)
                sequential(io, allocator, roots, options)
            else
                concurrent(io, allocator, roots, options, jobs);
        }

        pub fn sequential(
            io: std.Io,
            allocator: std.mem.Allocator,
            roots: []const []const u8,
            options: Options,
        ) !Summary {
            var context = try initContext(io, options);
            defer deinitContext(&context);

            var total = Summary{};
            for (roots) |root| {
                total.add(try walk(io, allocator, root, options, &context));
                if (has_limit and options.limit > 0 and total.fixtures >= options.limit) break;
            }
            return total;
        }

        fn walk(
            io: std.Io,
            allocator: std.mem.Allocator,
            path: []const u8,
            options: Options,
            context: *Context,
        ) !Summary {
            var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
                error.NotDir => return runFile(io, allocator, path, options, context),
                else => return err,
            };
            defer dir.close(io);

            var total = Summary{};
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                defer allocator.free(child);
                switch (entry.kind) {
                    .directory => total.add(try walk(io, allocator, child, options, context)),
                    .file => if (std.mem.endsWith(u8, entry.name, ".json")) {
                        total.add(try runFile(io, allocator, child, options, context));
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
            roots: []const []const u8,
            options: Options,
            jobs: usize,
        ) !Summary {
            const workers = try allocator.alloc(Worker, jobs);
            var started: usize = 0;
            defer {
                for (workers[0..started]) |*worker| worker.deinit();
                allocator.free(workers);
            }
            while (started < jobs) : (started += 1) {
                workers[started] = .{
                    .allocator = allocator,
                    .arena = .init(allocator),
                    .options = options,
                    .context = try initContext(io, options),
                };
            }
            try fixture_pool.runWorkers(io, allocator, roots, workers, .{ .suffix = ".json" }, Worker.run);

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
            /// Private per-worker executor state. Never shared: a guest host is
            /// one child process behind one pipe pair.
            context: Context,
            summary: Summary = .{},
            file_errors: std.ArrayList(FileError) = .empty,
            allocation_error: ?anyerror = null,

            fn deinit(self: *Worker) void {
                deinitContext(&self.context);
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
                    const summary = runFile(io, self.arena.allocator(), path, self.options, &self.context) catch |err| {
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
