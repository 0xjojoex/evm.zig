const std = @import("std");

const queue_capacity = 64;

pub const FileMatch = union(enum) {
    basename: []const u8,
    suffix: []const u8,

    fn matches(self: FileMatch, name: []const u8) bool {
        return switch (self) {
            .basename => |expected| std.mem.eql(u8, name, expected),
            .suffix => |expected| std.mem.endsWith(u8, name, expected),
        };
    }
};

pub fn runWorkers(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    workers: anytype,
    file_match: FileMatch,
    comptime workerFn: anytype,
) !void {
    var queue_buffer: [queue_capacity][]u8 = undefined;
    var queue: std.Io.Queue([]u8) = .init(&queue_buffer);
    var producer = Producer{
        .io = io,
        .allocator = allocator,
        .queue = &queue,
        .path = path,
        .file_match = file_match,
    };
    var producer_group: std.Io.Group = .init;
    defer producer_group.cancel(io);
    try producer_group.concurrent(io, Producer.run, .{&producer});

    var worker_group: std.Io.Group = .init;
    defer worker_group.cancel(io);
    for (workers) |*worker| {
        worker_group.async(io, workerFn, .{ worker, io, &queue });
    }

    worker_group.await(io) catch |err| {
        producer_group.cancel(io);
        drainQueue(io, allocator, &queue);
        return err;
    };
    try producer_group.await(io);
    if (producer.err) |err| return err;
}

const Producer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    queue: *std.Io.Queue([]u8),
    path: []const u8,
    file_match: FileMatch,
    err: ?anyerror = null,

    fn run(self: *Producer) std.Io.Cancelable!void {
        defer self.queue.close(self.io);
        enqueuePath(self.io, self.allocator, self.queue, self.path, self.file_match) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.err = err;
        };
    }
};

fn enqueuePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    queue: *std.Io.Queue([]u8),
    path: []const u8,
    file_match: FileMatch,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer allocator.free(child);
                try enqueuePath(io, allocator, queue, child, file_match);
            },
            .file => {
                if (file_match.matches(entry.name)) {
                    queue.putOne(io, child) catch |err| {
                        allocator.free(child);
                        return err;
                    };
                } else {
                    allocator.free(child);
                }
            },
            else => allocator.free(child),
        }
    }
}

fn drainQueue(io: std.Io, allocator: std.mem.Allocator, queue: *std.Io.Queue([]u8)) void {
    while (queue.getOneUncancelable(io)) |path| {
        allocator.free(path);
    } else |err| switch (err) {
        error.Closed => {},
    }
}

test "fixture file matching supports exact names and suffixes" {
    try std.testing.expect((FileMatch{ .basename = "serialized.ssz_snappy" }).matches("serialized.ssz_snappy"));
    try std.testing.expect(!(FileMatch{ .basename = "serialized.ssz_snappy" }).matches("other.ssz_snappy"));
    try std.testing.expect((FileMatch{ .suffix = ".json" }).matches("fixture.json"));
    try std.testing.expect(!(FileMatch{ .suffix = ".json" }).matches("fixture.yaml"));
}
