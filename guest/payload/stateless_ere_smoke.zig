const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_allocator = @import("guest_allocator");

const magic: u32 = 0x4552_4531; // ERE1
const zisk_output_addr: usize = 0xa0010000;

pub const output_word_count = 12;
pub export var evmz_guest_output: [output_word_count]u32 = [_]u32{0} ** output_word_count;
pub export var evmz_guest_public_values: evmz.stateless.ere.PublicValues = [_]u8{0} ** evmz.stateless.ere.public_values_size;

pub const EreSmokeProof = struct {
    successful_validation: bool,
    output_len: u32,
    public_values: evmz.stateless.ere.PublicValues,
};

export fn evmz_guest_entry() callconv(.c) void {
    var fixed = guest_allocator.fixedBufferAllocator();
    const proof = runStatelessEreSmoke(fixed.allocator()) catch |err| {
        evmz_guest_output = errorWords(@truncate(@intFromError(err)));
        return;
    };

    evmz_guest_public_values = proof.public_values;
    evmz_guest_output = proofWords(proof, 0);
}

comptime {
    if (guest_options.use_ziskos_staticlib) {
        @export(&ziskMain, .{ .name = "main" });
    }
}

fn ziskMain() callconv(.c) void {
    evmz_guest_entry();
    writeZiskOutput();
}

pub fn runStatelessEreSmoke(allocator: std.mem.Allocator) !EreSmokeProof {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input_bytes = try evmz.stateless.wire.smokeInputBytes(scratch);
    const run = try evmz.stateless.ere.runStatelessValidator(scratch, input_bytes);
    const output = try evmz.stateless.wire.StatelessValidationResult.decode(scratch, run.output);

    return .{
        .successful_validation = output.successful_validation,
        .output_len = @intCast(run.output.len),
        .public_values = run.public_values,
    };
}

fn proofWords(proof: EreSmokeProof, error_code: u32) [output_word_count]u32 {
    var words: [output_word_count]u32 = undefined;
    words[0] = magic;
    words[1] = @intFromBool(proof.successful_validation);
    words[2] = proof.output_len;
    for (0..8) |i| {
        words[3 + i] = std.mem.readInt(u32, proof.public_values[i * 4 ..][0..4], .big);
    }
    words[11] = error_code;
    return words;
}

fn errorWords(error_code: u32) [output_word_count]u32 {
    return proofWords(.{
        .successful_validation = false,
        .output_len = 0,
        .public_values = [_]u8{0} ** evmz.stateless.ere.public_values_size,
    }, error_code);
}

fn writeZiskOutput() void {
    for (evmz_guest_output, 0..) |word, i| {
        const output_word: *volatile u32 = @ptrFromInt(zisk_output_addr + i * @sizeOf(u32));
        output_word.* = word;
    }
}
