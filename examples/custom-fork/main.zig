const std = @import("std");
const evmz = @import("evmz");

const Revision = evmz.eth.Revision;

const CustomFork = evmz.eth.define(.{
    .name = "custom-fork",
    .transaction = .{
        .maxInitcodeSize = maxInitcodeSize,
    },
    .settlement = .{
        .gasRefundCapDivisor = gasRefundCapDivisor,
    },
    .authorization = .{
        .warmsDelegatedTarget = warmsDelegatedTarget,
    },
    .block = .{
        .transactionWarmsCoinbase = transactionWarmsCoinbase,
    },
    .create = .{
        .createCodeSizeLimit = createCodeSizeLimit,
        .createInitCodeSizeLimit = createInitCodeSizeLimit,
    },
});
const CustomVM = evmz.Vm(Revision, CustomFork, .{
    .support = .{ .min = .cancun, .max = .cancun },
});
const CustomProtocol = CustomVM.Protocol;

fn warmsDelegatedTarget(revision: Revision) bool {
    return revision.isImpl(.prague);
}

fn maxInitcodeSize(revision: Revision) usize {
    if (!revision.isImpl(.shanghai)) return std.math.maxInt(usize);
    return 0x10000;
}

fn transactionWarmsCoinbase(revision: Revision) bool {
    return revision.isImpl(.london);
}

fn gasRefundCapDivisor(revision: Revision) u64 {
    if (!revision.isImpl(.london)) return 2;
    return 4;
}

fn createCodeSizeLimit(revision: Revision) ?usize {
    if (!revision.isImpl(.spurious_dragon)) return null;
    return 0x8000;
}

fn createInitCodeSizeLimit(revision: Revision) ?usize {
    if (!revision.isImpl(.shanghai)) return null;
    return 0x10000;
}

comptime {
    evmz.protocol.assertValidDefinition(CustomFork);
    if (CustomProtocol.create.createCodeSizeLimit(.cancun) != 0x8000) @compileError("custom create limit mismatch");
    if (CustomProtocol.transaction.maxInitcodeSize(.cancun) != 0x10000) @compileError("custom transaction limit mismatch");
    if (CustomProtocol.settlement.gasRefundCapDivisor(.cancun) != 4) @compileError("custom settlement mismatch");
    if (!CustomProtocol.authorization.warmsDelegatedTarget(.prague)) @compileError("custom authorization mismatch");
    if (!CustomProtocol.block.transactionWarmsCoinbase(.london)) @compileError("custom block mismatch");
}

pub fn main(_: std.process.Init) !void {
    var vm = CustomVM.init(std.heap.page_allocator, .{ .revision = .cancun });
    defer vm.deinit();

    if (CustomProtocol.create.createCodeSizeLimit(.cancun) != 0x8000) return error.CustomLimitMismatch;
    if (CustomProtocol.transaction.maxInitcodeSize(.cancun) != 0x10000) return error.CustomTransactionLimitMismatch;
    if (CustomProtocol.settlement.gasRefundCapDivisor(.cancun) != 4) return error.CustomSettlementMismatch;
    if (!CustomProtocol.authorization.warmsDelegatedTarget(.prague)) return error.CustomAuthorizationMismatch;
    if (!CustomProtocol.block.transactionWarmsCoinbase(.london)) return error.CustomBlockMismatch;
    std.debug.print("{s}: code size limit {d}\n", .{ CustomFork.name, CustomProtocol.create.createCodeSizeLimit(.cancun).? });
}
