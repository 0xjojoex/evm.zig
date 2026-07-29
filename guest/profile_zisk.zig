const builtin = @import("builtin");

pub const enabled = true;

const Command = enum(u8) {
    report_start_cost = 3,
    report_end_cost = 4,
    report_start_steps = 7,
    report_end_steps = 8,
};

const Name = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub inline fn begin(comptime tag: @EnumLiteral()) void {
    call(tag, .report_start_cost);
    call(tag, .report_start_steps);
}

pub inline fn end(comptime tag: @EnumLiteral()) void {
    call(tag, .report_end_steps);
    call(tag, .report_end_cost);
}

pub inline fn finish(comptime tag: @EnumLiteral(), value: anytype) @TypeOf(value) {
    end(tag);
    return value;
}

inline fn call(comptime tag: @EnumLiteral(), comptime command: Command) void {
    if (comptime builtin.cpu.arch != .riscv64) {
        @compileError("ZisK profile tags require a riscv64 guest target");
    }

    const name = @tagName(tag);
    var descriptor: Name = .{ .ptr = name.ptr, .len = name.len };
    asm volatile (
        \\csrs 0x81A, %[name]
        \\addi x0, x0, %[command]
        :
        : [name] "r" (&descriptor),
          [command] "i" (@intFromEnum(command)),
        : .{ .memory = true });
}
