const std = @import("std");

pub inline fn fromBytes32(bytes: *const [32]u8) u256 {
    return std.mem.readInt(u256, bytes, .big);
}

pub inline fn toBytes32(bytes: *[32]u8, value: u256) void {
    std.mem.writeInt(u256, bytes, value, .big);
}

pub inline fn sdiv(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const quotient = if (ia == std.math.minInt(i256) and ib == -1)
        ia
    else
        @divTrunc(ia, ib);
    return @bitCast(quotient);
}

pub inline fn smod(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const remainder = signedMagnitude(ia) % signedMagnitude(ib);
    const signed_remainder: i256 = @intCast(remainder);
    return @bitCast(if (ia < 0) -signed_remainder else signed_remainder);
}

pub inline fn div(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    if ((a | b) <= std.math.maxInt(u64)) {
        return @as(u64, @intCast(a)) / @as(u64, @intCast(b));
    }
    return a / b;
}

pub inline fn mod(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    if ((a | b) <= std.math.maxInt(u64)) {
        return @as(u64, @intCast(a)) % @as(u64, @intCast(b));
    }
    return a % b;
}

pub inline fn addMod(a: u256, b: u256, modulo: u256) u256 {
    if (modulo == 0) return 0;

    const lhs = if (a >= modulo) a % modulo else a;
    const rhs = if (b >= modulo) b % modulo else b;
    return addModReduced(lhs, rhs, modulo);
}

pub inline fn mulMod(lhs: u256, rhs: u256, modulo: u256) u256 {
    if (modulo == 0) return 0;

    const complement = 0 -% modulo;
    if (complement <= std.math.maxInt(u64)) {
        return mulModNearPowerOfTwo(lhs, rhs, modulo, @intCast(complement));
    }
    return mulModBigInt(lhs, rhs, modulo);
}

pub inline fn checkedAdd(a: u256, b: u256) ?u256 {
    return std.math.add(u256, a, b) catch null;
}

pub inline fn checkedMul(a: u256, b: u256) ?u256 {
    return std.math.mul(u256, a, b) catch null;
}

pub inline fn bitLength(value: u256) u16 {
    if (value == 0) return 0;
    return 256 - @clz(value);
}

pub inline fn ceilDiv(value: u256, denominator: u256) u256 {
    return @divFloor(value, denominator) + @intFromBool(value % denominator != 0);
}

inline fn signedMagnitude(value: i256) u256 {
    const bits: u256 = @bitCast(value);
    if (value >= 0) return @intCast(value);
    return ~bits +% 1;
}

inline fn addModGeneric(a: u256, b: u256, modulo: u256) u256 {
    return @intCast((@as(u512, a) + b) % modulo);
}

inline fn addModReduced(lhs: u256, rhs: u256, modulo: u256) u256 {
    const result, const overflow = @addWithOverflow(lhs, rhs);
    if (overflow == 0) {
        return if (result >= modulo) result - modulo else result;
    }
    return result + (0 -% modulo);
}

inline fn mulModGeneric(lhs: u256, rhs: u256, modulo: u256) u256 {
    return @intCast((@as(u512, lhs) * rhs) % modulo);
}

fn mulModBigInt(lhs: u256, rhs: u256, modulo: u256) u256 {
    const bigint = std.math.big.int;
    const word_limb_count = comptime bigint.calcTwosCompLimbCount(256);
    const product_limb_count = comptime word_limb_count * 2;

    var lhs_limbs: [word_limb_count]std.math.big.Limb = undefined;
    var rhs_limbs: [word_limb_count]std.math.big.Limb = undefined;
    var modulo_limbs: [word_limb_count]std.math.big.Limb = undefined;
    var product_limbs: [product_limb_count]std.math.big.Limb = undefined;
    var quotient_limbs: [product_limb_count]std.math.big.Limb = undefined;
    var remainder_limbs: [word_limb_count]std.math.big.Limb = undefined;
    var div_limbs: [bigint.calcDivLimbsBufferLen(product_limb_count, word_limb_count)]std.math.big.Limb = undefined;

    const left = bigint.Mutable.init(&lhs_limbs, lhs);
    const right = bigint.Mutable.init(&rhs_limbs, rhs);
    const divisor = bigint.Mutable.init(&modulo_limbs, modulo);
    var product = bigint.Mutable.init(&product_limbs, 0);
    var quotient = bigint.Mutable.init(&quotient_limbs, 0);
    var remainder = bigint.Mutable.init(&remainder_limbs, 0);

    product.mulNoAlias(left.toConst(), right.toConst(), null);
    quotient.divTrunc(&remainder, product.toConst(), divisor.toConst(), &div_limbs);
    return remainder.toInt(u256) catch unreachable;
}

inline fn mulModNearPowerOfTwo(lhs: u256, rhs: u256, modulo: u256, complement: u64) u256 {
    const product = @as(u512, lhs) * rhs;
    var reduced: u320 = @as(u320, @as(u256, @truncate(product))) +
        @as(u320, @as(u256, @truncate(product >> 256))) * complement;

    while ((reduced >> 256) != 0) {
        const carry: u64 = @intCast(reduced >> 256);
        reduced = @as(u320, @as(u256, @truncate(reduced))) + @as(u320, carry) * complement;
    }

    var result: u256 = @intCast(reduced);
    if (result >= modulo) {
        result -%= modulo;
    }
    return result;
}

test sdiv {
    const min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg_one: u256 = @bitCast(@as(i256, -1));

    try std.testing.expectEqual(@as(u256, 0), sdiv(1, 0));
    try std.testing.expectEqual(@as(u256, 3), sdiv(10, 3));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -3))), sdiv(@bitCast(@as(i256, -10)), 3));
    try std.testing.expectEqual(min_word, sdiv(min_word, neg_one));
}

test smod {
    try std.testing.expectEqual(@as(u256, 0), smod(1, 0));
    try std.testing.expectEqual(@as(u256, 1), smod(10, 3));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -1))), smod(@bitCast(@as(i256, -10)), 3));
}

test "unsigned div and mod use EVM zero semantics and match builtin arithmetic" {
    const max = std.math.maxInt(u256);
    const word_sized = @as(u256, 0x1_0000_0000);

    try std.testing.expectEqual(@as(u256, 0), div(1, 0));
    try std.testing.expectEqual(@as(u256, 0), mod(1, 0));
    try std.testing.expectEqual(@as(u256, 3), div(10, 3));
    try std.testing.expectEqual(@as(u256, 1), mod(10, 3));
    try std.testing.expectEqual(word_sized / 3, div(word_sized, 3));
    try std.testing.expectEqual(word_sized % 3, mod(word_sized, 3));
    try std.testing.expectEqual(max / (max - 1), div(max, max - 1));
    try std.testing.expectEqual(max % (max - 1), mod(max, max - 1));
}

test "bytes32 conversion uses Ethereum byte order" {
    var bytes = [_]u8{0} ** 32;
    bytes[31] = 1;
    try std.testing.expectEqual(@as(u256, 1), fromBytes32(&bytes));

    toBytes32(&bytes, 0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), bytes[30]);
    try std.testing.expectEqual(@as(u8, 0x34), bytes[31]);
}

test addMod {
    const max = std.math.maxInt(u256);

    try std.testing.expectEqual(@as(u256, 0), addMod(max, 1, 0));
    try std.testing.expectEqual(@as(u256, 1), addMod(max, 1, max));
    try std.testing.expectEqual(@as(u256, 2), addMod(3, 4, 5));
    try std.testing.expectEqual(addModGeneric(max, max, max - 58), addMod(max, max, max - 58));
}

test mulMod {
    const max = std.math.maxInt(u256);

    try std.testing.expectEqual(
        @as(u256, 0x4000000000000000000000000000000000000000000000000000000000000000),
        mulMod(std.math.pow(u256, 2, 255), std.math.pow(u256, 2, 255), max),
    );
    try std.testing.expectEqual(@as(u256, 0), mulMod(max, 1, max));
    try std.testing.expectEqual(@as(u256, 2), mulMod(3, 4, 5));
}

test "mulMod near power-of-two modulus matches full-width division" {
    const max = std.math.maxInt(u256);
    const cases = [_]struct {
        lhs: u256,
        rhs: u256,
        modulo: u256,
    }{
        .{
            .lhs = 0xfefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe,
            .rhs = 0x800000000000000000000000000000000000000000000000000000000000007f,
            .modulo = max - 128,
        },
        .{
            .lhs = max,
            .rhs = max,
            .modulo = max,
        },
        .{
            .lhs = max - 57,
            .rhs = 0x1000000000000000000000000000000000000000000000001,
            .modulo = max - 58,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            mulModGeneric(case.lhs, case.rhs, case.modulo),
            mulMod(case.lhs, case.rhs, case.modulo),
        );
    }
}

test "mulMod large modulus matches full-width division" {
    const cases = [_]struct {
        lhs: u256,
        rhs: u256,
        modulo: u256,
    }{
        .{
            .lhs = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef,
            .rhs = 0x123456789abcdef0fedcba9876543210123456789abcdef0fedcba9876543210,
            .modulo = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080,
        },
        .{
            .lhs = 0xffffffffffffffffffffffffffffffff00000000000000000000000000000001,
            .rhs = 0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789,
            .modulo = 0xf123456789abcdef00112233445566778899aabbccddeeff1020304050607080,
        },
        .{
            .lhs = 0x8000000000000000000000000000000000000000000000000000000000000000,
            .rhs = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            .modulo = 0x9000000000000000000000000000000000000000000000000000000000000001,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            mulModGeneric(case.lhs, case.rhs, case.modulo),
            mulMod(case.lhs, case.rhs, case.modulo),
        );
    }
}

test "modular arithmetic fuzzes optimized reducers against full-width oracle" {
    const Fuzz = struct {
        const zero_mod_seed = [_]u8{0x00} ++ [_]u8{0x11} ** 127;
        const tiny_mod_seed = [_]u8{0x01} ++ [_]u8{0x22} ** 127;
        const medium_mod_seed = [_]u8{0x02} ++ [_]u8{0x33} ** 127;
        const large_mod_seed = [_]u8{0x03} ++ [_]u8{0x44} ** 127;
        const near_mod_seed = [_]u8{0x04} ++ [_]u8{0xff} ** 127;

        const corpus = [_][]const u8{
            &zero_mod_seed,
            &tiny_mod_seed,
            &medium_mod_seed,
            &large_mod_seed,
            &near_mod_seed,
        };

        fn oracle(_: void, smith: *std.testing.Smith) anyerror!void {
            var shape_bytes: [1]u8 = undefined;
            smith.bytes(&shape_bytes);

            const lhs = smith.value(u256);
            const rhs = smith.value(u256);
            const modulo = switch (shape_bytes[0] % 5) {
                0 => 0,
                1 => @as(u256, 1) + smith.value(u8),
                2 => @as(u256, smith.value(u128)) | 1,
                3 => smith.value(u256) | (@as(u256, 1) << 192),
                4 => 0 -% @as(u256, 1 + (smith.value(u64) % 1024)),
                else => unreachable,
            };

            try std.testing.expectEqual(if (modulo == 0) 0 else addModGeneric(lhs, rhs, modulo), addMod(lhs, rhs, modulo));
            try std.testing.expectEqual(if (modulo == 0) 0 else mulModGeneric(lhs, rhs, modulo), mulMod(lhs, rhs, modulo));
        }
    };

    try std.testing.fuzz({}, Fuzz.oracle, .{ .corpus = &Fuzz.corpus });
}

test "checked arithmetic" {
    const max = std.math.maxInt(u256);

    try std.testing.expectEqual(@as(?u256, 2), checkedAdd(1, 1));
    try std.testing.expectEqual(@as(?u256, null), checkedAdd(max, 1));
    try std.testing.expectEqual(@as(?u256, 12), checkedMul(3, 4));
    try std.testing.expectEqual(@as(?u256, null), checkedMul(max, 2));
}

test bitLength {
    try std.testing.expectEqual(@as(u16, 0), bitLength(0));
    try std.testing.expectEqual(@as(u16, 1), bitLength(1));
    try std.testing.expectEqual(@as(u16, 8), bitLength(255));
    try std.testing.expectEqual(@as(u16, 9), bitLength(256));
    try std.testing.expectEqual(@as(u16, 256), bitLength(std.math.maxInt(u256)));
}

test ceilDiv {
    try std.testing.expectEqual(@as(u256, 0), ceilDiv(0, 8));
    try std.testing.expectEqual(@as(u256, 1), ceilDiv(1, 8));
    try std.testing.expectEqual(@as(u256, 1), ceilDiv(8, 8));
    try std.testing.expectEqual(@as(u256, 2), ceilDiv(9, 8));
}
