const std = @import("std");
const support = @import("vm_support.zig");

const evmz = support.evmz;
const Default = support.Default;
const addr = support.addr;
const Env = support.Env;
const MemoryStore = support.MemoryStore;
const transact = support.transact;
const expectRejected = support.expectRejected;

test "supported state domains analyze as complete VM products" {
    const Tracked = evmz.Vm(evmz.eth.amsterdam);
    const Dense = evmz.BalStatelessVm(evmz.eth.amsterdam);

    analyzeEngineProduct(Tracked);
    analyzeEngineProduct(Dense);

    std.testing.refAllDecls(evmz.eth.BlockSTF.Bind(.amsterdam, Tracked));
    std.testing.refAllDecls(evmz.eth.BlockSTF.Bind(.amsterdam, Dense));
}

test "exact Engine derives one coherent transaction authoring chain" {
    const ExactVm = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const ExactEngine = evmz.Engine(ExactVm.spec);
    const Input = struct {
        env: evmz.Env,
        tx: evmz.Transaction,
        progress: evmz.transaction.PreparationBlockProgress = .{},
    };
    const Context = ExactEngine.Context(Input);
    const SourceContext = evmz.transaction.program.ContextType(
        ExactVm.spec,
        ExactVm.StateDomain.Execution,
        .{},
        Input,
    );
    const Transition = ExactEngine.EthereumTransition(Input);
    const ExpectedTransact = fn (
        *Context,
        evmz.Transaction,
    ) (Context.Error || error{Overflow})!evmz.transaction.TransitionOutcomeType(
        evmz.TxExecutionResult,
        evmz.transaction.validation.ValidationError,
    );

    comptime {
        std.debug.assert(ExactEngine.Executor == ExactVm.Executor);
        std.debug.assert(!@hasDecl(ExactEngine.Executor, "specification"));
        std.debug.assert(ExactVm.StateDomain.Execution == evmz.state_domain.Tracked.Execution);
        std.debug.assert(!@hasDecl(ExactEngine, "StateDomain"));
        std.debug.assert(SourceContext == Context);
        std.debug.assert(!@hasDecl(Context, "specification"));
        std.debug.assert(!@hasDecl(Context, "StateDomain"));
        std.debug.assert(!@hasDecl(Context, "compile_options"));
        std.debug.assert(@TypeOf(Transition.transact) == ExpectedTransact);
    }
}

test "Amsterdam BlockSTF combines spec and state capabilities" {
    const Tracked = evmz.Vm(evmz.eth.amsterdam);
    const Dense = evmz.BalStatelessVm(evmz.eth.amsterdam);
    const TrackedBlockStf = evmz.eth.BlockSTF.Bind(.amsterdam, Tracked);
    const DenseBlockStf = evmz.eth.BlockSTF.Bind(.amsterdam, Dense);

    comptime {
        std.debug.assert(Tracked.StateDomain.Lifecycle.supports_block_production);
        std.debug.assert(!Dense.StateDomain.Lifecycle.supports_block_production);
        std.debug.assert(Tracked.StateDomain.Lifecycle.supports_external_observation_capture);
        std.debug.assert(!Dense.StateDomain.Lifecycle.supports_external_observation_capture);
        std.debug.assert(@TypeOf(TrackedBlockStf.produce) != type);
        std.debug.assert(@TypeOf(TrackedBlockStf.produceAssumeDecoded) != type);
        std.debug.assert(@TypeOf(DenseBlockStf.produce) == type);
        std.debug.assert(@TypeOf(DenseBlockStf.produceAssumeDecoded) == type);
        std.debug.assert(@hasDecl(TrackedBlockStf.BalExecutor, "init"));
        std.debug.assert(!@hasDecl(DenseBlockStf.BalExecutor, "init"));
    }
}

fn analyzeEngineProduct(comptime Engine: type) void {
    std.testing.refAllDecls(Engine.Executor.State);
    std.testing.refAllDecls(Engine.Executor);
    std.testing.refAllDecls(Engine);
}

test "hand-written multi-variant family dispatches through ProgramType" {
    const Base = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const ExactEngine = evmz.Engine(Base.spec);
    const Executor = ExactEngine.Executor;

    const FamilyTransaction = union(enum) {
        small: u8,
        large: u16,
    };
    const FamilyOutput = union(enum) {
        small: u32,
        large: bool,
    };
    const FamilyRejection = union(enum) {
        small: error{SmallRejected},
        large: error{LargeRejected},
    };
    const FamilyInput = struct { tx: FamilyTransaction };
    const Context = ExactEngine.Context(FamilyInput);
    const Family = struct {
        pub fn transact(
            context: *Context,
            tx: FamilyTransaction,
        ) Context.Error!evmz.transaction.TransitionOutcomeType(FamilyOutput, FamilyRejection) {
            switch (tx) {
                .small => |value| {
                    if (value == 0) return .{ .rejected = .{ .small = error.SmallRejected } };
                    try context.beginTransaction();
                    return .{ .completed = .{ .small = value } };
                },
                .large => |value| {
                    if (value == 0) return .{ .rejected = .{ .large = error.LargeRejected } };
                    try context.beginTransaction();
                    return .{ .completed = .{ .large = value > 255 } };
                },
            }
        }
    };
    const Program = ExactEngine.Program(
        FamilyInput,
        FamilyOutput,
        FamilyRejection,
        Context.Error,
        Family,
    );

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const outcome = try Program.transact(&executor, .{ .tx = .{ .small = 7 } });
    const output = switch (outcome) {
        .rejected => return error.UnexpectedRejection,
        .executed => |executed| executed.retainResult(),
    };
    try std.testing.expectEqual(@as(u32, 7), output.small);
    try std.testing.expect(!executor.hasCurrentTransaction());

    // A rejected non-Ethereum branch must leave no pending executor state.
    const rejected = try Program.transact(&executor, .{ .tx = .{ .large = 0 } });
    switch (rejected) {
        .executed => return error.UnexpectedExecution,
        .rejected => |reason| try std.testing.expectEqual(error.LargeRejected, reason.large),
    }
    try std.testing.expect(!executor.hasCurrentTransaction());

    const executed_large = try Program.transact(&executor, .{ .tx = .{ .large = 300 } });
    switch (executed_large) {
        .rejected => return error.UnexpectedRejection,
        .executed => |executed| try std.testing.expect(executed.retainResult().large),
    }
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

    comptime {
        std.debug.assert(!@hasField(Cancun.Executor.Init, "revision"));
        std.debug.assert(!@hasField(Cancun.Executor, "revision_id"));
        std.debug.assert(Cancun.spec.transaction.max_initcode_size == evmz.eth.cancun.transaction.max_initcode_size);
        std.debug.assert(Cancun.Executor == evmz.executor.ExecutorType(
            Cancun.spec,
            Cancun.StateDomain.Execution,
            Cancun.compile_options,
        ));
    }

    try std.testing.expect(@hasDecl(Cancun, "transact"));
    try std.testing.expect(@hasDecl(Cancun, "BlockExecution"));
    try std.testing.expect(!@hasDecl(Cancun.BlockExecution.PreludeContext, "specification"));
    try std.testing.expect(!@hasDecl(Cancun, "beginBlock"));
    try std.testing.expect(!@hasDecl(Cancun, "Context"));
    try std.testing.expect(!@hasDecl(Cancun, "Transition"));
    try std.testing.expect(!@hasDecl(Cancun, "Program"));
    try std.testing.expect(!@hasDecl(Cancun, "Family"));
    try std.testing.expect(!@hasDecl(Cancun, "NamedFamily"));
    inline for (.{
        "TransactionLog",
        "TransactionLogs",
        "Prelude",
        "PreludeContext",
        "Gas",
        "Settlement",
    }) |name| try std.testing.expect(!@hasDecl(Cancun, name));
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
        std.debug.assert(Full.spec.transaction.max_initcode_size ==
            Slim.spec.transaction.max_initcode_size);
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
        std.debug.assert(Strict.spec.transaction.total_gas_limit.? == 20_000);
        std.debug.assert(Strict.spec.call.base_gas == London.spec.call.base_gas + 5);
        std.debug.assert(Strict.spec.create.initial_nonce == London.spec.create.initial_nonce);
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
