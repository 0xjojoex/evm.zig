const std = @import("std");
const support = @import("vm_support.zig");

const evmz = support.evmz;
const transaction = support.transaction;
const Default = support.Default;
const addr = support.addr;
const Env = support.Env;
const MemoryStore = support.MemoryStore;
const transact = support.transact;
const expectRejected = support.expectRejected;

test "supported state domains analyze as complete engine products" {
    const Tracked = evmz.Vm(evmz.eth.amsterdam);
    const Dense = evmz.BalStatelessVm(evmz.eth.amsterdam);

    analyzeEngineProduct(Tracked);
    analyzeEngineProduct(Dense);

    std.testing.refAllDecls(evmz.eth.BlockSTF.Bind(.amsterdam, Tracked));
    std.testing.refAllDecls(evmz.eth.BlockSTF.Bind(.amsterdam, Dense));
}

test "dense BlockSTF does not expose callable block production" {
    const Tracked = evmz.Vm(evmz.eth.amsterdam);
    const Dense = evmz.BalStatelessVm(evmz.eth.amsterdam);
    const TrackedBlockStf = evmz.eth.BlockSTF.Bind(.amsterdam, Tracked);
    const DenseBlockStf = evmz.eth.BlockSTF.Bind(.amsterdam, Dense);

    comptime {
        std.debug.assert(Tracked.BlockState.block_production);
        std.debug.assert(!Dense.BlockState.block_production);
        std.debug.assert(@TypeOf(TrackedBlockStf.produce) != type);
        std.debug.assert(@TypeOf(TrackedBlockStf.produceAssumeDecoded) != type);
        std.debug.assert(@TypeOf(DenseBlockStf.produce) == type);
        std.debug.assert(@TypeOf(DenseBlockStf.produceAssumeDecoded) == type);
    }
}

test "ordinary VM constructs executor state through its state domain" {
    const ExactVm = evmz.Vm(evmz.eth.amsterdam);

    comptime {
        std.debug.assert(ExactVm.BlockState.State == evmz.state.TrackedState);
        std.debug.assert(@hasField(ExactVm.Executor.Init, "state"));
        std.debug.assert(@hasField(ExactVm.Executor.Init, "services"));
        std.debug.assert(@hasField(ExactVm.BlockState.ExecutorStateInit, "reader"));
    }

    var executor = ExactVm.Executor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try std.testing.expect(executor.state.reader == null);
}

fn analyzeEngineProduct(comptime Engine: type) void {
    std.testing.refAllDecls(Engine.BlockState.State);
    std.testing.refAllDecls(Engine.Executor);
    std.testing.refAllDecls(Engine);
}

test "Env execution context derives opcode-visible gas limit from the environment" {
    const origin = addr(0xaaaa);
    const env = Env{ .chain_id = 10, .gas_limit = 30_000_000 };
    const context = env.executionContext(.{ .origin = origin, .gas_price = 7 });

    try std.testing.expectEqual(@as(u256, 10), context.chain.chain_id);
    try std.testing.expectEqual(@as(u64, 30_000_000), context.block.gas_limit);
    try std.testing.expectEqual(origin, context.transaction.origin);
    try std.testing.expectEqual(@as(u256, 7), context.transaction.gas_price);
}

test "exact VM closes the complete spec without revision state" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const Cancun = evmz.Vm(evmz.eth.cancun);
    const Context = Cancun.Context(Cancun.TransactInput);
    const Transition = Cancun.Transition(Cancun.TransactInput);
    const TransitionContextPointer = @typeInfo(@TypeOf(Transition.transact)).@"fn".params[0].type.?;

    comptime {
        std.debug.assert(!@hasField(Cancun.Executor.Init, "revision"));
        std.debug.assert(!@hasField(Cancun.Executor, "revision_id"));
        std.debug.assert(Cancun.specification.transaction.max_initcode_size == evmz.eth.cancun.transaction.max_initcode_size);
        std.debug.assert(@typeInfo(TransitionContextPointer).pointer.child == Context);
        std.debug.assert(Cancun.Executor == evmz.executor.ExecutorType(
            Cancun.specification,
            Cancun.BlockState,
            Cancun.compile_options,
        ));
    }

    try std.testing.expect(@hasDecl(Cancun, "transact"));
    try std.testing.expect(@hasDecl(Cancun, "Program"));
    try std.testing.expect(@hasDecl(Cancun, "BlockExecution"));
    try std.testing.expect(@hasDecl(Cancun, "Sequential"));
    try std.testing.expect(!@hasDecl(Cancun, "TransactionPolicy"));
    try std.testing.expect(!@hasDecl(Cancun, "ExecutionProtocol"));
}

test "exact VM compile options can opt into step capture" {
    const Slim = evmz.Vm(evmz.eth.amsterdam);
    const Full = evmz.VmWithOptions(evmz.eth.amsterdam, .{ .step_capture = true });

    comptime {
        std.debug.assert(Full != Slim);
        std.debug.assert(Full.Executor != Slim.Executor);
        std.debug.assert(Full.compile_options.step_capture);
        std.debug.assert(!Slim.compile_options.step_capture);
        std.debug.assert(Full.specification.transaction.max_initcode_size ==
            Slim.specification.transaction.max_initcode_size);
    }
}

test "Spec.extend creates a distinct exact VM from static values" {
    if (comptime !evmz.t.forkEnabled(.london)) return error.SkipZigTest;
    const Strict = evmz.Vm(evmz.eth.london.extend(.{
        .transaction = .{ .total_gas_limit = .{ .replace = 20_000 } },
        .call = .{ .base_gas = evmz.eth.london.call.base_gas + 5 },
    }));
    const London = evmz.Vm(evmz.eth.london);

    comptime {
        std.debug.assert(Strict != London);
        std.debug.assert(Strict.Executor != London.Executor);
        std.debug.assert(Strict.specification.transaction.total_gas_limit.? == 20_000);
        std.debug.assert(Strict.specification.call.base_gas == London.specification.call.base_gas + 5);
        std.debug.assert(Strict.specification.create.initial_nonce == London.specification.create.initial_nonce);
    }

    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try evmz.t.seedStoreAccount(&memory, addr(0xaaaa), .{ .balance = 10_000_000 });

    var executor = Strict.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();
    const outcome = try transact(Strict, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = addr(0xaaaa),
            .to = addr(0xbbbb),
            .gas_limit = 21_000,
        },
    });
    try std.testing.expectEqual(Strict.Rejection.gas_allowance_exceeded, try expectRejected(outcome));
}

test "custom transaction program remains bound to the exact Executor" {
    const Input = Default.TransactInput;
    const Context = Default.Context(Input);
    const Transition = Default.Transition(Input);
    const Program = Default.Program(
        transaction.Transaction,
        Input,
        Default.Output,
        Default.Rejection,
        Transition,
    );

    comptime {
        std.debug.assert(Program.Executor == Default.Executor);
        std.debug.assert(Program.Executor == evmz.executor.ExecutorType(
            Program.specification,
            Default.BlockState,
            Default.compile_options,
        ));
        std.debug.assert(Program.Context == Context);
        std.debug.assert(Program.Transaction == Default.Transaction);
        std.debug.assert(Program.Output == Default.Output);
        std.debug.assert(Program.Error != anyerror);
    }
}
