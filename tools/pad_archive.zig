//! Copy a static archive so that it ends on an even offset.
//!
//! An `ar` member starts on an even offset, so a member of odd size is followed
//! by one padding byte, the last member included. Zig's Mach-O archiver pads
//! before each member and never after the last one, and Apple's `ld` rejects
//! the result: "malformed archive, member exceeds file size". Whether the last
//! member is odd depends on the build mode.
//!
//! Upstream: https://codeberg.org/ziglang/zig/issues/30572
// tidy:root

const std = @import("std");

const magic = "!<arch>\n";
const header_len = 60;
const header_end = "`\n";
const max_archive_bytes: std.Io.Limit = .limited(1024 * 1024 * 1024);

const usage =
    \\usage: pad-archive <input> <output>
    \\
;

/// Whether `archive` ends right after an odd-sized last member. Every member
/// must otherwise lie inside the archive.
fn lacksFinalPadding(archive: []const u8) error{InvalidArchive}!bool {
    if (!std.mem.startsWith(u8, archive, magic)) return error.InvalidArchive;
    var offset: usize = magic.len;
    while (offset < archive.len) {
        if (archive.len - offset < header_len) return error.InvalidArchive;
        const header = archive[offset..][0..header_len];
        if (!std.mem.eql(u8, header[58..60], header_end)) return error.InvalidArchive;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, header[48..58], " "), 10) catch
            return error.InvalidArchive;
        offset += header_len;
        if (size > archive.len - offset) return error.InvalidArchive;
        offset += size;
        if (offset % 2 == 0) continue;
        if (offset == archive.len) return true;
        offset += 1;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const input = args.next() orelse fatal(usage, .{});
    const output = args.next() orelse fatal(usage, .{});
    if (args.next() != null) fatal(usage, .{});

    const cwd = std.Io.Dir.cwd();
    const archive = cwd.readFileAlloc(init.io, input, allocator, max_archive_bytes) catch |err|
        fatal("pad-archive: {s}: {t}\n", .{ input, err });
    const pad = lacksFinalPadding(archive) catch |err|
        fatal("pad-archive: {s}: {t}\n", .{ input, err });

    var file = cwd.createFile(init.io, output, .{}) catch |err|
        fatal("pad-archive: {s}: {t}\n", .{ output, err });
    defer file.close(init.io);
    file.writeStreamingAll(init.io, archive) catch |err|
        fatal("pad-archive: {s}: {t}\n", .{ output, err });
    if (pad) file.writeStreamingAll(init.io, "\n") catch |err|
        fatal("pad-archive: {s}: {t}\n", .{ output, err });
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

/// A member header followed by `size` bytes of content. Comptime only.
fn testMember(comptime size: usize) [header_len + size]u8 {
    var bytes: [header_len + size]u8 = @splat(' ');
    const digits = std.fmt.comptimePrint("{d}", .{size});
    @memcpy(bytes[48..][0..digits.len], digits);
    bytes[58..60].* = header_end.*;
    @memset(bytes[header_len..], 'x');
    return bytes;
}

test "an odd-sized last member lacks its padding" {
    try std.testing.expect(try lacksFinalPadding(comptime magic ++ testMember(3)));
    const two = comptime magic ++ testMember(4) ++ testMember(5);
    try std.testing.expect(try lacksFinalPadding(two));
}

test "a complete archive needs nothing" {
    try std.testing.expect(!try lacksFinalPadding(magic));
    try std.testing.expect(!try lacksFinalPadding(comptime magic ++ testMember(4)));
    try std.testing.expect(!try lacksFinalPadding(comptime magic ++ testMember(3) ++ "\n"));
    // The padding between members is skipped, not read as a header.
    const padded_between = comptime magic ++ testMember(3) ++ "\n" ++ testMember(4);
    try std.testing.expect(!try lacksFinalPadding(padded_between));
}

test "a member that leaves the archive is rejected" {
    const whole = comptime magic ++ testMember(8);
    const cut = whole[0 .. whole.len - 2];
    const trailing = comptime whole ++ "trailing";
    // Two odd members with no padding between them: the second header is misread.
    const unpadded_between = comptime magic ++ testMember(3) ++ testMember(3);
    for ([_][]const u8{ cut, trailing, unpadded_between, "\x7fELF" }) |archive| {
        try std.testing.expectError(error.InvalidArchive, lacksFinalPadding(archive));
    }
}
