//! Big-endian modular exponentiation shared by the precompile backends.
//!
//! Pure Zig with no backend or C dependencies so it can be exercised as a
//! standalone builtin-fuzzer target (`zig build fuzz`).

const std = @import("std");

pub fn into(allocator: std.mem.Allocator, output: []u8, base_bytes: []const u8, exponent_bytes: []const u8, modulus_bytes: []const u8) std.mem.Allocator.Error!void {
    if (modexpSmallInto(output, base_bytes, exponent_bytes, modulus_bytes)) return;
    try modexpBigIntInto(allocator, output, base_bytes, exponent_bytes, modulus_bytes);
}

fn modexpBigIntInto(allocator: std.mem.Allocator, output: []u8, base_bytes: []const u8, exponent_bytes: []const u8, modulus_bytes: []const u8) std.mem.Allocator.Error!void {
    const BigInt = std.math.big.int.Managed;
    var modulus = try managedFromBytes(allocator, modulus_bytes);
    defer modulus.deinit();

    var base = try managedFromBytes(allocator, base_bytes);
    defer base.deinit();
    try reduceManaged(&base, &modulus);

    var result = try BigInt.initSet(allocator, 1);
    defer result.deinit();
    try reduceManaged(&result, &modulus);

    var product = try BigInt.init(allocator);
    defer product.deinit();
    var quotient = try BigInt.init(allocator);
    defer quotient.deinit();
    var remainder = try BigInt.init(allocator);
    defer remainder.deinit();

    // Bits above the exponent's leading set bit contribute nothing: they
    // square-and-reduce a result that is still 1. Start at the first set
    // bit with result = base (mod modulus) instead.
    var started = false;
    for (exponent_bytes) |byte| {
        if (!started and byte == 0) continue;
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            if (started) {
                try mulMod(&result, &result, &result, &modulus, &product, &quotient, &remainder);
            }
            if (byte & mask != 0) {
                if (started) {
                    try mulMod(&result, &result, &base, &modulus, &product, &quotient, &remainder);
                } else {
                    try result.copy(base.toConst());
                    started = true;
                }
            }
        }
    }

    result.toConst().writeTwosComplement(output, .big);
}

/// Fast modexp for moduli and bases of at most 32 significant bytes.
///
/// Odd moduli use Montgomery multiplication; even moduli split into an odd
/// part and a power of two, then recombine with the CRT. Widths specialize
/// to the smallest of u64/u128/u256 that holds the modulus, since the
/// per-bit cost of the double-width multiply dominates the whole call.
/// Returns false when the inputs need the arbitrary-precision path.
fn modexpSmallInto(output: []u8, base_bytes: []const u8, exponent_bytes: []const u8, modulus_bytes: []const u8) bool {
    const sig_mod = stripLeadingZeroBytes(modulus_bytes);
    const sig_base = stripLeadingZeroBytes(base_bytes);
    if (sig_mod.len == 0 or sig_mod.len > 32 or sig_base.len > 32) return false;

    const base_word = readWordBytes(u256, sig_base);
    const result: u256 = if (sig_mod.len <= 8)
        modexpWords(u64, readWordBytes(u64, sig_mod), base_word, exponent_bytes)
    else if (sig_mod.len <= 16)
        modexpWords(u128, readWordBytes(u128, sig_mod), base_word, exponent_bytes)
    else
        modexpWords(u256, readWordBytes(u256, sig_mod), base_word, exponent_bytes);

    var word: [32]u8 = undefined;
    std.mem.writeInt(u256, &word, result, .big);
    // Output is modulus-length and pre-zeroed by the caller; the result is
    // right-aligned and always fits its significant modulus bytes.
    const copy_len = @min(output.len, word.len);
    @memcpy(output[output.len - copy_len ..], word[word.len - copy_len ..]);
    return true;
}

fn stripLeadingZeroBytes(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) start += 1;
    return bytes[start..];
}

/// Read up to @sizeOf(T) big-endian bytes into T.
fn readWordBytes(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    return value;
}

fn DoubleWidth(comptime T: type) type {
    return std.meta.Int(.unsigned, @typeInfo(T).int.bits * 2);
}

fn modexpWords(comptime T: type, modulus: T, base: u256, exponent_bytes: []const u8) T {
    std.debug.assert(modulus != 0);
    const shift = @ctz(modulus);
    const odd = modulus >> @intCast(shift);
    if (odd == 1) {
        // Power-of-two modulus: masked square-and-multiply only.
        const mask = modulus - 1;
        return powMod2k(T, @truncate(base & mask), exponent_bytes, mask);
    }
    const odd_result = montPow(T, reduceU256(T, base, odd), exponent_bytes, odd);
    if (shift == 0) return odd_result;

    // CRT recombination for modulus = odd << shift.
    const mask: T = (@as(T, 1) << @intCast(shift)) - 1;
    const pow2_result = powMod2k(T, @truncate(base & mask), exponent_bytes, mask);
    const pow2_mod_odd = pow2_result % odd;
    // odd fits in bits-shift bits with shift >= 1 here, so odd_result + odd
    // cannot overflow T.
    const diff = if (odd_result >= pow2_mod_odd)
        odd_result - pow2_mod_odd
    else
        odd_result + odd - pow2_mod_odd;
    // Multiply by 2^-shift (mod odd) via repeated exact halving.
    const half_step = (odd >> 1) + 1; // (odd + 1) / 2 without overflow
    var h = diff;
    for (0..shift) |_| {
        h = (h >> 1) + (if (h & 1 != 0) half_step else 0);
    }
    return pow2_result + (h << @intCast(shift));
}

fn powMod2k(comptime T: type, base: T, exponent_bytes: []const u8, mask: T) T {
    var result: T = 1 & mask;
    var started = false;
    for (exponent_bytes) |byte| {
        if (!started and byte == 0) continue;
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if (started) result = (result *% result) & mask;
            if (byte & bit != 0) {
                if (started) {
                    result = (result *% base) & mask;
                } else {
                    result = base & mask;
                    started = true;
                }
            }
        }
    }
    return result;
}

/// Reduce a full-width value into T modulo an odd modulus, bit by bit.
fn reduceU256(comptime T: type, value: u256, modulus: T) T {
    if (@typeInfo(T).int.bits == 256) {
        if (value < modulus) return value;
    } else if (value <= std.math.maxInt(T)) {
        const narrowed: T = @intCast(value);
        if (narrowed < modulus) return narrowed;
    }
    const D = DoubleWidth(T);
    var remainder: T = 0;
    var index: u9 = 256;
    while (index != 0) {
        index -= 1;
        const bit: u1 = @truncate(value >> @intCast(index));
        var widened = (@as(D, remainder) << 1) | bit;
        if (widened >= modulus) widened -= modulus;
        remainder = @intCast(widened);
    }
    return remainder;
}

fn montPow(comptime T: type, base: T, exponent_bytes: []const u8, modulus: T) T {
    const bits = @typeInfo(T).int.bits;
    std.debug.assert(modulus & 1 == 1);
    if (modulus == 1) return 0;

    // -modulus^-1 mod 2^bits via Newton iteration.
    var inverse: T = 1;
    for (0..8) |_| inverse *%= 2 -% modulus *% inverse;
    const neg_inverse = 0 -% inverse;

    // R^2 mod modulus by doubling, R = 2^bits.
    var r2: T = 1;
    for (0..2 * bits) |_| {
        var widened = @as(DoubleWidth(T), r2) << 1;
        if (widened >= modulus) widened -= modulus;
        r2 = @intCast(widened);
    }

    const base_mont = montMul(T, base, r2, modulus, neg_inverse);
    var result_mont = montMul(T, 1, r2, modulus, neg_inverse);
    var started = false;
    for (exponent_bytes) |byte| {
        if (!started and byte == 0) continue;
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if (started) result_mont = montMul(T, result_mont, result_mont, modulus, neg_inverse);
            if (byte & bit != 0) {
                if (started) {
                    result_mont = montMul(T, result_mont, base_mont, modulus, neg_inverse);
                } else {
                    result_mont = base_mont;
                    started = true;
                }
            }
        }
    }
    return montMul(T, result_mont, 1, modulus, neg_inverse);
}

fn montMul(comptime T: type, a: T, b: T, modulus: T, neg_inverse: T) T {
    const D = DoubleWidth(T);
    const bits = @typeInfo(T).int.bits;
    const product = @as(D, a) * b;
    const product_low: T = @truncate(product);
    const factor = product_low *% neg_inverse;
    const factor_modulus = @as(D, factor) * modulus;
    // product + factor*modulus ≡ 0 mod 2^bits, so the low halves sum to
    // exactly 0 or 2^bits; the latter iff the product's low half is nonzero.
    const carry: D = @intFromBool(product_low != 0);
    var reduced = (product >> bits) + (factor_modulus >> bits) + carry;
    if (reduced >= modulus) reduced -= modulus;
    return @intCast(reduced);
}

fn managedFromBytes(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!std.math.big.int.Managed {
    var value = try std.math.big.int.Managed.init(allocator);
    errdefer value.deinit();
    try value.ensureTwosCompCapacity(8 * bytes.len);
    var mutable = value.toMutable();
    mutable.readTwosComplement(bytes, 8 * bytes.len, .big, .unsigned);
    value.setMetadata(mutable.positive, mutable.len);
    return value;
}

fn reduceManaged(value: *std.math.big.int.Managed, modulus: *const std.math.big.int.Managed) std.mem.Allocator.Error!void {
    var quotient = try std.math.big.int.Managed.init(value.allocator);
    defer quotient.deinit();
    var remainder = try std.math.big.int.Managed.init(value.allocator);
    defer remainder.deinit();
    try std.math.big.int.Managed.divTrunc(&quotient, &remainder, value, modulus);
    value.swap(&remainder);
}

fn mulMod(
    target: *std.math.big.int.Managed,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    modulus: *const std.math.big.int.Managed,
    product: *std.math.big.int.Managed,
    quotient: *std.math.big.int.Managed,
    remainder: *std.math.big.int.Managed,
) std.mem.Allocator.Error!void {
    try std.math.big.int.Managed.mul(product, a, b);
    try std.math.big.int.Managed.divTrunc(quotient, remainder, product, modulus);
    target.swap(remainder);
}

test "modexp small-modulus fast path matches big-int path" {
    const Fuzz = struct {
        // Seed the corpus with the shapes the oracle biases toward so the
        // default (non-fuzzing) test runner still exercises them: large
        // operands, even moduli, powers of two, and tiny exponents.
        const corpus = [_][]const u8{
            &[_]u8{0} ** 4,
            &[_]u8{0xff} ** 48,
            &[_]u8{ 0x01, 0x21, 0x21, 0x11, 0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x03 },
            &[_]u8{ 0x02, 0x08, 0x02, 0x04, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xff, 0xfe },
            &[_]u8{ 0x03, 0x10, 0x30, 0x20, 0x00, 0x01, 0x00, 0x80 },
        };

        fn oracle(_: void, smith: *std.testing.Smith) anyerror!void {
            const allocator = std.testing.allocator;
            var base_buf: [40]u8 = undefined;
            var exponent_buf: [48]u8 = undefined;
            var modulus_buf: [40]u8 = undefined;
            var fast_out: [40]u8 = undefined;
            var slow_out: [40]u8 = undefined;

            const shape = smith.value(u8);
            const base_len: usize = smith.value(u8) % 34;
            const exponent_len: usize = smith.value(u8) % (exponent_buf.len + 1);
            const modulus_len: usize = 1 + @as(usize, smith.value(u8) % 33);

            const base = base_buf[0..base_len];
            const exponent = exponent_buf[0..exponent_len];
            const modulus = modulus_buf[0..modulus_len];
            smith.bytes(base);
            smith.bytes(exponent);
            smith.bytes(modulus);

            // Bias toward interesting shapes: leading zeros, even moduli,
            // powers of two, and tiny exponents.
            switch (shape % 4) {
                0 => if (base_len != 0) @memset(base[0 .. base_len / 2], 0),
                1 => if (exponent_len != 0) @memset(exponent[0 .. exponent_len / 2], 0),
                2 => modulus[modulus_len - 1] &= 0xfe,
                3 => {
                    @memset(modulus, 0);
                    modulus[shape % modulus_len] = @as(u8, 1) << @as(u3, @truncate(shape >> 4));
                },
                else => unreachable,
            }
            if (std.mem.allEqual(u8, modulus, 0)) modulus[modulus_len - 1] = 1;

            const fast = fast_out[0..modulus_len];
            const slow = slow_out[0..modulus_len];
            @memset(fast, 0);
            @memset(slow, 0);
            if (!modexpSmallInto(fast, base, exponent, modulus)) {
                // The fast path only declines oversized significant operands.
                try std.testing.expect(stripLeadingZeroBytes(base).len > 32 or
                    stripLeadingZeroBytes(modulus).len > 32);
                return;
            }
            try modexpBigIntInto(allocator, slow, base, exponent, modulus);
            try std.testing.expectEqualSlices(u8, slow, fast);
        }
    };

    try std.testing.fuzz({}, Fuzz.oracle, .{ .corpus = &Fuzz.corpus });
}
