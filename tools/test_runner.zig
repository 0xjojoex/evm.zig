//! Custom test runner (structure after Karl's version).
//!
//! Filters at RUNTIME so the compiled binary stays cached across filter
//! changes — compile-time pruning belongs to `-Dtest-forks` / `-Dtest-filter`.
//!
//! Environment:
//!   TEST_FILTER=<substring>   run only matching tests (no recompile)
//!   TEST_VERBOSE=true         one line per test with duration
//!   TEST_FAIL_FIRST=true      stop at the first failure

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const border = "=" ** 60;

// Named by the panic handler so a crash points at the running test.
var current_test: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    std.testing.io_instance = .init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer std.testing.io_instance.deinit();
    const io = std.testing.io_instance.io();

    const env_map = init.environ_map;
    const filter = env_map.get("TEST_FILTER");
    const verbose = envBool(env_map, "TEST_VERBOSE");
    const fail_first = envBool(env_map, "TEST_FAIL_FIRST");

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;
    var filtered: usize = 0;
    var timings: std.ArrayList(TestInfo) = .empty;
    defer timings.deinit(gpa);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(gpa);
    // `zig build test -- <substring>` lands here as argv; like TEST_FILTER it
    // only affects this run, never the compiled binary.
    var argv_filters: std.ArrayList([]const u8) = .empty;
    defer argv_filters.deinit(gpa);
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip();
    while (arg_it.next()) |arg| try argv_filters.append(gpa, arg);

    for (builtin.test_functions) |t| {
        const unnamed = std.mem.endsWith(u8, t.name, ".test_0") or std.mem.eql(u8, t.name, "test_0");
        const name = friendlyName(t.name);
        if (!unnamed and !matchesFilters(t.name, filter, argv_filters.items)) {
            filtered += 1;
            continue;
        }

        current_test = name;
        std.testing.allocator_instance = .{};
        const start = Io.Clock.awake.now(io);
        const result = t.func();
        const ns: u64 = @intCast(start.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
        current_test = null;

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            print(.fail, "\n{s}\n\"{s}\" - memory leak\n{s}\n", .{ border, name, border });
        }
        if (unnamed) continue;
        try timings.append(gpa, .{ .ns = ns, .name = name });

        if (result) |_| {
            pass += 1;
            if (verbose) {
                print(.pass, "{s} ({d:.2}ms)\n", .{ name, msFloat(ns) });
            } else print(.pass, ".", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                if (verbose) print(.skip, "{s} (skip)\n", .{name}) else print(.skip, "_", .{});
            },
            else => {
                fail += 1;
                try failed.append(gpa, name);
                print(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ border, name, @errorName(err), border });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                if (fail_first) break;
            },
        }
    }

    print(if (fail == 0) .pass else .fail, "\n{d} of {d} tests passed", .{ pass, pass + fail });
    if (skip > 0) print(.skip, ", {d} skipped (fork-gated tests skip under narrowed -Dtest-forks presets)", .{skip});
    if (filtered > 0) print(.skip, ", {d} filtered out", .{filtered});
    if (leak > 0) print(.fail, ", {d} leaked", .{leak});
    print(.text, "\n", .{});

    if (timings.items.len > 1) {
        std.mem.sort(TestInfo, timings.items, {}, slower);
        print(.text, "slowest:\n", .{});
        for (timings.items[0..@min(5, timings.items.len)]) |info| {
            print(.text, "  {d:.2}ms\t{s}\n", .{ msFloat(info.ns), info.name });
        }
    }
    for (failed.items) |name| print(.fail, "failed: {s}\n", .{name});

    std.process.exit(if (fail == 0 and leak == 0) 0 else 1);
}

fn matchesFilters(name: []const u8, env_filter: ?[]const u8, argv_filters: []const []const u8) bool {
    if (env_filter == null and argv_filters.len == 0) return true;
    if (env_filter) |f| if (std.mem.indexOf(u8, name, f) != null) return true;
    for (argv_filters) |f| if (std.mem.indexOf(u8, name, f) != null) return true;
    return false;
}

const TestInfo = struct {
    ns: u64,
    name: []const u8,
};

fn slower(_: void, a: TestInfo, b: TestInfo) bool {
    return a.ns > b.ns;
}

fn msFloat(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn friendlyName(name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }
    return name;
}

fn envBool(map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = map.get(key) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

const Status = enum { pass, fail, skip, text };

fn print(status: Status, comptime format: []const u8, args: anytype) void {
    switch (status) {
        .pass => std.debug.print("\x1b[32m", .{}),
        .fail => std.debug.print("\x1b[31m", .{}),
        .skip => std.debug.print("\x1b[33m", .{}),
        .text => {},
    }
    std.debug.print(format ++ "\x1b[0m", args);
}

/// `std.testing.fuzz` delegates here. The `fuzz` build steps keep the default
/// runner, so real fuzz mode never reaches this one; mirror the default
/// runner's non-fuzz path and smoke-run the corpus plus an empty input.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: std.testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |name| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\x1b[0m\n", .{ border, name });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);
