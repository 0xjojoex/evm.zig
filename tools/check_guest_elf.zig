//! Validate the structural and optional ISA contract of a zkEVM guest ELF.
// tidy:root

const std = @import("std");
const Allocator = std.mem.Allocator;

const max_elf_bytes: std.Io.Limit = .limited(1024 * 1024 * 1024);

const Program = struct {
    kind: u32,
    flags: u32,
    offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
};

const Section = struct {
    name_offset: u32,
    kind: u32,
    flags: u64,
    address: u64,
    offset: u64,
    size: u64,
    link: u32,
    entry_size: u64,
};

const Symbol = struct {
    info: u8,
    section_index: u16,
    value: u64,
};

const Summary = struct {
    load_count: usize,
};

const Checker = struct {
    allocator: Allocator,
    data: []const u8,
    failure: []const u8 = "invalid ELF",

    fn fail(checker: *Checker, message: []const u8) error{InvalidElf} {
        checker.failure = message;
        return error.InvalidElf;
    }

    fn failFmt(checker: *Checker, comptime format: []const u8, args: anytype) error{InvalidElf} {
        checker.failure = std.fmt.allocPrint(checker.allocator, format, args) catch "invalid ELF";
        return error.InvalidElf;
    }

    fn region(checker: *Checker, offset: u64, size: u64) error{InvalidElf}![]const u8 {
        const start = std.math.cast(usize, offset) orelse return checker.fail("ELF offset is too large");
        const length = std.math.cast(usize, size) orelse return checker.fail("ELF size is too large");
        if (start > checker.data.len or length > checker.data.len - start) {
            return checker.fail("ELF table extends past end of file");
        }
        return checker.data[start..][0..length];
    }

    fn integer(checker: *Checker, comptime T: type, offset: u64) error{InvalidElf}!T {
        const bytes = try checker.region(offset, @sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn tableEntry(checker: *Checker, offset: u64, index: usize, entry_size: u16, minimum_size: u16) error{InvalidElf}!u64 {
        if (entry_size < minimum_size) return checker.fail("ELF table entry is smaller than its declared format");
        const entry_offset = std.math.mul(u64, index, entry_size) catch return checker.fail("ELF table offset overflows");
        const start = std.math.add(u64, offset, entry_offset) catch return checker.fail("ELF table offset overflows");
        _ = try checker.region(start, entry_size);
        return start;
    }

    fn program(checker: *Checker, offset: u64) error{InvalidElf}!Program {
        return .{
            .kind = try checker.integer(u32, offset),
            .flags = try checker.integer(u32, offset + 4),
            .offset = try checker.integer(u64, offset + 8),
            .virtual_address = try checker.integer(u64, offset + 16),
            .file_size = try checker.integer(u64, offset + 32),
            .memory_size = try checker.integer(u64, offset + 40),
            .alignment = try checker.integer(u64, offset + 48),
        };
    }

    fn section(checker: *Checker, offset: u64) error{InvalidElf}!Section {
        return .{
            .name_offset = try checker.integer(u32, offset),
            .kind = try checker.integer(u32, offset + 4),
            .flags = try checker.integer(u64, offset + 8),
            .address = try checker.integer(u64, offset + 16),
            .offset = try checker.integer(u64, offset + 24),
            .size = try checker.integer(u64, offset + 32),
            .link = try checker.integer(u32, offset + 40),
            .entry_size = try checker.integer(u64, offset + 56),
        };
    }

    fn sectionBytes(checker: *Checker, section_value: Section) error{InvalidElf}![]const u8 {
        return checker.region(section_value.offset, section_value.size) catch {
            return checker.fail("section extends past end of file");
        };
    }

    fn cString(checker: *Checker, strings: []const u8, offset: u32) error{InvalidElf}![]const u8 {
        if (offset >= strings.len) return checker.fail("string-table offset is out of bounds");
        const tail = strings[offset..];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse return checker.fail("unterminated ELF string");
        for (tail[0..end]) |byte| {
            if (byte > 0x7f) return checker.fail("ELF string is not ASCII");
        }
        return tail[0..end];
    }

    fn endAddress(checker: *Checker, address: u64, size: u64) error{InvalidElf}!u64 {
        return std.math.add(u64, address, size) catch checker.fail("ELF address range overflows");
    }

    fn loadIndex(checker: *Checker, loads: []const Program, address: u64, size: u64) error{InvalidElf}!?usize {
        const end = try checker.endAddress(address, size);
        for (loads, 0..) |load, index| {
            const load_end = try checker.endAddress(load.virtual_address, load.memory_size);
            if (load.virtual_address <= address and end <= load_end) return index;
        }
        return null;
    }

    fn findSection(
        checker: *Checker,
        sections: []const Section,
        section_names: []const u8,
        wanted: []const u8,
    ) error{InvalidElf}!?Section {
        for (sections) |section_value| {
            const name = try checker.cString(section_names, section_value.name_offset);
            if (std.mem.eql(u8, name, wanted)) return section_value;
        }
        return null;
    }

    fn checkArchitecture(checker: *Checker, attributes: []const u8, allow_attribute_a: bool) error{InvalidElf}!void {
        const marker = std.mem.indexOf(u8, attributes, "rv64") orelse return checker.fail("missing RISC-V architecture attribute");
        var end = marker + 4;
        while (end < attributes.len) : (end += 1) {
            const byte = attributes[end];
            if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_')) break;
        }
        const architecture = attributes[marker..end];
        var extensions = std.mem.splitScalar(u8, architecture, '_');
        const base = extensions.next() orelse return checker.fail("missing RISC-V architecture attribute");
        if (!std.mem.startsWith(u8, base, "rv64i")) return checker.fail("RISC-V target must declare RV64I");

        var has_m = false;
        var has_zicclsm = false;
        while (extensions.next()) |extension| {
            if (std.mem.startsWith(u8, extension, "m")) has_m = true;
            if (std.mem.startsWith(u8, extension, "zicclsm")) has_zicclsm = true;
            const atomic_family = std.mem.startsWith(u8, extension, "a") or
                std.mem.startsWith(u8, extension, "zaamo") or
                std.mem.startsWith(u8, extension, "zalrsc");
            if (atomic_family and allow_attribute_a) continue;
            if (atomic_family or
                std.mem.startsWith(u8, extension, "f") or
                std.mem.startsWith(u8, extension, "d"))
            {
                return checker.failFmt("RISC-V target declares forbidden extension: {s}", .{extension});
            }
        }
        if (!has_m) return checker.fail("RISC-V target must declare M");
        if (!has_zicclsm) return checker.fail("RISC-V target must declare Zicclsm");
    }

    fn check(checker: *Checker, options: CheckOptions) error{InvalidElf}!Summary {
        if (checker.data.len < 64) return checker.fail("file is too small to be ELF64");
        if (!std.mem.eql(u8, checker.data[0..4], "\x7fELF")) return checker.fail("missing ELF magic");
        if (checker.data[4] != 2) return checker.fail("ELF class must be ELF64");
        if (checker.data[5] != 1) return checker.fail("ELF data encoding must be little endian");
        if (checker.data[6] != 1) return checker.fail("unsupported ELF identification version");
        if (checker.data[7] != 0) return checker.fail("ELF OS ABI must be System V");
        if (checker.data[8] != 0) return checker.fail("ELF ABI version must be zero");

        const elf_type = try checker.integer(u16, 16);
        const machine = try checker.integer(u16, 18);
        const version = try checker.integer(u32, 20);
        const entry = try checker.integer(u64, 24);
        const program_offset = try checker.integer(u64, 32);
        const section_offset = try checker.integer(u64, 40);
        const flags = try checker.integer(u32, 48);
        const header_size = try checker.integer(u16, 52);
        const program_entry_size = try checker.integer(u16, 54);
        const program_count = try checker.integer(u16, 56);
        const section_entry_size = try checker.integer(u16, 58);
        const section_count = try checker.integer(u16, 60);
        const section_names_index = try checker.integer(u16, 62);

        if (elf_type != 2) return checker.fail("ELF type must be ET_EXEC");
        if (machine != 243) return checker.fail("ELF machine must be RISC-V");
        if (version != 1) return checker.fail("unsupported ELF header version");
        if (header_size != 64) return checker.fail("unexpected ELF64 header size");
        if (flags & 0x1 != 0) return checker.fail("RISC-V compressed-instruction flag is forbidden");
        if (flags & 0x6 != 0) return checker.fail("RISC-V floating-point ABI flags are forbidden");
        if (flags & 0x8 != 0) return checker.fail("RV32E ABI flag is forbidden");
        if (program_count == 0 or program_count == 0xffff) return checker.fail("ELF must have a non-extended program-header table");
        if (section_count == 0 or section_count == 0xffff) return checker.fail("ELF must retain a non-extended section table");
        if (section_names_index >= section_count) return checker.fail("section-name string table index is out of bounds");

        const loads_storage = checker.allocator.alloc(Program, program_count) catch return checker.fail("out of memory");
        var load_count: usize = 0;
        for (0..program_count) |index| {
            const offset = try checker.tableEntry(program_offset, index, program_entry_size, 56);
            const program_value = try checker.program(offset);
            if (program_value.kind != 1) continue;
            loads_storage[load_count] = program_value;
            load_count += 1;
        }
        const loads = loads_storage[0..load_count];
        if (loads.len == 0) return checker.fail("ELF has no PT_LOAD segments");

        var has_executable_load = false;
        var has_writable_load = false;
        var entry_is_executable = false;
        for (loads) |load| {
            if (load.file_size > load.memory_size) return checker.fail("PT_LOAD file size exceeds memory size");
            _ = checker.region(load.offset, load.file_size) catch return checker.fail("PT_LOAD file range extends past end of file");
            if (load.flags & 0x2 != 0 and load.flags & 0x1 != 0) return checker.fail("PT_LOAD violates W^X");
            if (load.alignment != 0 and load.alignment & (load.alignment - 1) != 0) return checker.fail("PT_LOAD alignment is not a power of two");
            if (load.alignment > 1 and load.virtual_address % load.alignment != load.offset % load.alignment) {
                return checker.fail("PT_LOAD virtual address and file offset violate alignment");
            }
            const load_end = try checker.endAddress(load.virtual_address, load.memory_size);
            if (load.flags & 0x1 != 0) {
                has_executable_load = true;
                if (load.virtual_address <= entry and entry < load_end) entry_is_executable = true;
            }
            if (load.flags & 0x2 != 0) has_writable_load = true;
        }
        for (loads, 0..) |earlier, index| {
            const earlier_end = try checker.endAddress(earlier.virtual_address, earlier.memory_size);
            for (loads[index + 1 ..]) |later| {
                const later_end = try checker.endAddress(later.virtual_address, later.memory_size);
                if (!(earlier_end <= later.virtual_address or later_end <= earlier.virtual_address)) {
                    return checker.fail("PT_LOAD virtual-address ranges overlap");
                }
            }
        }
        if (!has_executable_load) return checker.fail("ELF has no executable PT_LOAD");
        if (!has_writable_load) return checker.fail("ELF has no writable PT_LOAD");
        if (!entry_is_executable) return checker.fail("entry point is not inside an executable PT_LOAD");

        const sections = checker.allocator.alloc(Section, section_count) catch return checker.fail("out of memory");
        for (sections, 0..) |*section_value, index| {
            const offset = try checker.tableEntry(section_offset, index, section_entry_size, 64);
            section_value.* = try checker.section(offset);
        }
        const section_names = try checker.sectionBytes(sections[section_names_index]);
        const text = try checker.findSection(sections, section_names, ".text") orelse return checker.fail("missing required .text section");
        const rodata = try checker.findSection(sections, section_names, ".rodata") orelse return checker.fail("missing required .rodata section");
        if (text.flags & 0x6 != 0x6) return checker.fail(".text has incorrect section permissions");
        if (text.flags & 0x1 != 0) return checker.fail(".text has forbidden section permissions");
        if (rodata.flags & 0x2 != 0x2) return checker.fail(".rodata has incorrect section permissions");
        if (rodata.flags & 0x5 != 0) return checker.fail(".rodata has forbidden section permissions");
        for ([_][]const u8{ ".data", ".bss" }) |name| {
            if (try checker.findSection(sections, section_names, name)) |section_value| {
                if (section_value.flags & 0x3 != 0x3) return checker.failFmt("{s} has incorrect section permissions", .{name});
                if (section_value.flags & 0x4 != 0) return checker.failFmt("{s} has forbidden section permissions", .{name});
            }
        }

        const text_load = try checker.loadIndex(loads, text.address, text.size) orelse return checker.fail(".text is not contained in a PT_LOAD");
        const rodata_load = try checker.loadIndex(loads, rodata.address, rodata.size) orelse return checker.fail(".rodata is not contained in a PT_LOAD");
        if (text_load == rodata_load) return checker.fail(".text and .rodata must use separate PT_LOAD segments");

        if (options.require_target) {
            const attributes = try checker.findSection(sections, section_names, ".riscv.attributes") orelse return checker.fail("missing .riscv.attributes");
            try checker.checkArchitecture(try checker.sectionBytes(attributes), options.allow_attribute_a);
            const text_bytes = try checker.sectionBytes(text);
            if (text.address % 4 != 0 or text_bytes.len % 4 != 0) return checker.fail(".text is not composed of RV64 32-bit words");
            var offset: usize = 0;
            while (offset < text_bytes.len) : (offset += 4) {
                const instruction = std.mem.readInt(u32, text_bytes[offset..][0..4], .little);
                const opcode = instruction & 0x7f;
                const address = text.address + offset;
                if (opcode == 0x2f) return checker.failFmt("atomic instruction at 0x{x}", .{address});
                if (opcode == 0x07 or opcode == 0x27 or opcode == 0x43 or opcode == 0x47 or
                    opcode == 0x4b or opcode == 0x4f or opcode == 0x53)
                {
                    return checker.failFmt("floating-point instruction at 0x{x}", .{address});
                }
            }
        }

        var start_symbol: ?Symbol = null;
        var main_symbol: ?Symbol = null;
        var heap_start_symbol: ?Symbol = null;
        var heap_end_symbol: ?Symbol = null;
        for (sections) |section_value| {
            if (section_value.kind != 2 and section_value.kind != 11) continue;
            if (section_value.link >= sections.len) return checker.fail("symbol string-table index is out of bounds");
            const strings = try checker.sectionBytes(sections[section_value.link]);
            if (section_value.entry_size < 24 or section_value.size % section_value.entry_size != 0) return checker.fail("invalid ELF symbol table");
            const symbol_count = section_value.size / section_value.entry_size;
            for (0..symbol_count) |index| {
                const offset_delta = std.math.mul(u64, index, section_value.entry_size) catch return checker.fail("ELF table offset overflows");
                const offset = std.math.add(u64, section_value.offset, offset_delta) catch return checker.fail("ELF table offset overflows");
                _ = try checker.region(offset, 24);
                const name_offset = try checker.integer(u32, offset);
                const symbol: Symbol = .{
                    .info = (try checker.region(offset + 4, 1))[0],
                    .section_index = try checker.integer(u16, offset + 6),
                    .value = try checker.integer(u64, offset + 8),
                };
                if (symbol.section_index == 0) continue;
                const name = try checker.cString(strings, name_offset);
                if (std.mem.eql(u8, name, "_start")) start_symbol = symbol;
                if (std.mem.eql(u8, name, "main")) main_symbol = symbol;
                if (std.mem.eql(u8, name, "_heap_start")) heap_start_symbol = symbol;
                if (std.mem.eql(u8, name, "_heap_end")) heap_end_symbol = symbol;
            }
        }

        const start = start_symbol orelse return checker.fail("missing required symbol _start");
        const main_entry = main_symbol orelse return checker.fail("missing required symbol main");
        const heap_start = heap_start_symbol orelse return checker.fail("missing required symbol _heap_start");
        const heap_end = heap_end_symbol orelse return checker.fail("missing required symbol _heap_end");
        if (start.value != entry) return checker.fail("ELF entry point does not equal _start");
        if (main_entry.info & 0xf != 2) return checker.fail("main symbol must be a function");
        if (main_entry.info >> 4 != 1) return checker.fail("main symbol must have global binding");
        if (heap_start.value >= heap_end.value) return checker.fail("guest heap is empty or inverted");

        return .{ .load_count = loads.len };
    }
};

/// The attribute waiver covers conformance deviation:
/// the vendor static library declares `A` while contributing no atomic
/// instructions. The `.text` opcode scan stays unconditional, so the waiver
/// never excuses actual atomics.
const CheckOptions = struct {
    require_target: bool = false,
    allow_attribute_a: bool = false,
};

const Options = struct {
    path: []const u8,
    check: CheckOptions = .{},
};

fn parseOptions(init: std.process.Init, allocator: Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var path: ?[]const u8 = null;
    var check: CheckOptions = .{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--require-rv64im-zicclsm")) {
            check.require_target = true;
        } else if (std.mem.eql(u8, arg, "--allow-attribute-a")) {
            check.allow_attribute_a = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("usage: check-guest-elf [--require-rv64im-zicclsm [--allow-attribute-a]] ELF\n", .{});
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-") or path != null) {
            return error.InvalidArguments;
        } else {
            path = arg;
        }
    }
    if (check.allow_attribute_a and !check.require_target) return error.InvalidArguments;
    return .{ .path = path orelse return error.InvalidArguments, .check = check };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const options = parseOptions(init, allocator) catch {
        std.debug.print("usage: check-guest-elf [--require-rv64im-zicclsm [--allow-attribute-a]] ELF\n", .{});
        std.process.exit(2);
    };
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, options.path, allocator, max_elf_bytes) catch |err| {
        std.debug.print("check-guest-elf: {s}: {s}\n", .{ options.path, @errorName(err) });
        std.process.exit(1);
    };
    var checker: Checker = .{ .allocator = allocator, .data = data };
    const summary = checker.check(options.check) catch {
        std.debug.print("check-guest-elf: {s}: {s}\n", .{ options.path, checker.failure });
        std.process.exit(1);
    };
    std.debug.print(
        "check-guest-elf: {s}: ELF64 RISC-V ET_EXEC, {d} non-overlapping PT_LOAD segments, W^X, canonical entry and heap symbols\n",
        .{ options.path, summary.load_count },
    );
}

fn writeTestInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn testHeader(flags: u32) [64]u8 {
    var bytes = [_]u8{0} ** 64;
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    writeTestInt(u16, &bytes, 16, 2);
    writeTestInt(u16, &bytes, 18, 243);
    writeTestInt(u32, &bytes, 20, 1);
    writeTestInt(u32, &bytes, 48, flags);
    writeTestInt(u16, &bytes, 52, 64);
    return bytes;
}

test "rejects compressed-instruction ELF flag" {
    const bytes = testHeader(1);
    var checker: Checker = .{ .allocator = std.testing.allocator, .data = &bytes };
    try std.testing.expectError(error.InvalidElf, checker.check(.{}));
    try std.testing.expectEqualStrings("RISC-V compressed-instruction flag is forbidden", checker.failure);
}

test "accepts required architecture attributes" {
    var checker: Checker = .{ .allocator = std.testing.allocator, .data = "" };
    try checker.checkArchitecture("\x00rv64i2p1_m2p0_zicclsm1p0_zicsr2p0\x00", false);
}

test "rejects atomic architecture attributes" {
    var checker: Checker = .{ .allocator = std.testing.allocator, .data = "" };
    defer if (!std.mem.eql(u8, checker.failure, "invalid ELF")) std.testing.allocator.free(checker.failure);
    try std.testing.expectError(
        error.InvalidElf,
        checker.checkArchitecture("\x00rv64i2p1_m2p0_zicclsm1p0_zaamo1p0_zalrsc1p0\x00", false),
    );
    try std.testing.expectEqualStrings("RISC-V target declares forbidden extension: zaamo1p0", checker.failure);
}

test "waives only the atomic attribute family when allowed" {
    var checker: Checker = .{ .allocator = std.testing.allocator, .data = "" };
    try checker.checkArchitecture("\x00rv64i2p1_m2p0_a2p1_zicclsm1p0_zaamo1p0_zalrsc1p0\x00", true);

    defer if (!std.mem.eql(u8, checker.failure, "invalid ELF")) std.testing.allocator.free(checker.failure);
    try std.testing.expectError(
        error.InvalidElf,
        checker.checkArchitecture("\x00rv64i2p1_m2p0_a2p1_zicclsm1p0_d2p2\x00", true),
    );
    try std.testing.expectEqualStrings("RISC-V target declares forbidden extension: d2p2", checker.failure);
}
