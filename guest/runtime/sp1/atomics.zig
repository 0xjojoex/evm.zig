// SP1 executes one guest thread and RV64IM has no atomic instructions. Zig's
// compiler-rt atomics recurse into their own libcalls on this target, so the
// guest supplies the six 64-bit operations its execution code actually uses.

fn load8(src: *const u64, _: c_int) callconv(.c) u64 {
    return src.*;
}

fn store8(dst: *u64, value: u64, _: c_int) callconv(.c) void {
    dst.* = value;
}

fn exchange8(ptr: *u64, value: u64, _: c_int) callconv(.c) u64 {
    const old = ptr.*;
    ptr.* = value;
    return old;
}

fn compareExchange8(
    ptr: *u64,
    expected: *u64,
    desired: u64,
    _: c_int,
    _: c_int,
) callconv(.c) c_int {
    const old = ptr.*;
    if (old != expected.*) {
        expected.* = old;
        return 0;
    }
    ptr.* = desired;
    return 1;
}

fn fetchAdd8(ptr: *u64, value: u64, _: c_int) callconv(.c) u64 {
    const old = ptr.*;
    ptr.* +%= value;
    return old;
}

fn fetchOr8(ptr: *u64, value: u64, _: c_int) callconv(.c) u64 {
    const old = ptr.*;
    ptr.* |= value;
    return old;
}

comptime {
    @export(&load8, .{ .name = "__atomic_load_8" });
    @export(&store8, .{ .name = "__atomic_store_8" });
    @export(&exchange8, .{ .name = "__atomic_exchange_8" });
    @export(&compareExchange8, .{ .name = "__atomic_compare_exchange_8" });
    @export(&fetchAdd8, .{ .name = "__atomic_fetch_add_8" });
    @export(&fetchOr8, .{ .name = "__atomic_fetch_or_8" });
}
