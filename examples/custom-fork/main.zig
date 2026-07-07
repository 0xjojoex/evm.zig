const std = @import("std");
const evmz = @import("evmz");

const Revision = evmz.eth.Revision;

const CustomFork = evmz.eth.define(.{
    .name = "custom-fork",
    .Transaction = .{
        .maxInitcodeSize = maxInitcodeSize,
    },
    .Settlement = .{
        .gasRefundCapDivisor = gasRefundCapDivisor,
    },
    .Authorization = .{
        .warmsDelegatedTarget = warmsDelegatedTarget,
    },
    .Block = .{
        .transactionWarmsCoinbase = transactionWarmsCoinbase,
    },
    .Create = .{
        .createCodeSizeLimit = createCodeSizeLimit,
        .createInitCodeSizeLimit = createInitCodeSizeLimit,
    },
});
const CustomDefinition = evmz.definition.Bound(CustomFork);

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
}

pub fn main(_: std.process.Init) !void {
    const CustomProtocol = evmz.Protocol(CustomFork, .{ .support = CustomDefinition.Support.at(.cancun) });
    const CustomVm = evmz.Vm(CustomProtocol);

    var vm = CustomVm.init(std.heap.page_allocator, .{ .revision = .cancun });
    defer vm.deinit();

    if (CustomProtocol.Create.createCodeSizeLimit(.cancun) != 0x8000) return error.CustomLimitMismatch;
    if (CustomProtocol.Transaction.maxInitcodeSize(.cancun) != 0x10000) return error.CustomTransactionLimitMismatch;
    if (CustomProtocol.Settlement.gasRefundCapDivisor(.cancun) != 4) return error.CustomSettlementMismatch;
    if (!CustomProtocol.Authorization.warmsDelegatedTarget(.prague)) return error.CustomAuthorizationMismatch;
    if (!CustomProtocol.Block.transactionWarmsCoinbase(.london)) return error.CustomBlockMismatch;
    std.debug.print("{s}: code size limit {d}\n", .{ CustomDefinition.name, CustomProtocol.Create.createCodeSizeLimit(.cancun).? });
}
