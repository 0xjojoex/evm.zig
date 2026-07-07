//! Gas-derived resource upper-bound planner for bounded execution.
//!
//! This module is intentionally a pure estimator. It does not configure
//! `Executor` or allocate pools. The exact block policy uses `blockEnvelope` as
//! a reproducible checkpoint, but this remains an experimental gas-formula input
//! rather than the general bounded-resource policy API.
//!
//! The bounds are conservative sizing inputs, not consensus gas accounting. Some
//! resources have crisp gas formulas, such as EVM memory expansion, log data,
//! transient storage writes, and journal rows. Others, especially loaded account
//! maps and persistent storage overlay maps, are coarse planning estimates until
//! the executor has a more compact address-book representation.

const std = @import("std");
const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");
const uint256 = @import("../uint256.zig");

pub const default_call_depth_limit: usize = Host.max_call_depth;
pub const default_max_live_frames: usize = default_call_depth_limit + 1;
pub const stack_slots_per_frame: usize = 1024;
pub const word_bytes: usize = 32;

const legacy_max_code_size: usize = 0x6000;
const log_entry_gas: u64 = 375;
const log_data_byte_gas: u64 = 8;
const journal_entry_gas: u64 = 100;
const transient_entry_gas: u64 = 100;
const legacy_storage_overlay_entry_gas: u64 = 4800;
const legacy_create_warm_cost: u64 = 32_000;
const amsterdam_create_warm_cost: u64 = 11_000;

pub const Scope = enum {
    /// Apply per-transaction execution-gas caps from the selected revision.
    transaction,
    /// Use the supplied gas limit directly. This is useful for block-sized or
    /// prover-mode stress envelopes that are not yet tied to transaction
    /// validation.
    gas_budget,
};

pub fn InputFor(comptime Revision: type) type {
    return struct {
        revision: Revision = latestRevision(Revision),
        gas_limit: u64,
        scope: Scope = .transaction,
        max_live_frames: usize = default_max_live_frames,
        /// Accounts warmed before opcode execution, such as sender, tx target or
        /// created address, coinbase on applicable forks, and active precompiles.
        initial_warm_accounts: usize = 0,
    };
}

pub const MemoryBound = struct {
    /// Largest memory byte length a single frame can reach if it spends the
    /// entire gas budget only on memory expansion.
    ///
    /// This is a semantic boundary proof, not a value to multiply by
    /// `max_live_frames` or wire to `memory_bytes_per_frame`.
    one_frame_bytes: usize,
    /// Conservative maximum total live memory bytes across the current live call
    /// chain. Because the memory cost is convex, the maximum occurs when gas is
    /// spread roughly evenly across live frames.
    ///
    /// This is the value that should feed a future transaction-owned EVM memory
    /// pool, where active frames borrow and release bytes.
    total_live_bytes: usize,
    /// Number of live frames at the total-live-memory maximum.
    total_live_frames: usize,
    /// Per-frame byte length at the total-live-memory maximum.
    bytes_per_frame_at_total_max: usize,
};

pub const AccessBound = struct {
    accounts: usize,
    storage_keys: usize,
};

pub const StateBound = struct {
    accounts: usize,
    original_storage_entries: usize,
    storage_overlay_entries: usize,
    selfdestructed_accounts: usize,
    created_contracts: usize,
    deleted_accounts: usize,
    dirty_accounts: usize,
};

pub const LogBound = struct {
    entries: usize,
    data_bytes: usize,
};

pub fn PlanFor(comptime Revision: type) type {
    return struct {
        revision: Revision,
        scope: Scope,
        gas_limit: u64,
        /// Gas budget used by the planner after applying the selected scope.
        effective_gas_limit: u64,
        max_live_frames: usize,
        stack_slots: usize,
        stack_bytes: usize,
        memory: MemoryBound,
        logs: LogBound,
        journal_entries: usize,
        access: AccessBound,
        state: StateBound,
        transient_storage_entries: usize,
        max_code_bytes: usize,
        max_initcode_bytes: usize,
    };
}

pub const Error = error{
    InvalidMaxLiveFrames,
    CapacityOverflow,
};

fn latestRevision(comptime Revision: type) Revision {
    const values = std.enums.values(Revision);
    if (values.len == 0) @compileError("revision enum must have at least one value");
    return values[values.len - 1];
}

fn defaultRevisionForProtocol(comptime Protocol: type) Protocol.Revision {
    if (@hasDecl(Protocol, "support")) return Protocol.support.max;
    return latestRevision(Protocol.Revision);
}

pub fn For(comptime Protocol: type) type {
    return struct {
        const Self = @This();

        pub const Input = struct {
            revision: Protocol.Revision = defaultRevisionForProtocol(Protocol),
            gas_limit: u64,
            scope: Scope = .transaction,
            max_live_frames: usize = default_max_live_frames,
            /// Accounts warmed before opcode execution, such as sender, tx target or
            /// created address, coinbase on applicable forks, and active precompiles.
            initial_warm_accounts: usize = 0,
        };
        pub const Plan = PlanFor(Protocol.Revision);

        pub const BlockInput = struct {
            spec: Protocol.Revision = defaultRevisionForProtocol(Protocol),
            block_gas_limit: u64,
            max_live_frames: usize = default_max_live_frames,
        };

        pub const BlockResourceBound = struct {
            spec: Protocol.Revision,
            gas_limit: u64,
            effective_gas_limit: u64,
            state: StateBound,
        };

        pub const BlockEnvelope = struct {
            spec: Protocol.Revision,
            block_gas_limit: u64,
            /// Block-wide provisioning envelope for state that can accumulate
            /// across transactions before commit/discard.
            block: Self.BlockResourceBound,
            /// Largest single transaction sub-scope allowed inside the block.
            transaction: Self.Plan,
        };

        /// Estimate bounded-runtime resource capacities from a gas budget.
        ///
        /// Keep lifetime separate when mapping this plan into runtime resources:
        /// stack is per-frame, but EVM linear memory is transaction-wide live
        /// memory. Do not wire `memory.one_frame_bytes` as a per-frame executor
        /// cap.
        pub fn estimate(input: Input) Error!Plan {
            if (input.max_live_frames == 0) return error.InvalidMaxLiveFrames;

            const effective_gas_limit = Self.effectiveGasLimit(input.revision, input.gas_limit, input.scope);
            const stack_slots = try mul(usize, input.max_live_frames, stack_slots_per_frame);
            const stack_bytes = try mul(usize, stack_slots, word_bytes);
            const memory = try memoryBound(effective_gas_limit, input.max_live_frames);
            const log_entries = try countFromGas(effective_gas_limit, log_entry_gas);
            const log_data_bytes = try countFromGas(effective_gas_limit, log_data_byte_gas);
            const journal_entries = try countFromGas(effective_gas_limit, journal_entry_gas);
            const transient_entries = try countFromGas(effective_gas_limit, transient_entry_gas);
            const warm_accounts_from_gas = try countFromGas(effective_gas_limit, Self.accountWarmCost(input.revision));
            const warm_accounts = try add(usize, input.initial_warm_accounts, warm_accounts_from_gas);
            const warm_storage_keys = try countFromGas(effective_gas_limit, Self.storageKeyWarmCost(input.revision));
            const storage_overlay_entries = try countFromGas(effective_gas_limit, Self.storageOverlayEntryCost(input.revision));

            return .{
                .revision = input.revision,
                .scope = input.scope,
                .gas_limit = input.gas_limit,
                .effective_gas_limit = effective_gas_limit,
                .max_live_frames = input.max_live_frames,
                .stack_slots = stack_slots,
                .stack_bytes = stack_bytes,
                .memory = memory,
                .logs = .{
                    .entries = log_entries,
                    .data_bytes = log_data_bytes,
                },
                .journal_entries = journal_entries,
                .access = .{
                    .accounts = warm_accounts,
                    .storage_keys = warm_storage_keys,
                },
                .state = .{
                    .accounts = warm_accounts,
                    .original_storage_entries = storage_overlay_entries,
                    .storage_overlay_entries = storage_overlay_entries,
                    .selfdestructed_accounts = warm_accounts,
                    .created_contracts = try countFromGas(effective_gas_limit, Self.createWarmCost(input.revision)),
                    .deleted_accounts = warm_accounts,
                    .dirty_accounts = warm_accounts,
                },
                .transient_storage_entries = transient_entries,
                .max_code_bytes = Self.maxCodeSize(input.revision),
                .max_initcode_bytes = Protocol.Transaction.maxInitcodeSize(input.revision),
            };
        }

        pub fn blockEnvelope(input: Self.BlockInput) Error!Self.BlockEnvelope {
            const initial_warm_accounts = protocolWarmAccountReserve(input.spec);
            const block_plan = try Self.estimate(.{
                .spec = input.spec,
                .gas_limit = input.block_gas_limit,
                .scope = .gas_budget,
                .max_live_frames = input.max_live_frames,
                .initial_warm_accounts = initial_warm_accounts,
            });
            const tx_plan = try Self.estimate(.{
                .spec = input.spec,
                .gas_limit = input.block_gas_limit,
                .scope = .transaction,
                .max_live_frames = input.max_live_frames,
                .initial_warm_accounts = initial_warm_accounts,
            });
            return .{
                .spec = input.spec,
                .block_gas_limit = input.block_gas_limit,
                .block = .{
                    .spec = block_plan.spec,
                    .gas_limit = block_plan.gas_limit,
                    .effective_gas_limit = block_plan.effective_gas_limit,
                    .state = block_plan.state,
                },
                .transaction = tx_plan,
            };
        }

        pub fn effectiveGasLimit(revision: Protocol.Revision, gas_limit: u64, scope: Scope) u64 {
            return switch (scope) {
                .transaction => Protocol.Transaction.regularGasLimit(revision, gas_limit),
                .gas_budget => gas_limit,
            };
        }

        pub fn maxCodeSize(revision: Protocol.Revision) usize {
            return Protocol.Create.createCodeSizeLimit(revision) orelse legacy_max_code_size;
        }

        fn accountWarmCost(revision: Protocol.Revision) u64 {
            return Protocol.Transaction.accessListAddressGas(revision);
        }

        fn storageKeyWarmCost(revision: Protocol.Revision) u64 {
            return Protocol.Transaction.storageKeyGas(revision);
        }

        fn storageOverlayEntryCost(revision: Protocol.Revision) u64 {
            const state_gas = Protocol.Storage.sstoreStateGas(revision, .added);
            if (state_gas.charge <= 0) return legacy_storage_overlay_entry_gas;

            const storage_access = Protocol.Storage.sstoreStorageAccessGas(revision, .cold) orelse 0;
            const storage_write = Protocol.Storage.sstoreGas(revision, .added).cost;
            const regular_gas = std.math.add(i64, storage_access, storage_write) catch return std.math.maxInt(u64);
            return std.math.cast(u64, regular_gas) orelse std.math.maxInt(u64);
        }

        fn createWarmCost(revision: Protocol.Revision) u64 {
            if (Protocol.Transaction.intrinsicRegularGasLimit(revision) != null) return amsterdam_create_warm_cost;
            return legacy_create_warm_cost;
        }

        fn protocolWarmAccountReserve(revision: Protocol.Revision) usize {
            var count: usize = 2; // sender plus recipient or created address.
            if (Protocol.Block.transactionWarmsCoinbase(revision)) count += 1;
            if (Protocol.Authorization.warmsDelegatedTarget(revision)) count += 1;
            return count;
        }
    };
}

pub fn memoryBound(gas_limit: u64, max_live_frames: usize) Error!MemoryBound {
    if (max_live_frames == 0) return error.InvalidMaxLiveFrames;

    const one_frame_words = maxMemoryWordsForGas(gas_limit);
    const one_frame_bytes = try wordsToBytes(one_frame_words);
    var best_bytes: usize = 0;
    var best_frames: usize = 1;
    var best_per_frame_bytes: usize = 0;

    const end_frame = try add(usize, max_live_frames, 1);
    for (1..end_frame) |frames| {
        const per_frame_gas = ceilDiv(gas_limit, std.math.cast(u64, frames) orelse return error.CapacityOverflow);
        const words = maxMemoryWordsForGas(per_frame_gas);
        const per_frame_bytes = try wordsToBytes(words);
        const total_bytes = try mul(usize, frames, per_frame_bytes);
        if (total_bytes > best_bytes) {
            best_bytes = total_bytes;
            best_frames = frames;
            best_per_frame_bytes = per_frame_bytes;
        }
    }

    return .{
        .one_frame_bytes = one_frame_bytes,
        .total_live_bytes = best_bytes,
        .total_live_frames = best_frames,
        .bytes_per_frame_at_total_max = best_per_frame_bytes,
    };
}

pub fn memoryExpansionCostWords(words: u64) u128 {
    const wide_words: u128 = words;
    return (wide_words * wide_words) / 512 + 3 * wide_words;
}

pub fn maxMemoryWordsForGas(gas_limit: u64) u64 {
    var low: u64 = 0;
    var high: u64 = 1;
    while (memoryExpansionCostWords(high) <= gas_limit) {
        high = std.math.mul(u64, high, 2) catch break;
    }

    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        if (memoryExpansionCostWords(mid) <= gas_limit) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    return low;
}

fn countFromGas(gas_limit: u64, per_entry_gas: u64) Error!usize {
    return std.math.cast(usize, gas_limit / per_entry_gas) orelse error.CapacityOverflow;
}

fn wordsToBytes(words: u64) Error!usize {
    const bytes = std.math.mul(u64, words, word_bytes) catch return error.CapacityOverflow;
    return std.math.cast(usize, bytes) orelse error.CapacityOverflow;
}

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    std.debug.assert(denominator != 0);
    if (numerator == 0) return 0;
    return 1 + (numerator - 1) / denominator;
}

fn add(comptime T: type, a: T, b: T) Error!T {
    return std.math.add(T, a, b) catch error.CapacityOverflow;
}

fn mul(comptime T: type, a: T, b: T) Error!T {
    return std.math.mul(T, a, b) catch error.CapacityOverflow;
}

fn ethereumTestProtocol() type {
    const eth = @import("../eth.zig");
    return @import("../protocol.zig").ProtocolWithDispatch(eth.definition, eth.Support.all, .{});
}

fn ethereumTestPlanner() type {
    return For(ethereumTestProtocol());
}

test "bound gas plan input defaults to protocol support max" {
    const eth = @import("../eth.zig");
    const protocol = @import("../protocol.zig");
    const Cancun = protocol.ProtocolWithDispatch(eth.definition, eth.Support.at(.cancun), .{});
    const Planner = For(Cancun);
    const input = Planner.Input{ .gas_limit = 1_000_000 };

    try std.testing.expectEqual(eth.Revision.cancun, input.revision);
}

test "gas bound plan estimates 60M raw gas budget" {
    const Planner = ethereumTestPlanner();
    const plan = try Planner.estimate(.{
        .revision = .osaka,
        .gas_limit = 60_000_000,
        .scope = .gas_budget,
    });

    try std.testing.expectEqual(@as(u64, 60_000_000), plan.effective_gas_limit);
    try std.testing.expectEqual(@as(usize, default_max_live_frames), plan.max_live_frames);
    try std.testing.expectEqual(@as(usize, 33_587_200), plan.stack_bytes);
    try std.testing.expectEqual(@as(usize, 5_584_128), plan.memory.one_frame_bytes);
    try std.testing.expectEqual(@as(usize, 156_128_000), plan.memory.total_live_bytes);
    try std.testing.expectEqual(@as(usize, 1025), plan.memory.total_live_frames);
    try std.testing.expectEqual(@as(usize, 152_320), plan.memory.bytes_per_frame_at_total_max);
    try std.testing.expectEqual(@as(usize, 160_000), plan.logs.entries);
    try std.testing.expectEqual(@as(usize, 7_500_000), plan.logs.data_bytes);
    try std.testing.expectEqual(@as(usize, 600_000), plan.journal_entries);
    try std.testing.expectEqual(@as(usize, 600_000), plan.transient_storage_entries);
    try std.testing.expectEqual(@as(usize, 25_000), plan.access.accounts);
    try std.testing.expectEqual(@as(usize, 31_578), plan.access.storage_keys);
    try std.testing.expectEqual(@as(usize, 12_500), plan.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 0x6000), plan.max_code_bytes);
    try std.testing.expectEqual(@as(usize, 49_152), plan.max_initcode_bytes);
}

test "transaction scope applies Osaka transaction gas cap" {
    const Planner = ethereumTestPlanner();
    const plan = try Planner.estimate(.{
        .revision = .osaka,
        .gas_limit = 60_000_000,
    });

    try std.testing.expectEqual(@as(u64, 16_777_216), plan.effective_gas_limit);
    try std.testing.expectEqual(@as(usize, 2_941_344), plan.memory.one_frame_bytes);
    try std.testing.expectEqual(@as(usize, 73_045_600), plan.memory.total_live_bytes);
}

test "Amsterdam code and initcode limits are represented" {
    const Planner = ethereumTestPlanner();
    const plan = try Planner.estimate(.{
        .revision = .amsterdam,
        .gas_limit = 60_000_000,
        .scope = .gas_budget,
    });

    try std.testing.expectEqual(@as(usize, 0x10000), plan.max_code_bytes);
    try std.testing.expectEqual(@as(usize, 131_072), plan.max_initcode_bytes);
    try std.testing.expectEqual(@as(usize, 20_000), plan.access.accounts);
    try std.testing.expectEqual(@as(usize, 20_000), plan.access.storage_keys);
    try std.testing.expectEqual(@as(usize, 4_615), plan.state.storage_overlay_entries);
}

test "memory word inversion brackets the expansion cost" {
    const words = maxMemoryWordsForGas(60_000_000);

    try std.testing.expect(memoryExpansionCostWords(words) <= 60_000_000);
    try std.testing.expect(memoryExpansionCostWords(words + 1) > 60_000_000);
    try std.testing.expectEqual(@as(u64, 174_504), words);
}

test "single frame memory boundary matches interpreter gas semantics" {
    const gas_limit: u64 = 60_000_000;
    const opcode_overhead: u64 = 9; // PUSH1 + PUSH32 + MSTORE.
    const target_words = maxMemoryWordsForGas(gas_limit - opcode_overhead);

    const success = try runMstoreMemoryBoundary(ethereumTestProtocol(), gas_limit, target_words);
    try std.testing.expectEqual(Interpreter.Status.success, success.status);
    try std.testing.expectEqual(try wordsToBytes(target_words), success.memory_len);
    try std.testing.expect(success.gas_left >= 0);

    const failure = try runMstoreMemoryBoundary(ethereumTestProtocol(), gas_limit, target_words + 1);
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, failure.status);
    try std.testing.expectEqual(@as(usize, 0), failure.memory_len);
    try std.testing.expectEqual(@as(i64, 0), failure.gas_left);
}

const MemoryRunResult = struct {
    status: Interpreter.Status,
    gas_left: i64,
    memory_len: usize,
};

fn runMstoreMemoryBoundary(comptime Protocol: type, gas_limit: u64, target_words: u64) !MemoryRunResult {
    var code = mstoreAtWordBoundaryCode(target_words);
    var host: Host = undefined;
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = std.math.cast(i64, gas_limit) orelse return error.CapacityOverflow,
        .recipient = std.mem.zeroes([20]u8),
        .sender = std.mem.zeroes([20]u8),
        .input_data = &.{},
        .value = 0,
    };

    var owned = try Interpreter.OwnedCallFrame(Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .osaka,
    });
    defer owned.deinit();

    var interpreter = owned.interpreter();
    const result = try interpreter.execute();
    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .memory_len = owned.frame.memory.len(),
    };
}

fn mstoreAtWordBoundaryCode(target_words: u64) [37]u8 {
    std.debug.assert(target_words != 0);
    const offset: u256 = (@as(u256, target_words) - 1) * word_bytes;
    var result: [37]u8 = undefined;
    result[0] = 0x60; // PUSH1
    result[1] = 0xaa;
    result[2] = 0x7f; // PUSH32
    uint256.writeBytes32(result[3..35], offset);
    result[35] = 0x52; // MSTORE
    result[36] = 0x00; // STOP
    return result;
}
