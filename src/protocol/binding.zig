const std = @import("std");

const types = @import("types.zig");
const validate = @import("validate.zig");
const dispatcher = @import("dispatcher.zig");
const instruction_mod = @import("instruction.zig");
const transaction_mod = @import("transaction.zig");
const definition_mod = @import("../definition.zig");
const address = @import("../address.zig");
const opcode_info = @import("../opcode.zig");
const precompile_mod = @import("../precompile.zig");
const precompile_runtime = @import("../execution/precompile_runtime.zig");
const tx_settlement = @import("../transaction/settlement.zig");
const support_mod = @import("support.zig");
const Resolution = support_mod.Resolution;

pub fn compileExecution(
    comptime execution_rules: anytype,
    comptime support_window: definition_mod.ExecutionModel(execution_rules).Support,
) type {
    return compileExecutionWithDispatch(execution_rules, support_window, .{});
}

/// Compile transaction rules above one resolved execution model.
///
/// The transaction layer owns preparation, settlement, and authorization
/// policy. It inherits revision context from the execution layer below and
/// never re-binds it: the support window is applied once, at the execution
/// binding, because only instruction dispatch has comptime revision shape.
/// Cross-layer reads stay explicit through `ExecutionProtocol`.
pub fn compileTransaction(
    comptime ExecutionProtocolType: type,
    comptime transaction_layer_rules: definition_mod.TransactionLayerRules(ExecutionProtocolType.Revision),
) type {
    const R = ExecutionProtocolType.Revision;
    const transaction_config: definition_mod.TransactionConfig(R) = transaction_layer_rules.transaction;
    const settlement_config: definition_mod.SettlementConfig(R) = transaction_layer_rules.settlement;
    const authorization_config: definition_mod.AuthorizationConfig(R) = transaction_layer_rules.authorization;

    return struct {
        pub const ExecutionProtocol = ExecutionProtocolType;

        pub const Revision = ExecutionProtocolType.Revision;
        pub const Support = ExecutionProtocolType.Support;
        pub const support = ExecutionProtocolType.support;

        pub const transaction = transaction_config;
        pub const settlement = settlement_config;
        pub const authorization = authorization_config;

        pub const Tx = transaction_mod.Ethereum;
        pub const Settlement = tx_settlement.Default;
    };
}

/// Compile block rules above one resolved transaction model.
///
/// The block layer owns block-sequencing system-call hooks. Everything else is
/// reached through the `TransactionProtocol` and `ExecutionProtocol` layer
/// references.
pub fn compileBlock(
    comptime TransactionProtocolType: type,
    comptime block_config: definition_mod.BlockConfig(TransactionProtocolType.Revision),
) type {
    return struct {
        pub const TransactionProtocol = TransactionProtocolType;
        pub const ExecutionProtocol = TransactionProtocolType.ExecutionProtocol;

        pub const Revision = TransactionProtocolType.Revision;
        pub const Support = TransactionProtocolType.Support;
        pub const support = TransactionProtocolType.support;

        pub const block = block_config;
    };
}

/// Compile the execution model used by Interpreter and Executor. Its type
/// identity is independent from transaction and block program customization.
pub fn compileExecutionWithDispatch(
    comptime execution_rules: anytype,
    comptime support_window: definition_mod.ExecutionModel(execution_rules).Support,
    comptime dispatch_config: dispatcher.DispatchConfig,
) type {
    const ExecutionModel = definition_mod.ExecutionModel(execution_rules);
    validate.assertDispatchContract(ExecutionModel);
    support_window.assertValid();
    const hot_cold_dispatch = dispatcher.useHotColdDispatch(dispatch_config);
    const InstructionFacts = instruction_mod.For(ExecutionModel, support_window);

    return struct {
        pub const Revision = ExecutionModel.Revision;
        pub const BaseRevision = ExecutionModel.BaseRevision;
        pub const revisions = ExecutionModel.revisions;
        pub const Support = ExecutionModel.Support;
        pub const Availability = ExecutionModel.Availability;
        pub const order = ExecutionModel.order;
        pub const isImpl = ExecutionModel.isImpl;
        pub const baseRevision = ExecutionModel.baseRevision;

        pub const support = support_window;
        pub const dispatch = dispatch_config;
        pub const hot_cold_dispatch_enabled = hot_cold_dispatch;

        pub const valueTransferLog = ExecutionModel.valueTransferLog;
        pub const call = ExecutionModel.call;
        pub const create = ExecutionModel.create;
        pub const storage = ExecutionModel.storage;
        pub const self_destruct = ExecutionModel.self_destruct;

        pub const Precompile = struct {
            pub fn active(revision: ExecutionModel.Revision, target: address.Address) bool {
                if (comptime std.meta.hasFn(ExecutionModel.Precompile, "active")) {
                    return ExecutionModel.Precompile.active(revision, target);
                }
                return ExecutionModel.Precompile.resolve(revision, target) != null;
            }

            pub fn execute(
                revision: ExecutionModel.Revision,
                target: address.Address,
                precompile_call: precompile_runtime.PrecompileCall,
            ) precompile_mod.Error!?precompile_runtime.PrecompileOutcome {
                const entry = ExecutionModel.Precompile.resolve(revision, target) orelse return null;
                return try ExecutionModel.Precompile.execute(revision, entry, precompile_call);
            }
        };

        const byte = struct {
            pub fn entry(comptime opcode_byte: u8) dispatcher.DispatchEntry {
                return dispatcher.resolveDispatchEntryByte(ExecutionModel, support_window, opcode_byte);
            }

            pub fn info(comptime opcode_byte: u8) opcode_info.OpInfo {
                return InstructionFacts.info(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn availability(comptime opcode_byte: u8) Resolution {
                return InstructionFacts.availability(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn tier(comptime opcode_byte: u8) dispatcher.OpcodeTier {
                return InstructionFacts.tier(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn executionTarget(comptime opcode_byte: u8) dispatcher.ExecutionTarget {
                return InstructionFacts.executionTarget(InstructionFacts.fromByte(opcode_byte));
            }

            pub fn staticGas(comptime opcode_byte: u8) dispatcher.StaticGas {
                return dispatcher.resolveStaticGasByte(ExecutionModel, support_window, opcode_byte);
            }

            pub fn staticGasConstant(comptime opcode_byte: u8) ?i64 {
                return switch (@This().staticGas(opcode_byte)) {
                    .constant => |gas| gas,
                    .revision_bands => null,
                };
            }
        };

        pub const Instruction = struct {
            pub const Value = InstructionFacts.Value;
            pub const Context = InstructionFacts.Context;

            pub fn fromByte(comptime opcode_byte: u8) Value {
                return InstructionFacts.fromByte(opcode_byte);
            }

            pub fn context(comptime value: Value) Context {
                return InstructionFacts.context(value);
            }

            pub fn entry(comptime value: Value) dispatcher.DispatchEntry {
                @setEvalBranchQuota(10_000);
                return switch (comptime @This().context(value)) {
                    .byte => |opcode_byte| byte.entry(opcode_byte),
                    .custom => dispatcher.resolveDispatchEntryInstruction(ExecutionModel, support_window, value),
                };
            }

            pub fn info(comptime value: Value) opcode_info.OpInfo {
                return InstructionFacts.info(value);
            }

            pub fn rawAvailability(comptime value: Value) ExecutionModel.Availability {
                return InstructionFacts.rawAvailability(value);
            }

            pub fn availability(comptime value: Value) Resolution {
                return InstructionFacts.availability(value);
            }

            pub fn staticGasForRevision(revision: ExecutionModel.Revision, comptime value: Value) i64 {
                return InstructionFacts.staticGasForRevision(revision, value);
            }

            pub fn tier(comptime value: Value) dispatcher.OpcodeTier {
                return InstructionFacts.tier(value);
            }

            pub fn executionTarget(comptime value: Value) dispatcher.ExecutionTarget {
                return InstructionFacts.executionTarget(value);
            }

            pub fn staticGas(comptime value: Value) dispatcher.StaticGas {
                return switch (comptime context(value)) {
                    .byte => |opcode_byte| byte.staticGas(opcode_byte),
                    .custom => dispatcher.resolveStaticGasInstruction(ExecutionModel, support_window, value),
                };
            }

            pub fn staticGasConstant(comptime value: Value) ?i64 {
                return switch (@This().staticGas(value)) {
                    .constant => |gas| gas,
                    .revision_bands => null,
                };
            }

            pub fn expByteGas(revision: ExecutionModel.Revision) i64 {
                return InstructionFacts.expByteGas(revision);
            }

            pub fn accountReadColdAccessGas(revision: ExecutionModel.Revision) ?i64 {
                return InstructionFacts.accountReadColdAccessGas(revision);
            }

            pub fn codeAccountAccessGas(revision: ExecutionModel.Revision, status: types.AccountAccessStatus) ?i64 {
                return InstructionFacts.codeAccountAccessGas(revision, status);
            }
        };

        pub fn dispatchTable() dispatcher.DispatchTable {
            return dispatcher.resolveDispatchTable(ExecutionModel, support_window);
        }
    };
}

fn instructionFor(comptime ProtocolType: type, comptime opcode: opcode_info.Opcode) ProtocolType.Instruction.Value {
    return ProtocolType.Instruction.fromByte(@intFromEnum(opcode));
}

test "layered protocol chain exposes resolved Ethereum facts" {
    const ethereum = @import("../eth.zig");
    const eth_config = @import("../eth/config.zig");
    const resolved = eth_config.canonical;
    const Ethereum = definition_mod.ExecutionModel(resolved.execution);
    const CancunPlus = compileExecution(
        resolved.execution,
        Ethereum.Support.since(.cancun),
    );
    const blobbasefee = comptime instructionFor(CancunPlus, .BLOBBASEFEE);
    const slotnum = comptime instructionFor(CancunPlus, .SLOTNUM);
    const balance = comptime instructionFor(CancunPlus, .BALANCE);
    const add = comptime instructionFor(CancunPlus, .ADD);
    const push1 = comptime instructionFor(CancunPlus, .PUSH1);
    const push0 = comptime instructionFor(CancunPlus, .PUSH0);
    const sload = comptime instructionFor(CancunPlus, .SLOAD);

    comptime {
        if (@hasDecl(Ethereum, "opcodeAvailability") or @hasDecl(Ethereum, "staticGasForRevision"))
            @compileError("resolved execution leaked flat byte-level instruction facts");
        if (@hasDecl(CancunPlus, "opcodeAvailability") or @hasDecl(CancunPlus, "staticGasForRevision"))
            @compileError("execution protocol leaked flat byte-level instruction facts");
    }

    try std.testing.expectEqual(Resolution.always, CancunPlus.Instruction.availability(blobbasefee));
    try std.testing.expectEqual(Resolution.runtime, CancunPlus.Instruction.availability(slotnum));
    try std.testing.expectEqual(@as(?i64, 100), CancunPlus.Instruction.staticGasConstant(balance));
    try std.testing.expect(CancunPlus.hot_cold_dispatch_enabled);
    try std.testing.expect(CancunPlus.Instruction.entry(add).hot_path);
    try std.testing.expect(CancunPlus.Instruction.entry(push1).hot_path);
    try std.testing.expect(CancunPlus.Instruction.entry(push0).hot_path);
    try std.testing.expect(!CancunPlus.Instruction.entry(slotnum).hot_path);
    try std.testing.expect(!CancunPlus.Instruction.entry(sload).hot_path);
    try std.testing.expectEqual(@as(?usize, ethereum.system.Create.max_code_size), CancunPlus.create.createCodeSizeLimit(.cancun));
    try std.testing.expectEqual(@as(i64, 50), CancunPlus.Instruction.expByteGas(.cancun));
    try std.testing.expectEqual(@as(?precompile_mod.Contract, .ecrecover), ethereum.precompile.resolve(.cancun, address.addr(0x01)));
    try std.testing.expect(CancunPlus.Precompile.active(.cancun, address.addr(0x01)));

    const CancunPlusTx = compileTransaction(CancunPlus, resolved.transaction);
    const CancunPlusBlock = compileBlock(CancunPlusTx, resolved.block);
    try std.testing.expect(CancunPlusTx.authorization.active(.prague));
    try std.testing.expectEqual(CancunPlus.support, CancunPlusBlock.support);

    const Amsterdam = compileExecution(
        resolved.execution,
        Ethereum.Support.at(.amsterdam),
    );
    try std.testing.expect(Amsterdam.hot_cold_dispatch_enabled);
    try std.testing.expectEqual(@as(?usize, ethereum.system.Create.amsterdam_max_code_size), Amsterdam.create.createCodeSizeLimit(.amsterdam));

    const AmsterdamWithoutHotCold = compileExecutionWithDispatch(
        resolved.execution,
        Ethereum.Support.at(.amsterdam),
        .{ .hot_cold = .disabled },
    );
    try std.testing.expect(!AmsterdamWithoutHotCold.hot_cold_dispatch_enabled);

    const Frontier = compileExecution(
        resolved.execution,
        Ethereum.Support.at(.frontier),
    );
    try std.testing.expectEqual(@as(?usize, null), Frontier.create.createCodeSizeLimit(.frontier));
}

test "execution protocol identity ignores transaction and block program hooks" {
    const ethereum = @import("../eth.zig");
    const eth_config = @import("../eth/config.zig");
    const overrides = struct {
        fn maxInitcodeSize(_: ethereum.Revision) usize {
            return 1234;
        }

        fn beforeBlock(_: ethereum.Revision, _: types.BeforeBlockContext) types.BlockSystemCalls {
            return .{};
        }
    };
    const base = eth_config.canonical;
    const alternate = comptime eth_config.resolveExtension(.{
        .transaction = .{ .maxInitcodeSize = overrides.maxInitcodeSize },
        .block = .{ .beforeBlock = overrides.beforeBlock },
    });
    const Ethereum = definition_mod.ExecutionModel(base.execution);
    const support_window = comptime Ethereum.Support.at(.cancun);
    const Execution = compileExecution(base.execution, support_window);
    const BaseTx = compileTransaction(Execution, base.transaction);
    const BaseBlock = compileBlock(BaseTx, base.block);
    const AlternateTx = compileTransaction(Execution, alternate.transaction);
    const AlternateBlock = compileBlock(AlternateTx, alternate.block);

    comptime {
        if (BaseTx == AlternateTx)
            @compileError("transaction protocol must retain transaction-layer rule identity");
        if (BaseBlock == AlternateBlock)
            @compileError("block protocol must retain block-config identity");
        if (BaseTx.ExecutionProtocol != AlternateTx.ExecutionProtocol)
            @compileError("execution protocol changed with transaction or block program hooks");
        if (BaseBlock.ExecutionProtocol != Execution)
            @compileError("block protocol lost the execution layer reference");
    }
}
