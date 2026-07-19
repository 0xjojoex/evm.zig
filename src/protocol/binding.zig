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

pub fn ExecutionProtocol(
    comptime definition_value: anytype,
    comptime support_window: definition_mod.BoundExecution(definition_value).Support,
) type {
    return ExecutionProtocolWithDispatch(definition_value, support_window, .{});
}

/// Bind one transaction definition above one bound execution protocol.
///
/// The transaction layer owns preparation, settlement, and authorization
/// policy. It inherits revision context from the execution layer below and
/// never re-binds it: the support window is applied once, at the execution
/// binding, because only instruction dispatch has comptime revision shape.
/// Cross-layer reads stay explicit through `ExecutionProtocol`.
pub fn TransactionProtocol(
    comptime ExecutionProtocolType: type,
    comptime transaction_definition: definition_mod.TransactionDefinition(ExecutionProtocolType.Revision),
) type {
    validate.assertTransactionContract(ExecutionProtocolType.Revision, transaction_definition);
    const R = ExecutionProtocolType.Revision;
    const transaction_config: definition_mod.TransactionConfig(R) = transaction_definition.transaction;
    const settlement_config: definition_mod.SettlementConfig(R) = transaction_definition.settlement;
    const authorization_config: definition_mod.AuthorizationConfig(R) = transaction_definition.authorization;

    return struct {
        pub const ExecutionProtocol = ExecutionProtocolType;

        pub const Revision = ExecutionProtocolType.Revision;
        pub const Support = ExecutionProtocolType.Support;
        pub const support = ExecutionProtocolType.support;

        pub const transaction = transaction_config;
        pub const settlement = settlement_config;
        pub const authorization = authorization_config;

        pub const Tx = transaction_mod.For(transaction_config);
        pub const Settlement = tx_settlement.Default;
    };
}

/// Bind one block definition above one bound transaction protocol.
///
/// The block layer owns block-sequencing system-call hooks. Everything else is
/// reached through the `TransactionProtocol` and `ExecutionProtocol` layer
/// references.
pub fn BlockProtocol(
    comptime TransactionProtocolType: type,
    comptime block_definition: definition_mod.BlockDefinition(TransactionProtocolType.Revision),
) type {
    const R = TransactionProtocolType.Revision;
    const block_config: definition_mod.BlockConfig(R) = block_definition.block;

    return struct {
        pub const TransactionProtocol = TransactionProtocolType;
        pub const ExecutionProtocol = TransactionProtocolType.ExecutionProtocol;

        pub const Revision = TransactionProtocolType.Revision;
        pub const Support = TransactionProtocolType.Support;
        pub const support = TransactionProtocolType.support;

        pub const block = block_config;
    };
}

/// Bind the execution-only Definition projection used by Interpreter and
/// Executor. Its type identity is independent from transaction and block
/// program customization in the authoring aggregate.
pub fn ExecutionProtocolWithDispatch(
    comptime definition_value: anytype,
    comptime support_window: definition_mod.BoundExecution(definition_value).Support,
    comptime dispatch_config: dispatcher.DispatchConfig,
) type {
    const DefinitionType = definition_mod.BoundExecution(definition_value);
    validate.assertDispatchContract(DefinitionType);
    support_window.assertValid();
    const hot_cold_dispatch = dispatcher.useHotColdDispatch(dispatch_config);
    const InstructionFacts = instruction_mod.For(DefinitionType, support_window);

    return struct {
        pub const Revision = DefinitionType.Revision;
        pub const BaseRevision = DefinitionType.BaseRevision;
        pub const revisions = DefinitionType.revisions;
        pub const Support = DefinitionType.Support;
        pub const Availability = DefinitionType.Availability;
        pub const order = DefinitionType.order;
        pub const isImpl = DefinitionType.isImpl;
        pub const baseRevision = DefinitionType.baseRevision;

        pub const support = support_window;
        pub const dispatch = dispatch_config;
        pub const hot_cold_dispatch_enabled = hot_cold_dispatch;

        pub const valueTransferLog = DefinitionType.valueTransferLog;
        pub const call = DefinitionType.call;
        pub const create = DefinitionType.create;
        pub const storage = DefinitionType.storage;
        pub const self_destruct = DefinitionType.self_destruct;

        pub const Precompile = struct {
            pub fn active(revision: DefinitionType.Revision, target: address.Address) bool {
                if (comptime std.meta.hasFn(DefinitionType.Precompile, "active")) {
                    return DefinitionType.Precompile.active(revision, target);
                }
                return DefinitionType.Precompile.resolve(revision, target) != null;
            }

            pub fn execute(
                revision: DefinitionType.Revision,
                target: address.Address,
                precompile_call: precompile_runtime.PrecompileCall,
            ) precompile_mod.Error!?precompile_runtime.PrecompileOutcome {
                const entry = DefinitionType.Precompile.resolve(revision, target) orelse return null;
                return try DefinitionType.Precompile.execute(revision, entry, precompile_call);
            }
        };

        const byte = struct {
            pub fn entry(comptime opcode_byte: u8) dispatcher.DispatchEntry {
                return dispatcher.resolveDispatchEntryByte(DefinitionType, support_window, opcode_byte);
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
                return dispatcher.resolveStaticGasByte(DefinitionType, support_window, opcode_byte);
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
                    .custom => dispatcher.resolveDispatchEntryInstruction(DefinitionType, support_window, value),
                };
            }

            pub fn info(comptime value: Value) opcode_info.OpInfo {
                return InstructionFacts.info(value);
            }

            pub fn rawAvailability(comptime value: Value) DefinitionType.Availability {
                return InstructionFacts.rawAvailability(value);
            }

            pub fn availability(comptime value: Value) Resolution {
                return InstructionFacts.availability(value);
            }

            pub fn staticGasForRevision(revision: DefinitionType.Revision, comptime value: Value) i64 {
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
                    .custom => dispatcher.resolveStaticGasInstruction(DefinitionType, support_window, value),
                };
            }

            pub fn staticGasConstant(comptime value: Value) ?i64 {
                return switch (@This().staticGas(value)) {
                    .constant => |gas| gas,
                    .revision_bands => null,
                };
            }

            pub fn expByteGas(revision: DefinitionType.Revision) i64 {
                return InstructionFacts.expByteGas(revision);
            }

            pub fn accountReadColdAccessGas(revision: DefinitionType.Revision) ?i64 {
                return InstructionFacts.accountReadColdAccessGas(revision);
            }

            pub fn codeAccountAccessGas(revision: DefinitionType.Revision, status: types.AccountAccessStatus) ?i64 {
                return InstructionFacts.codeAccountAccessGas(revision, status);
            }
        };

        pub fn dispatchTable() dispatcher.DispatchTable {
            return dispatcher.resolveDispatchTable(DefinitionType, support_window);
        }
    };
}

fn instructionFor(comptime ProtocolType: type, comptime opcode: opcode_info.Opcode) ProtocolType.Instruction.Value {
    return ProtocolType.Instruction.fromByte(@intFromEnum(opcode));
}

test "layered protocol chain exposes resolved Ethereum facts" {
    const ethereum = @import("../eth.zig");
    const Ethereum = definition_mod.BoundExecution(ethereum.execution_definition);
    const CancunPlus = ExecutionProtocol(
        ethereum.execution_definition,
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
            @compileError("bound execution leaked flat byte-level instruction facts");
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

    const CancunPlusTx = TransactionProtocol(CancunPlus, ethereum.transaction_definition);
    const CancunPlusBlock = BlockProtocol(CancunPlusTx, ethereum.block_definition);
    try std.testing.expect(CancunPlusTx.authorization.active(.prague));
    try std.testing.expectEqual(CancunPlus.support, CancunPlusBlock.support);

    const Amsterdam = ExecutionProtocol(
        ethereum.execution_definition,
        Ethereum.Support.at(.amsterdam),
    );
    try std.testing.expect(Amsterdam.hot_cold_dispatch_enabled);
    try std.testing.expectEqual(@as(?usize, ethereum.system.Create.amsterdam_max_code_size), Amsterdam.create.createCodeSizeLimit(.amsterdam));

    const AmsterdamWithoutHotCold = ExecutionProtocolWithDispatch(
        ethereum.execution_definition,
        Ethereum.Support.at(.amsterdam),
        .{ .hot_cold = .disabled },
    );
    try std.testing.expect(!AmsterdamWithoutHotCold.hot_cold_dispatch_enabled);

    const Frontier = ExecutionProtocol(
        ethereum.execution_definition,
        Ethereum.Support.at(.frontier),
    );
    try std.testing.expectEqual(@as(?usize, null), Frontier.create.createCodeSizeLimit(.frontier));
}

test "execution protocol identity ignores transaction and block program hooks" {
    const ethereum = @import("../eth.zig");
    const overrides = struct {
        fn maxInitcodeSize(_: ethereum.Revision) usize {
            return 1234;
        }

        fn beforeBlock(_: ethereum.Revision, _: types.BeforeBlockContext) types.BlockSystemCalls {
            return .{};
        }
    };
    const alternate_transaction = comptime ethereum.defineTransaction(.{
        .transaction = .{ .maxInitcodeSize = overrides.maxInitcodeSize },
    });
    const alternate_block = comptime ethereum.defineBlock(.{
        .block = .{ .beforeBlock = overrides.beforeBlock },
    });
    const Ethereum = definition_mod.BoundExecution(ethereum.execution_definition);
    const support_window = comptime Ethereum.Support.at(.cancun);
    const Execution = ExecutionProtocol(ethereum.execution_definition, support_window);
    const BaseTx = TransactionProtocol(Execution, ethereum.transaction_definition);
    const BaseBlock = BlockProtocol(BaseTx, ethereum.block_definition);
    const AlternateTx = TransactionProtocol(Execution, alternate_transaction);
    const AlternateBlock = BlockProtocol(AlternateTx, alternate_block);

    comptime {
        if (BaseTx == AlternateTx)
            @compileError("transaction protocol must retain transaction definition identity");
        if (BaseBlock == AlternateBlock)
            @compileError("block protocol must retain block definition identity");
        if (BaseTx.ExecutionProtocol != AlternateTx.ExecutionProtocol)
            @compileError("execution protocol changed with transaction or block program hooks");
        if (BaseBlock.ExecutionProtocol != Execution)
            @compileError("block protocol lost the execution layer reference");
    }
}
