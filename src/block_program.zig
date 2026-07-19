//! Typed block-fold program bound above one transaction runtime.
//!
//! The program owns block environment, cumulative fold state, inclusion
//! planning, and included/result representation. The bound runtime owns one
//! exclusive Executor block claim. Scheduling and whole-block validation stay
//! above this layer.

pub fn TransactOutcome(comptime Included: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        included: Included,
    };
}

/// First-class block fold program with lexical public carriers for ZLS.
pub fn BlockProgram(
    comptime TxT: type,
    comptime OutputT: type,
    comptime RejectionT: type,
    comptime EnvT: type,
    comptime IncludedT: type,
    comptime ResultT: type,
    comptime ImplT: type,
) type {
    const TransactionType = TxT;
    const OutputType = OutputT;
    const RejectionType = RejectionT;
    const EnvironmentType = EnvT;
    const IncludedType = IncludedT;
    const ResultType = ResultT;
    const ImplementationType = ImplT;

    return struct {
        pub const Transaction = TransactionType;
        pub const Output = OutputType;
        pub const Rejection = RejectionType;
        pub const Environment = EnvironmentType;
        pub const Included = IncludedType;
        pub const Result = ResultType;
        pub const Implementation = ImplementationType;

        pub fn bind(
            comptime TransactionRuntimeType: type,
            comptime BlockPolicyType: type,
            comptime default_block_policy: BlockPolicyType,
        ) type {
            comptime {
                if (TransactionRuntimeType.Transaction != TransactionType)
                    @compileError("block transaction type does not match transaction runtime");
                if (TransactionRuntimeType.Output != OutputType)
                    @compileError("block output type does not match transaction runtime");
                if (TransactionRuntimeType.Rejection != RejectionType)
                    @compileError("block rejection type does not match transaction runtime");
                if (!@hasDecl(ImplementationType, "PreludeError"))
                    @compileError("block program implementation must declare PreludeError");
            }
            const RuntimeWithPrelude = if (ImplementationType.PreludeError == error{})
                TransactionRuntimeType
            else
                TransactionRuntimeType.withPreludeError(ImplementationType.PreludeError);
            return BoundBlockProgram(
                TransactionRuntimeType,
                RuntimeWithPrelude,
                TransactionType,
                OutputType,
                RejectionType,
                EnvironmentType,
                IncludedType,
                ResultType,
                ImplementationType,
                BlockPolicyType,
                default_block_policy,
            );
        }
    };
}

fn BoundBlockProgram(
    comptime BaseTransactionRuntimeType: type,
    comptime TransactionRuntimeType: type,
    comptime TransactionType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime EnvironmentType: type,
    comptime IncludedType: type,
    comptime ResultType: type,
    comptime ImplementationType: type,
    comptime BlockPolicyType: type,
    comptime default_block_policy: BlockPolicyType,
) type {
    const OutcomeType = TransactOutcome(IncludedType, RejectionType);
    const ContractError = error{
        UncommittedChanges,
    };
    const ErrorType = TransactionRuntimeType.Error || ImplementationType.Error || ContractError;
    comptime validateImplementation(
        TransactionRuntimeType,
        TransactionType,
        OutputType,
        EnvironmentType,
        IncludedType,
        ResultType,
        ImplementationType,
    );

    return struct {
        const Self = @This();

        pub const TransactionRuntime = TransactionRuntimeType;
        pub const Executor = TransactionRuntimeType.Executor;
        pub const Transaction = TransactionType;
        pub const Output = OutputType;
        pub const Rejection = RejectionType;
        pub const Prelude = TransactionRuntimeType.Prelude;
        pub const PreludeContext = TransactionRuntimeType.PreludeContext;
        pub const Environment = EnvironmentType;
        pub const Included = IncludedType;
        pub const Result = ResultType;
        pub const BlockPolicy = BlockPolicyType;
        pub const block_policy = default_block_policy;
        pub const Outcome = OutcomeType;
        pub const Error = ErrorType;

        transaction_runtime: TransactionRuntimeType,
        policy_value: BlockPolicyType,
        claim: Executor.BlockExecutionClaim,
        environment: Environment,
        state: ImplementationType.State,
        finished: bool = false,

        pub fn init(
            executor: *Executor,
            environment: Environment,
        ) Error!Self {
            return initWithRuntime(
                BaseTransactionRuntimeType.init(executor),
                environment,
            );
        }

        /// Advanced composition seam for a preconfigured transaction runtime.
        pub fn initWithRuntime(
            transaction_runtime: BaseTransactionRuntimeType,
            environment: Environment,
        ) Error!Self {
            return initRuntimeWithBlockPolicy(
                transaction_runtime,
                default_block_policy,
                environment,
            );
        }

        /// Select both runtime policy values without changing program identity.
        pub fn initWithPolicies(
            executor: *Executor,
            transaction_policy: BaseTransactionRuntimeType.TransactionPolicy,
            block_policy_value: BlockPolicyType,
            environment: Environment,
        ) Error!Self {
            return initRuntimeWithBlockPolicy(
                BaseTransactionRuntimeType.initWithPolicy(executor, transaction_policy),
                block_policy_value,
                environment,
            );
        }

        fn initRuntimeWithBlockPolicy(
            transaction_runtime: BaseTransactionRuntimeType,
            policy_value_arg: BlockPolicyType,
            environment: Environment,
        ) Error!Self {
            const runtime = transaction_runtime.rebindPreludeError(ImplementationType.PreludeError);
            const executor = runtime.executorPtr();
            if (executor.hasActiveBlockExecution()) return error.BlockExecutionActive;
            if (executor.hasCurrentTransaction()) return error.ExecutedTransactionActive;
            if (executor.hasChanges()) return error.UncommittedChanges;
            return .{
                .transaction_runtime = runtime,
                .policy_value = policy_value_arg,
                .claim = executor.claimBlockExecution() catch |err| return Executor.normalizeError(err),
                .environment = environment,
                .state = ImplementationType.init(environment),
            };
        }

        pub fn policy(self: *const Self) *const BlockPolicyType {
            return &self.policy_value;
        }

        pub fn executorPtr(self: *const Self) *Executor {
            return self.transaction_runtime.executorPtr();
        }

        pub fn transact(self: *Self, transaction_value: Transaction) Error!Outcome {
            return self.transactOwned(transaction_value, null);
        }

        /// Fold one transaction whose family prelude shares the transaction
        /// program's journaled retain/discard lifetime.
        pub fn transactWithPrelude(
            self: *Self,
            transaction_value: Transaction,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transactOwned(transaction_value, prelude);
        }

        fn transactOwned(
            self: *Self,
            transaction_value: Transaction,
            prelude: ?Prelude,
        ) Error!Outcome {
            if (self.finished) return error.BlockExecutionFinished;
            const input = ImplementationType.transactInput(
                &self.environment,
                &self.state,
                &transaction_value,
            );
            const outcome = if (prelude) |value|
                try self.transaction_runtime.transactInBlockWithPrelude(
                    input,
                    self.claim,
                    value,
                )
            else
                try self.transaction_runtime.transactInBlock(input, self.claim);
            return switch (outcome) {
                .rejected => |reason| .{ .rejected = reason },
                .executed => |executed_value| blk: {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    const view = try executed.view();
                    const plan = try ImplementationType.planInclude(
                        &self.environment,
                        &self.state,
                        &transaction_value,
                        view.output,
                        view.logs,
                    );
                    const included = ImplementationType.included(
                        &transaction_value,
                        view.output,
                        view.logs,
                        plan,
                    );
                    try executed.retain();
                    ImplementationType.applyInclude(&self.state, plan);
                    break :blk .{ .included = included };
                },
            };
        }

        pub fn progress(self: *const Self) Result {
            return ImplementationType.finish(&self.environment, &self.state);
        }

        pub fn finish(self: *Self) Error!Result {
            if (self.finished) return error.BlockExecutionFinished;
            try self.claim.requireFor(self.executorPtr());
            const result = ImplementationType.finish(&self.environment, &self.state);
            self.claim.release();
            self.finished = true;
            return result;
        }

        pub fn discardIfUnfinished(self: *Self) void {
            if (self.finished) return;
            self.claim.requireFor(self.executorPtr()) catch return;
            self.executorPtr().discardChanges();
            self.claim.release();
            self.finished = true;
        }
    };
}

fn validateImplementation(
    comptime TransactionRuntimeType: type,
    comptime TransactionType: type,
    comptime OutputType: type,
    comptime EnvironmentType: type,
    comptime IncludedType: type,
    comptime ResultType: type,
    comptime Implementation: type,
) void {
    if (!@hasDecl(Implementation, "State"))
        @compileError("block program implementation must declare State");
    if (!@hasDecl(Implementation, "InclusionPlan"))
        @compileError("block program implementation must declare InclusionPlan");
    if (!@hasDecl(Implementation, "Error"))
        @compileError("block program implementation must declare Error");
    if (!@hasDecl(Implementation, "PreludeError"))
        @compileError("block program implementation must declare PreludeError");
    if (@TypeOf(Implementation.init(@as(EnvironmentType, undefined))) != Implementation.State)
        @compileError("block program init has the wrong signature");
    if (@TypeOf(Implementation.transactInput(
        @as(*const EnvironmentType, undefined),
        @as(*const Implementation.State, undefined),
        @as(*const TransactionType, undefined),
    )) != TransactionRuntimeType.TransactInput) @compileError("block program transactInput has the wrong signature");
    if (@TypeOf(Implementation.planInclude(
        @as(*const EnvironmentType, undefined),
        @as(*const Implementation.State, undefined),
        @as(*const TransactionType, undefined),
        @as(*const OutputType, undefined),
        @as([]const TransactionRuntimeType.TransactionLog, undefined),
    )) != Implementation.Error!Implementation.InclusionPlan) @compileError("block program planInclude has the wrong signature");
    if (@TypeOf(Implementation.included(
        @as(*const TransactionType, undefined),
        @as(*const OutputType, undefined),
        @as([]const TransactionRuntimeType.TransactionLog, undefined),
        @as(Implementation.InclusionPlan, undefined),
    )) != IncludedType) @compileError("block program included has the wrong signature");
    if (@TypeOf(Implementation.applyInclude(
        @as(*Implementation.State, undefined),
        @as(Implementation.InclusionPlan, undefined),
    )) != void) @compileError("block program applyInclude must be infallible");
    if (@TypeOf(Implementation.finish(
        @as(*const EnvironmentType, undefined),
        @as(*const Implementation.State, undefined),
    )) != ResultType) @compileError("block program finish has the wrong signature");
}
