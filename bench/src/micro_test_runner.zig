const builtin = @import("builtin");
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (builtin.test_functions) |test_fn| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;
        std.testing.log_level = .warn;

        const result = test_fn.func();

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            leaked += 1;
        }

        if (result) |_| {
            passed += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                failed += 1;
                std.debug.print("micro test {s} failed: {t}\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    if (passed == 0 and skipped == 0 and failed == 0) {
        std.debug.print("No micro benchmarks matched.\n", .{});
        std.process.exit(1);
    }
    if (failed != 0 or leaked != 0) {
        std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked.\n", .{ passed, skipped, failed, leaked });
        std.process.exit(1);
    }
}
