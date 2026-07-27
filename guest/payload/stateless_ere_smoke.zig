const std = @import("std");
const builtin = @import("builtin");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_allocator = @import("guest_allocator");

const magic: u32 = 0x4552_4531; // ERE1
const zisk_output_addr: usize = 0xa0010000;

pub const output_word_count = 4;
pub var evmz_guest_output: [output_word_count]u32 = [_]u32{0} ** output_word_count;

pub const EreSmokeProof = struct {
    successful_validation: bool,
    output_len: u32,
};

pub fn evmz_guest_entry() callconv(.c) void {
    var fixed = guest_allocator.fixedBufferAllocator();
    const proof = runStatelessEreSmoke(fixed.allocator()) catch |err| {
        evmz_guest_output = errorWords(@truncate(@intFromError(err)));
        return;
    };

    evmz_guest_output = proofWords(proof, 0);
}

comptime {
    if (!builtin.is_test) {
        @export(&evmz_guest_output, .{ .name = "evmz_guest_output" });
        @export(&evmz_guest_entry, .{ .name = "evmz_guest_entry" });
    }
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
    const output_bytes = try evmz.stateless.wire.validateStatelessBytes(scratch, input_bytes);
    const output = try evmz.stateless.wire.StatelessValidationResult.decode(scratch, output_bytes);

    return .{
        .successful_validation = output.successful_validation,
        .output_len = @intCast(output_bytes.len),
    };
}

fn proofWords(proof: EreSmokeProof, error_code: u32) [output_word_count]u32 {
    return .{ magic, @intFromBool(proof.successful_validation), proof.output_len, error_code };
}

fn errorWords(error_code: u32) [output_word_count]u32 {
    return proofWords(.{
        .successful_validation = false,
        .output_len = 0,
    }, error_code);
}

fn writeZiskOutput() void {
    for (evmz_guest_output, 0..) |word, i| {
        const output_word: *volatile u32 = @ptrFromInt(zisk_output_addr + i * @sizeOf(u32));
        output_word.* = word;
    }
}
