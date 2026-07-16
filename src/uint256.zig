//! 256-bit unsigned integer helpers for EVM word arithmetic and byte conversion.

const std = @import("std");

const use_limb_div_mod = true;

pub inline fn fromBytes32(bytes: *const [32]u8) u256 {
    return std.mem.readInt(u256, bytes, .big);
}

pub inline fn toBytes32(value: u256) [32]u8 {
    var bytes: [32]u8 = undefined;
    writeBytes32(&bytes, value);
    return bytes;
}

pub inline fn writeBytes32(bytes: *[32]u8, value: u256) void {
    std.mem.writeInt(u256, bytes, value, .big);
}

pub inline fn sdiv(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const quotient = div(signedMagnitude(ia), signedMagnitude(ib));
    return if ((ia < 0) != (ib < 0)) 0 -% quotient else quotient;
}

pub inline fn smod(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const remainder = mod(signedMagnitude(ia), signedMagnitude(ib));
    return if (ia < 0) 0 -% remainder else remainder;
}

pub inline fn div(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    if ((a | b) <= std.math.maxInt(u64)) {
        return @as(u64, @truncate(a)) / @as(u64, @truncate(b));
    }
    if (!use_limb_div_mod) return a / b;
    return divKnuth(a, b);
}

pub inline fn mod(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    if ((a | b) <= std.math.maxInt(u64)) {
        return @as(u64, @truncate(a)) % @as(u64, @truncate(b));
    }
    if (!use_limb_div_mod) return a % b;
    return modKnuth(a, b);
}

pub inline fn addMod(a: u256, b: u256, modulo: u256) u256 {
    if (modulo == 0) return 0;

    const lhs = if (a >= modulo) mod(a, modulo) else a;
    const rhs = if (b >= modulo) mod(b, modulo) else b;
    return addModReduced(lhs, rhs, modulo);
}

pub inline fn mulMod(lhs: u256, rhs: u256, modulo: u256) u256 {
    if (modulo == 0) return 0;

    const complement = 0 -% modulo;
    if (complement <= std.math.maxInt(u64)) {
        return mulModNearPowerOfTwo(lhs, rhs, modulo, @intCast(complement));
    }
    return mulModKnuth(lhs, rhs, modulo);
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

/// Left shift via a u128 limb funnel. LLVM lowers a variable-amount u256 `<<`
/// to ~2KB of generic wide-shift code (4x fatter than `>>`); this form stays
/// compact enough to inline into interpreter opcode handlers.
pub fn shl(value: u256, shift: u8) u256 {
    const lo: u128 = @truncate(value);
    if (shift >= 128) {
        // shift - 128 == the low 7 bits of shift when bit 7 is set.
        const upper = lo << @as(u7, @truncate(shift));
        return @as(u256, upper) << 128;
    }
    if (shift == 0) return value;
    const s: u7 = @intCast(shift);
    const hi: u128 = @intCast(value >> 128);
    const carry = lo >> @as(u7, @intCast(128 - @as(u8, s)));
    return (@as(u256, (hi << s) | carry) << 128) | (lo << s);
}

test shl {
    const patterns = [_]u256{
        0,
        1,
        std.math.maxInt(u256),
        std.math.maxInt(u128),
        @as(u256, std.math.maxInt(u128)) << 128,
        0x0123_4567_89ab_cdef_0123_4567_89ab_cdef_0123_4567_89ab_cdef_0123_4567_89ab_cdef,
        @as(u256, 1) << 127,
        @as(u256, 1) << 255,
    };
    for (patterns) |value| {
        for (0..256) |shift_usize| {
            const shift: u8 = @intCast(shift_usize);
            try std.testing.expectEqual(value << shift, shl(value, shift));
        }
    }
}

inline fn signedMagnitude(value: i256) u256 {
    const bits: u256 = @bitCast(value);
    if (value >= 0) return @intCast(value);
    return ~bits +% 1;
}

inline fn sdivGeneric(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const quotient = if (ia == std.math.minInt(i256) and ib == -1)
        ia
    else
        @divTrunc(ia, ib);
    return @bitCast(quotient);
}

inline fn smodGeneric(a: u256, b: u256) u256 {
    if (b == 0) return 0;

    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const remainder = signedMagnitude(ia) % signedMagnitude(ib);
    const signed_remainder: i256 = @intCast(remainder);
    return @bitCast(if (ia < 0) -signed_remainder else signed_remainder);
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

const Word4 = [4]u64;
const Word5 = [5]u64;
const Word8 = [8]u64;
const Word9 = [9]u64;

inline fn toLimbs(out: *Word4, value: u256) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 64);
    out[2] = @truncate(value >> 128);
    out[3] = @truncate(value >> 192);
}

inline fn fromLimbs(limbs: Word4) u256 {
    return @as(u256, limbs[0]) |
        (@as(u256, limbs[1]) << 64) |
        (@as(u256, limbs[2]) << 128) |
        (@as(u256, limbs[3]) << 192);
}

inline fn fromLimbsPtr(limbs: *const Word4) u256 {
    return @as(u256, limbs[0]) |
        (@as(u256, limbs[1]) << 64) |
        (@as(u256, limbs[2]) << 128) |
        (@as(u256, limbs[3]) << 192);
}

inline fn clearLimbs(comptime N: usize, out: *[N]u64) void {
    inline for (0..N) |i| out[i] = 0;
}

fn countLimbs(comptime N: usize, limbs: *const [N]u64) usize {
    var n = N;
    while (n > 0 and limbs[n - 1] == 0) n -= 1;
    return n;
}

fn ltPrefix(comptime N: usize, a: *const [N]u64, a_len: usize, b: *const Word4, b_len: usize) bool {
    if (a_len != b_len) return a_len < b_len;
    var i = a_len;
    while (i != 0) {
        i -= 1;
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
}

fn mulFull4(out: *Word8, lhs: *const Word4, rhs: *const Word4) void {
    clearLimbs(8, out);

    inline for (0..4) |i| {
        var carry: u128 = 0;
        inline for (0..4) |j| {
            const index = i + j;
            const sum = @as(u128, out[index]) + @as(u128, lhs[i]) * @as(u128, rhs[j]) + carry;
            out[index] = @truncate(sum);
            carry = sum >> 64;
        }

        var index = i + 4;
        while (carry != 0) : (index += 1) {
            const sum = @as(u128, out[index]) + carry;
            out[index] = @truncate(sum);
            carry = sum >> 64;
        }
    }
}

fn div128by64(n_hi: u64, n_lo: u64, denominator: u64) struct { q: u64, r: u64 } {
    const base: u64 = 1 << 32;
    const shift: u6 = @intCast(@clz(denominator));
    const v = denominator << shift;
    const vn1 = v >> 32;
    const vn0 = v & 0xffff_ffff;

    const un32 = if (shift > 0)
        (n_hi << shift) | (n_lo >> @intCast(@as(u7, 64) - shift))
    else
        n_hi;
    const un10 = n_lo << shift;
    const un1 = un10 >> 32;
    const un0 = un10 & 0xffff_ffff;

    var q1 = un32 / vn1;
    var rhat = un32 % vn1;

    while (q1 >= base or q1 * vn0 > (rhat << 32) + un1) {
        q1 -= 1;
        rhat += vn1;
        if (rhat >= base) break;
    }

    const un21 = un32 *% base +% un1 -% q1 *% v;

    var q0 = un21 / vn1;
    rhat = un21 % vn1;

    while (q0 >= base or q0 * vn0 > (rhat << 32) + un0) {
        q0 -= 1;
        rhat += vn1;
        if (rhat >= base) break;
    }

    return .{
        .q = q1 * base + q0,
        .r = (un21 *% base +% un0 -% q0 *% v) >> shift,
    };
}

fn mulSubAt(u: *Word9, divisor: *const Word4, divisor_len: usize, offset: usize, qhat: u64) bool {
    var carry: u128 = 0;
    var borrow: u128 = 0;

    for (0..divisor_len) |i| {
        const product = @as(u128, qhat) * @as(u128, divisor[i]) + carry;
        carry = product >> 64;

        const rhs = @as(u128, @as(u64, @truncate(product))) + borrow;
        const lhs = @as(u128, u[offset + i]);
        if (lhs >= rhs) {
            u[offset + i] = @truncate(lhs - rhs);
            borrow = 0;
        } else {
            u[offset + i] = @truncate((@as(u128, 1) << 64) + lhs - rhs);
            borrow = 1;
        }
    }

    const high_rhs = carry + borrow;
    const high_lhs = @as(u128, u[offset + divisor_len]);
    if (high_lhs >= high_rhs) {
        u[offset + divisor_len] = @truncate(high_lhs - high_rhs);
        return false;
    }

    u[offset + divisor_len] = @truncate((@as(u128, 1) << 64) + high_lhs - high_rhs);
    return true;
}

fn addBackAt(u: *Word9, divisor: *const Word4, divisor_len: usize, offset: usize) void {
    var carry: u128 = 0;
    for (0..divisor_len) |i| {
        const sum = @as(u128, u[offset + i]) + @as(u128, divisor[i]) + carry;
        u[offset + i] = @truncate(sum);
        carry = sum >> 64;
    }
    u[offset + divisor_len] +%= @truncate(carry);
}

fn modNxMKnuth(out: *Word4, numerator: *const Word8, modulo: *const Word4, numerator_len: usize, divisor_len: usize) void {
    var divisor: Word4 = undefined;
    var u: Word9 = undefined;

    const shift: u6 = @intCast(@clz(modulo[divisor_len - 1]));
    if (shift == 0) {
        inline for (0..4) |i| {
            if (i < divisor_len) divisor[i] = modulo[i];
        }
        inline for (0..8) |i| {
            if (i < numerator_len) {
                u[i] = numerator[i];
            } else {
                u[i] = 0;
            }
        }
        u[8] = 0;
    } else {
        const rshift: u6 = @intCast(@as(u7, 64) - shift);
        divisor[0] = modulo[0] << shift;
        var i: usize = 1;
        while (i < divisor_len) : (i += 1) {
            divisor[i] = (modulo[i] << shift) | (modulo[i - 1] >> rshift);
        }

        u[0] = numerator[0] << shift;
        i = 1;
        while (i < numerator_len) : (i += 1) {
            u[i] = (numerator[i] << shift) | (numerator[i - 1] >> rshift);
        }
        u[numerator_len] = numerator[numerator_len - 1] >> rshift;
    }

    var offset = numerator_len - divisor_len + 1;
    while (offset != 0) {
        offset -= 1;

        var qhat: u64 = undefined;
        var rhat: u64 = undefined;
        var rhat_overflow = false;
        if (u[offset + divisor_len] == divisor[divisor_len - 1]) {
            qhat = std.math.maxInt(u64);
            const add = @addWithOverflow(u[offset + divisor_len - 1], divisor[divisor_len - 1]);
            rhat = add[0];
            rhat_overflow = add[1] != 0;
        } else {
            const trial = div128by64(u[offset + divisor_len], u[offset + divisor_len - 1], divisor[divisor_len - 1]);
            qhat = trial.q;
            rhat = trial.r;
        }

        if (divisor_len >= 2) {
            while (!rhat_overflow and
                @as(u128, qhat) * @as(u128, divisor[divisor_len - 2]) >
                    (@as(u128, rhat) << 64) | @as(u128, u[offset + divisor_len - 2]))
            {
                qhat -%= 1;
                const add = @addWithOverflow(rhat, divisor[divisor_len - 1]);
                rhat = add[0];
                rhat_overflow = add[1] != 0;
            }
        }

        if (mulSubAt(&u, &divisor, divisor_len, offset, qhat)) {
            addBackAt(&u, &divisor, divisor_len, offset);
        }
    }

    clearLimbs(4, out);
    if (shift == 0) {
        inline for (0..4) |i| {
            if (i < divisor_len) out[i] = u[i];
        }
    } else {
        const lshift: u6 = @intCast(@as(u7, 64) - shift);
        inline for (0..4) |i| {
            if (i < divisor_len) {
                const upper = if (i + 1 < divisor_len) u[i + 1] << lshift else 0;
                out[i] = (u[i] >> shift) | upper;
            }
        }
    }
}

fn mod8By4Knuth(out: *Word4, numerator: *const Word8, modulo: *const Word4) void {
    const divisor_len = countLimbs(4, modulo);
    const numerator_len = countLimbs(8, numerator);
    if (numerator_len == 0) {
        clearLimbs(4, out);
        return;
    }
    if (ltPrefix(8, numerator, numerator_len, modulo, divisor_len)) {
        clearLimbs(4, out);
        inline for (0..4) |i| {
            if (i < numerator_len) out[i] = numerator[i];
        }
        return;
    }

    if (divisor_len == 1) {
        var rem: u64 = 0;
        var i = numerator_len;
        while (i != 0) {
            i -= 1;
            const result = div128by64(rem, numerator[i], modulo[0]);
            rem = result.r;
        }
        out[0] = rem;
        out[1] = 0;
        out[2] = 0;
        out[3] = 0;
        return;
    }

    modNxMKnuth(out, numerator, modulo, numerator_len, divisor_len);
}

inline fn divModSingleLimb(out_q: *Word4, out_r: *Word4, numerator: *const Word4, numerator_len: usize, divisor: u64) void {
    clearLimbs(4, out_q);

    var rem: u64 = 0;
    var i = numerator_len;
    while (i != 0) {
        i -= 1;
        const result = div128by64(rem, numerator[i], divisor);
        out_q[i] = result.q;
        rem = result.r;
    }

    out_r[0] = rem;
    out_r[1] = 0;
    out_r[2] = 0;
    out_r[3] = 0;
}

inline fn divMulSubAt(u: *Word5, divisor: *const Word4, divisor_len: usize, offset: usize, qhat: u64) bool {
    var carry: u128 = 0;
    var borrow: u128 = 0;

    for (0..divisor_len) |i| {
        const product = @as(u128, qhat) * @as(u128, divisor[i]) + carry;
        carry = product >> 64;

        const rhs = @as(u128, @as(u64, @truncate(product))) + borrow;
        const lhs = @as(u128, u[offset + i]);
        if (lhs >= rhs) {
            u[offset + i] = @truncate(lhs - rhs);
            borrow = 0;
        } else {
            u[offset + i] = @truncate((@as(u128, 1) << 64) + lhs - rhs);
            borrow = 1;
        }
    }

    const high_rhs = carry + borrow;
    const high_lhs = @as(u128, u[offset + divisor_len]);
    if (high_lhs >= high_rhs) {
        u[offset + divisor_len] = @truncate(high_lhs - high_rhs);
        return false;
    }

    u[offset + divisor_len] = @truncate((@as(u128, 1) << 64) + high_lhs - high_rhs);
    return true;
}

inline fn divAddBackAt(u: *Word5, divisor: *const Word4, divisor_len: usize, offset: usize) void {
    var carry: u128 = 0;
    for (0..divisor_len) |i| {
        const sum = @as(u128, u[offset + i]) + @as(u128, divisor[i]) + carry;
        u[offset + i] = @truncate(sum);
        carry = sum >> 64;
    }
    u[offset + divisor_len] +%= @truncate(carry);
}

inline fn unnormalizeRemainder(out: *Word4, u: *const Word5, divisor_len: usize, shift: u6) void {
    clearLimbs(4, out);
    if (shift == 0) {
        inline for (0..4) |i| {
            if (i < divisor_len) out[i] = u[i];
        }
        return;
    }

    const lshift: u6 = @intCast(@as(u7, 64) - shift);
    inline for (0..4) |i| {
        if (i < divisor_len) {
            const upper = if (i + 1 < divisor_len) u[i + 1] << lshift else 0;
            out[i] = (u[i] >> shift) | upper;
        }
    }
}

inline fn divModNormalized(out_q: *Word4, out_r: *Word4, numerator: *const Word4, numerator_len: usize, divisor_in: *const Word4, divisor_len: usize) void {
    var divisor: Word4 = undefined;
    var u: Word5 = undefined;

    const shift: u6 = @intCast(@clz(divisor_in[divisor_len - 1]));
    if (shift == 0) {
        inline for (0..4) |i| {
            divisor[i] = if (i < divisor_len) divisor_in[i] else 0;
        }
        inline for (0..5) |i| {
            if (i < 4) {
                u[i] = if (i < numerator_len) numerator[i] else 0;
            } else {
                u[i] = 0;
            }
        }
    } else {
        const rshift: u6 = @intCast(@as(u7, 64) - shift);
        inline for (0..4) |i| divisor[i] = 0;
        inline for (0..5) |i| u[i] = 0;

        divisor[0] = divisor_in[0] << shift;
        var i: usize = 1;
        while (i < divisor_len) : (i += 1) {
            divisor[i] = (divisor_in[i] << shift) | (divisor_in[i - 1] >> rshift);
        }

        u[0] = numerator[0] << shift;
        i = 1;
        while (i < numerator_len) : (i += 1) {
            u[i] = (numerator[i] << shift) | (numerator[i - 1] >> rshift);
        }
        u[numerator_len] = numerator[numerator_len - 1] >> rshift;
    }

    clearLimbs(4, out_q);
    var offset = numerator_len - divisor_len + 1;
    while (offset != 0) {
        offset -= 1;

        var qhat: u64 = undefined;
        var rhat: u64 = undefined;
        var rhat_overflow = false;
        if (u[offset + divisor_len] == divisor[divisor_len - 1]) {
            qhat = std.math.maxInt(u64);
            const add = @addWithOverflow(u[offset + divisor_len - 1], divisor[divisor_len - 1]);
            rhat = add[0];
            rhat_overflow = add[1] != 0;
        } else {
            const trial = div128by64(u[offset + divisor_len], u[offset + divisor_len - 1], divisor[divisor_len - 1]);
            qhat = trial.q;
            rhat = trial.r;
        }

        if (divisor_len >= 2) {
            while (!rhat_overflow and
                @as(u128, qhat) * @as(u128, divisor[divisor_len - 2]) >
                    (@as(u128, rhat) << 64) | @as(u128, u[offset + divisor_len - 2]))
            {
                qhat -%= 1;
                const add = @addWithOverflow(rhat, divisor[divisor_len - 1]);
                rhat = add[0];
                rhat_overflow = add[1] != 0;
            }
        }

        out_q[offset] = qhat;
        if (divMulSubAt(&u, &divisor, divisor_len, offset, qhat)) {
            out_q[offset] -%= 1;
            divAddBackAt(&u, &divisor, divisor_len, offset);
        }
    }

    unnormalizeRemainder(out_r, &u, divisor_len, shift);
}

inline fn divModKnuth(out_q: *Word4, out_r: *Word4, numerator: *const Word4, divisor: *const Word4) void {
    const divisor_len = countLimbs(4, divisor);
    if (divisor_len == 0) {
        clearLimbs(4, out_q);
        clearLimbs(4, out_r);
        return;
    }

    const numerator_len = countLimbs(4, numerator);
    if (numerator_len == 0) {
        clearLimbs(4, out_q);
        clearLimbs(4, out_r);
        return;
    }

    if (ltPrefix(4, numerator, numerator_len, divisor, divisor_len)) {
        clearLimbs(4, out_q);
        inline for (0..4) |i| out_r[i] = numerator[i];
        return;
    }

    if (divisor_len == 1) {
        divModSingleLimb(out_q, out_r, numerator, numerator_len, divisor[0]);
    } else {
        divModNormalized(out_q, out_r, numerator, numerator_len, divisor, divisor_len);
    }
}

inline fn divKnuth(value: u256, denominator: u256) u256 {
    var numerator: Word4 = undefined;
    var divisor: Word4 = undefined;
    var quotient: Word4 = undefined;
    var remainder: Word4 = undefined;

    toLimbs(&numerator, value);
    toLimbs(&divisor, denominator);
    divModKnuth(&quotient, &remainder, &numerator, &divisor);
    return fromLimbsPtr(&quotient);
}

inline fn modKnuth(value: u256, denominator: u256) u256 {
    var numerator: Word4 = undefined;
    var divisor: Word4 = undefined;
    var quotient: Word4 = undefined;
    var remainder: Word4 = undefined;

    toLimbs(&numerator, value);
    toLimbs(&divisor, denominator);
    divModKnuth(&quotient, &remainder, &numerator, &divisor);
    return fromLimbsPtr(&remainder);
}

fn mulModKnuth(lhs: u256, rhs: u256, modulo: u256) u256 {
    var lhs_limbs: Word4 = undefined;
    var rhs_limbs: Word4 = undefined;
    var modulo_limbs: Word4 = undefined;
    var product: Word8 = undefined;
    var reduced: Word4 = undefined;

    toLimbs(&lhs_limbs, lhs);
    toLimbs(&rhs_limbs, rhs);
    toLimbs(&modulo_limbs, modulo);
    mulFull4(&product, &lhs_limbs, &rhs_limbs);
    mod8By4Knuth(&reduced, &product, &modulo_limbs);
    return fromLimbs(reduced);
}

fn expectDivModMatchesBuiltin(numerator: u256, denominator: u256) !void {
    try std.testing.expect(denominator != 0);
    try std.testing.expectEqual(numerator / denominator, div(numerator, denominator));
    try std.testing.expectEqual(numerator % denominator, mod(numerator, denominator));
    try std.testing.expectEqual(numerator / denominator, divKnuth(numerator, denominator));
    try std.testing.expectEqual(numerator % denominator, modKnuth(numerator, denominator));
}

fn expectSignedDivModMatchesGeneric(numerator: u256, denominator: u256) !void {
    try std.testing.expectEqual(sdivGeneric(numerator, denominator), sdiv(numerator, denominator));
    try std.testing.expectEqual(smodGeneric(numerator, denominator), smod(numerator, denominator));
}

test sdiv {
    const min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg_one: u256 = @bitCast(@as(i256, -1));
    const neg_three: u256 = @bitCast(@as(i256, -3));

    try std.testing.expectEqual(@as(u256, 0), sdiv(1, 0));
    try std.testing.expectEqual(@as(u256, 3), sdiv(10, 3));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -3))), sdiv(@bitCast(@as(i256, -10)), 3));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -3))), sdiv(10, neg_three));
    try std.testing.expectEqual(@as(u256, 3), sdiv(@bitCast(@as(i256, -10)), neg_three));
    try std.testing.expectEqual(min_word, sdiv(min_word, 1));
    try std.testing.expectEqual(min_word, sdiv(min_word, neg_one));
    try std.testing.expectEqual(@as(u256, 0), sdiv(neg_one, 2));
}

test smod {
    const min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const neg_three: u256 = @bitCast(@as(i256, -3));

    try std.testing.expectEqual(@as(u256, 0), smod(1, 0));
    try std.testing.expectEqual(@as(u256, 1), smod(10, 3));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -1))), smod(@bitCast(@as(i256, -10)), 3));
    try std.testing.expectEqual(@as(u256, 1), smod(10, neg_three));
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -1))), smod(@bitCast(@as(i256, -10)), neg_three));
    try std.testing.expectEqual(smodGeneric(min_word, 3), smod(min_word, 3));
    try std.testing.expectEqual(@as(u256, 0), smod(min_word, @bitCast(@as(i256, -1))));
}

test "signed div and mod cover limb edge vectors" {
    const min_word: u256 = @bitCast(@as(i256, std.math.minInt(i256)));
    const max_positive: u256 = @bitCast(@as(i256, std.math.maxInt(i256)));
    const neg_one: u256 = @bitCast(@as(i256, -1));
    const neg_two: u256 = @bitCast(@as(i256, -2));
    const neg_large_64: u256 = @bitCast(@as(i256, -0x1_0000_0000_0000_0000));
    const neg_large_128: u256 = @bitCast(@as(i256, -0x1_0000_0000_0000_0000_0000_0000_0000_0000));

    const cases = [_]struct {
        numerator: u256,
        denominator: u256,
    }{
        .{ .numerator = min_word, .denominator = neg_one },
        .{ .numerator = min_word, .denominator = neg_two },
        .{ .numerator = min_word, .denominator = neg_large_64 },
        .{ .numerator = min_word +% 0x1234, .denominator = neg_large_64 -% 57 },
        .{ .numerator = min_word +% 0x4567, .denominator = neg_large_128 +% 99 },
        .{ .numerator = max_positive, .denominator = min_word },
        .{ .numerator = neg_one, .denominator = min_word },
        .{ .numerator = 0x7effffff8000000000000000000000000000000000000000d900000000000001, .denominator = @bitCast(@as(i256, -0x7fff_ffff_ffff_ffff)) },
    };

    for (cases) |case| {
        try expectSignedDivModMatchesGeneric(case.numerator, case.denominator);
    }
}

test "unsigned div and mod use EVM zero semantics and match builtin arithmetic" {
    const max = std.math.maxInt(u256);
    const word_sized = @as(u256, 0x1_0000_0000);
    const cases = [_]struct {
        numerator: u256,
        denominator: u256,
    }{
        .{
            .numerator = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef,
            .denominator = 0x8123456789abcdef0011223344556677,
        },
        .{
            .numerator = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef,
            .denominator = 0x8123456789abcdef00112233445566778899aabbccddeeff,
        },
        .{
            .numerator = 0xfedcba98765432100123456789abcdeffedcba98765432100123456789abcdef,
            .denominator = 0x8123456789abcdef00112233445566778899aabbccddeeff1020304050607080,
        },
    };

    try std.testing.expectEqual(@as(u256, 0), div(1, 0));
    try std.testing.expectEqual(@as(u256, 0), mod(1, 0));
    try std.testing.expectEqual(@as(u256, 3), div(10, 3));
    try std.testing.expectEqual(@as(u256, 1), mod(10, 3));
    try std.testing.expectEqual(word_sized / 3, div(word_sized, 3));
    try std.testing.expectEqual(word_sized % 3, mod(word_sized, 3));
    try std.testing.expectEqual(max / (max - 1), div(max, max - 1));
    try std.testing.expectEqual(max % (max - 1), mod(max, max - 1));

    for (cases) |case| {
        try std.testing.expectEqual(case.numerator / case.denominator, div(case.numerator, case.denominator));
        try std.testing.expectEqual(case.numerator % case.denominator, mod(case.numerator, case.denominator));
        try std.testing.expectEqual(case.numerator / case.denominator, divKnuth(case.numerator, case.denominator));
        try std.testing.expectEqual(case.numerator % case.denominator, modKnuth(case.numerator, case.denominator));
    }
}

test "limb div and mod cover branch edge vectors" {
    const cases = [_]struct {
        numerator: u256,
        denominator: u256,
    }{
        .{ .numerator = 0x7000000000000000, .denominator = 0x8000000000000000 },
        .{ .numerator = 0x80000000000000010000000000000000, .denominator = 0x80000000000000000000000000000000 },
        .{ .numerator = 0x80000000000000000000000000000000, .denominator = 0x80000000000000000000000000000001 },
        .{ .numerator = 0x478392145435897052, .denominator = 0x111 },
        .{ .numerator = 0x12121212121212121212121212121212, .denominator = 0x232323232323232323 },
        .{ .numerator = 0xf6376770abd3a36b20394c5664afef1194c801c3f05e42566f085ed24d002bb0, .denominator = 0xb368d219438b7f3f },
        .{ .numerator = 0xfffff716b61616160b0b0b2b0b0b0becf4bef50a0df4f48b090b2b0bc60a0a00, .denominator = 0xfffff716b61616160b0b0b2b0b230b000008010d0a2b00 },
        .{ .numerator = 0x50beb1c60141a0000dc2b0b0b0b0b0b410a0a0df4f40b090b2b0bc60a0a00, .denominator = 0x2000110000000d0a300e750a000000090a0a },
        .{ .numerator = 0x4b00000b41000b0b0b2b0b0b0b0b0b410a0aeff4f40b090b2b0bc60a0a1000, .denominator = 0x4b00000b41000b0b0b2b0b0b0b0b0b410a0aeff4f40b0a0a },
        .{ .numerator = 0x8200000000000000000000000000000000000000000000000000000000000000, .denominator = 0x8200000000000000fe000004000000ffff000000fffff700 },
        .{ .numerator = 0x8000000000000001800000000000000080000000000000008000000000000000, .denominator = 0x800000000000000080000000000000008000000000000000 },
        .{ .numerator = 0x001f000000000000000000000000000000200000000100000000000000000000, .denominator = 0x0000000000000000000100000000ffffffffffffffff0000000000002e000000 },
        .{ .numerator = 0x7effffff80000000000000000000000000020000440000000000000000000001, .denominator = 0x7effffff800000007effffff800000008000ff0000010000 },
        .{ .numerator = 0xff00ffffffffffffffcaffffffff0100, .denominator = 0x0100000000000000ff800000000000ff },
        .{ .numerator = 170141183460488574554024512018559533058, .denominator = 170141183460488574554024512018559533057 },
    };

    for (cases) |case| {
        try expectDivModMatchesBuiltin(case.numerator, case.denominator);
    }
}

test "bytes32 conversion uses Ethereum byte order" {
    var bytes = [_]u8{0} ** 32;
    bytes[31] = 1;
    try std.testing.expectEqual(@as(u256, 1), fromBytes32(&bytes));

    bytes = toBytes32(0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), bytes[30]);
    try std.testing.expectEqual(@as(u8, 0x34), bytes[31]);

    writeBytes32(&bytes, 1);
    try std.testing.expectEqual(@as(u8, 1), bytes[31]);
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
        const signed_min_seed = [_]u8{0x05} ++ [_]u8{0x80} ++ [_]u8{0x00} ** 126;
        const signed_neg_seed = [_]u8{0x06} ++ [_]u8{0xff} ** 127;

        const corpus = [_][]const u8{
            &zero_mod_seed,
            &tiny_mod_seed,
            &medium_mod_seed,
            &large_mod_seed,
            &near_mod_seed,
            &signed_min_seed,
            &signed_neg_seed,
        };

        fn shapedWord(raw: u256, shape: u8) u256 {
            return switch (shape % 12) {
                0 => 0,
                1 => 1,
                2 => std.math.maxInt(u256),
                3 => @as(u256, 1) << 255,
                4 => (@as(u256, 1) << 255) - 1,
                5 => 0 -% @as(u256, 1 + (raw & 0xff)),
                6 => raw & std.math.maxInt(u64),
                7 => raw & std.math.maxInt(u128),
                8 => raw | (@as(u256, 1) << 192),
                9 => raw | (@as(u256, 1) << 255),
                10 => 0 -% @as(u256, 1 + (raw & 0xffff)),
                else => raw,
            };
        }

        fn oracle(_: void, smith: *std.testing.Smith) anyerror!void {
            var shape_bytes: [4]u8 = undefined;
            smith.bytes(&shape_bytes);

            const lhs = shapedWord(smith.value(u256), shape_bytes[1]);
            const rhs = shapedWord(smith.value(u256), shape_bytes[2]);
            const modulo = switch (shape_bytes[0] % 5) {
                0 => 0,
                1 => @as(u256, 1) + smith.value(u8),
                2 => @as(u256, smith.value(u128)) | 1,
                3 => smith.value(u256) | (@as(u256, 1) << 192),
                4 => 0 -% @as(u256, 1 + (smith.value(u64) % 1024)),
                else => unreachable,
            };
            const signed_denominator = shapedWord(smith.value(u256), shape_bytes[3]);

            try std.testing.expectEqual(if (modulo == 0) 0 else lhs / modulo, div(lhs, modulo));
            try std.testing.expectEqual(if (modulo == 0) 0 else lhs % modulo, mod(lhs, modulo));
            try std.testing.expectEqual(if (modulo == 0) 0 else lhs / modulo, divKnuth(lhs, modulo));
            try std.testing.expectEqual(if (modulo == 0) 0 else lhs % modulo, modKnuth(lhs, modulo));
            try std.testing.expectEqual(sdivGeneric(lhs, signed_denominator), sdiv(lhs, signed_denominator));
            try std.testing.expectEqual(smodGeneric(lhs, signed_denominator), smod(lhs, signed_denominator));
            try std.testing.expectEqual(if (modulo == 0) 0 else addModGeneric(lhs, rhs, modulo), addMod(lhs, rhs, modulo));
            try std.testing.expectEqual(if (modulo == 0) 0 else mulModGeneric(lhs, rhs, modulo), mulMod(lhs, rhs, modulo));
            if (modulo != 0 and (0 -% modulo) > std.math.maxInt(u64)) {
                try std.testing.expectEqual(mulModGeneric(lhs, rhs, modulo), mulModKnuth(lhs, rhs, modulo));
            }
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
