const std = @import("std");

pub fn main() void {
    const W = Wrap(.ok);
    std.debug.print("wr: {any}\n", .{W.status});
    var w = W.init();

    w.add();

    // add_outside(W, &w);

    std.debug.print("wr: {any}\n", .{w.pc});
}

const Status = enum { ok, no_ok };

fn Wrap(comptime status_: Status) type {
    return struct {
        const Self = @This();
        pub const status = status_;
        pc: usize = 0,

        pub fn init() Self {
            return .{
                .pc = 0,
            };
        }

        pub fn add(self: *Self) void {
            self.pc += 1;
            std.debug.print("{any}\n", .{self.pc});
        }
    };
}

fn add_outside(status: Status, ip: Wrap(status)) void {
    // std.debug.print("typeof {any}\n", .{@TypeOf(T)});
    ip.pc += 1;

    std.debug.print("{any}\n", .{ip.pc});
}

pub fn Instructions(comptime status: Status) type {
    const Interpreter = Wrap(status);
    return struct {
        const Self = @This();
        pub fn add(ip: *Interpreter) !void {
            // const a = try ip.stack.pop();
            _ = ip;
            std.debug.print("ADD\n", .{});
        }
    };
}
