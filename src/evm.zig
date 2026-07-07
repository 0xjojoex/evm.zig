const std = @import("std");

pub const address = @import("./address.zig");
pub const BlockHashSource = @import("./BlockHashSource.zig");
pub const c_api = @import("./c_api.zig");
pub const code = @import("./code.zig");
pub const definition = @import("./definition.zig");
pub const ExecutionConfig = @import("./ExecutionConfig.zig");
pub const easm = @import("./easm.zig");
pub const eth = @import("./eth.zig");
pub const executor = @import("./executor.zig");
pub const Host = @import("./Host.zig");
pub const instruction = @import("./instruction.zig");
pub const Interpreter = @import("./Interpreter.zig");
pub const precompile = @import("./precompile.zig");
pub const protocol = @import("./protocol.zig");
pub const rlp = @import("./rlp.zig");
pub const state = @import("./state.zig");
pub const t = @import("./t.zig");
pub const trace = @import("./trace.zig");
pub const transaction = @import("./transaction.zig");
pub const transaction_envelope = @import("./transaction_envelope.zig");
pub const uint256 = @import("./uint256.zig");

const opcode = @import("./opcode.zig");
const vm = @import("./vm.zig");

pub const Executor = executor.Executor;
pub const Vm = vm.Vm;
pub const eip7702 = executor.eip7702;

pub const Bytecode = code.Bytecode;
pub const Opcode = opcode.Opcode;
pub const OpcodeInfo = opcode.OpInfo;
pub const Address = address.Address;
pub const addr = address.addr;

pub const empty_code_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

pub const EthProtocol = eth.Protocol;
pub const EthExecutor = Executor(EthProtocol);
pub const Evm = Vm(EthProtocol);
pub const StateReader = vm.StateReader;
pub const Env = vm.Env;
pub const Transaction = EthProtocol.Transaction.Value;
pub const TxStatus = vm.TxStatus;
pub const TxResult = vm.TxResultFor(EthProtocol);
pub const TxReceiptView = vm.TxReceiptView;
pub const BlockSession = Evm.BlockSession;
pub const BlockResult = vm.BlockResult;
pub const Log = vm.Log;
pub const SystemCall = vm.SystemCall;
pub const Committer = vm.Committer;
pub const AccountView = vm.AccountView;
pub const RuntimeResources = vm.RuntimeResources;
pub const BoundedRuntimeResources = vm.BoundedRuntimeResources;

pub const Definition = definition.Definition;
pub const RevisionConfig = definition.RevisionConfig;
pub const RevisionModel = definition.RevisionModel;

pub const Protocol = protocol.Protocol;

pub fn calcWordSize(comptime T: type, size: T) T {
    return @divFloor(size + 31, 32);
}

test "protocol definition plugs into existing runtime code" {
    const Cancun = eth.fork(.cancun);

    try std.testing.expectEqual(protocol.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(protocol.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expect(Cancun.support.min == .cancun);
    try std.testing.expect(Cancun.support.max == .cancun);
    try std.testing.expect(Cancun.hot_cold_dispatch_enabled);
    try std.testing.expect(@hasDecl(Vm(Cancun), "transact"));
    try std.testing.expect(@hasDecl(Executor(Cancun), "runStandalone"));
    try std.testing.expect(@hasDecl(Interpreter.For(Cancun), "execute"));

    var evm = Vm(Cancun).init(std.testing.allocator, .{ .revision = .cancun });
    defer evm.deinit();

    const result = try evm.executor.runStandalone(evm.env.txContext(addr(0xaaaa), 0, 100_000, &.{}), .{
        .call = .{
            .sender = addr(0xaaaa),
            .recipient = addr(0xbbbb),
            .gas = 100_000,
        },
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.expectCall().status);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("./eth/config.zig");
    _ = @import("./test.zig");
}
