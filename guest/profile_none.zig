pub const enabled = false;

pub inline fn begin(comptime _: @EnumLiteral()) void {}
pub inline fn end(comptime _: @EnumLiteral()) void {}
pub inline fn finish(comptime _: @EnumLiteral(), value: anytype) @TypeOf(value) {
    return value;
}
