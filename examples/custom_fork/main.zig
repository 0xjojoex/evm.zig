const std = @import("std");
const evmz = @import("evmz");

const Revision = evmz.eth.Revision;

const CustomEvm = evmz.eth.extend(.{
    .support = .at(.cancun),
    .execution = .{
        .name = "custom-fork",
        .create = .{
            .createCodeSizeLimit = createCodeSizeLimit,
            .createInitCodeSizeLimit = createInitCodeSizeLimit,
        },
    },
    .transaction = .{
        .maxInitcodeSize = maxInitcodeSize,
        .transactionWarmsCoinbase = transactionWarmsCoinbase,
    },
    .settlement = .{
        .gasRefundCapDivisor = gasRefundCapDivisor,
    },
    .authorization = .{
        .warmsDelegatedTarget = warmsDelegatedTarget,
    },
});
const CustomExecutionProtocol = CustomEvm.ExecutionProtocol;
const CustomTransactionProtocol = CustomEvm.TransactionProtocol;

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
    if (CustomExecutionProtocol.create.createCodeSizeLimit(.cancun) != 0x8000) @compileError("custom create limit mismatch");
    if (CustomTransactionProtocol.transaction.maxInitcodeSize(.cancun) != 0x10000) @compileError("custom transaction limit mismatch");
    if (CustomTransactionProtocol.settlement.gasRefundCapDivisor(.cancun) != 4) @compileError("custom settlement mismatch");
    if (!CustomTransactionProtocol.authorization.warmsDelegatedTarget(.prague)) @compileError("custom authorization mismatch");
    if (!CustomTransactionProtocol.transaction.transactionWarmsCoinbase(.london)) @compileError("custom transaction warming mismatch");
}

pub fn main(_: std.process.Init) !void {
    if (CustomExecutionProtocol.create.createCodeSizeLimit(.cancun) != 0x8000) return error.CustomLimitMismatch;
    if (CustomTransactionProtocol.transaction.maxInitcodeSize(.cancun) != 0x10000) return error.CustomTransactionLimitMismatch;
    if (CustomTransactionProtocol.settlement.gasRefundCapDivisor(.cancun) != 4) return error.CustomSettlementMismatch;
    if (!CustomTransactionProtocol.authorization.warmsDelegatedTarget(.prague)) return error.CustomAuthorizationMismatch;
    if (!CustomTransactionProtocol.transaction.transactionWarmsCoinbase(.london)) return error.CustomTransactionWarmingMismatch;
    std.debug.print("custom-fork: code size limit {d}\n", .{CustomExecutionProtocol.create.createCodeSizeLimit(.cancun).?});
}
