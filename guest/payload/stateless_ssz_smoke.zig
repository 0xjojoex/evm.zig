const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_allocator = @import("guest_allocator");

const magic: u32 = 0x5353_5a31; // SSZ1
const zisk_output_addr: usize = 0xa0010000;

pub const output_word_count = 8;
pub export var evmz_guest_output: [output_word_count]u32 = .{
    magic,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
};

pub const SszSmokeProof = struct {
    successful_validation: bool,
    output_len: u32,
    payload_root_low: u32,
    chain_id_low: u32,
    fork: u32,
};

export fn evmz_guest_entry() callconv(.c) void {
    var fixed = guest_allocator.fixedBufferAllocator();
    const proof = runStatelessSszSmoke(fixed.allocator()) catch |err| {
        evmz_guest_output = .{
            magic,
            0,
            0,
            0,
            0,
            0,
            0,
            @truncate(@intFromError(err)),
        };
        return;
    };

    evmz_guest_output = .{
        magic,
        @intFromBool(proof.successful_validation),
        proof.output_len,
        proof.payload_root_low,
        proof.chain_id_low,
        proof.fork,
        0,
        0,
    };
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

pub fn runStatelessSszSmoke(allocator: std.mem.Allocator) !SszSmokeProof {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input_bytes = try evmz.stateless.wire.smokeInputBytes(scratch);
    const output_bytes = try evmz.stateless.wire.validateStatelessBytes(scratch, input_bytes);
    const output = try evmz.stateless.wire.StatelessValidationResult.decode(scratch, output_bytes);

    return .{
        .successful_validation = output.successful_validation,
        .output_len = @intCast(output_bytes.len),
        .payload_root_low = std.mem.readInt(u32, output.new_payload_request_root[28..32], .big),
        .chain_id_low = @truncate(output.chain_config.chain_id),
        .fork = @intCast(@intFromEnum(output.chain_config.active_fork.fork)),
    };
}

fn writeZiskOutput() void {
    for (evmz_guest_output, 0..) |word, i| {
        const output_word: *volatile u32 = @ptrFromInt(zisk_output_addr + i * @sizeOf(u32));
        output_word.* = word;
    }
}
