const definition = @import("./definition.zig");
const opcode_info = @import("./opcode.zig");

pub const interface = @import("./protocol/interface.zig");
pub const dispatcher = @import("./protocol/dispatcher.zig");
pub const instruction = @import("./protocol/instruction.zig");
pub const transaction = @import("./protocol/transaction.zig");
pub const binding = @import("./protocol/binding.zig");
pub const support = @import("./protocol/support.zig");

pub fn assertValidDefinition(comptime definition_value: anytype) void {
    interface.assertValidDefinition(definition.Bound(definition_value));
}

pub fn assertValidProtocolDefinition(comptime definition_value: anytype) void {
    interface.assertValidProtocolDefinition(definition.Bound(definition_value));
}

pub const RevisionModel = support.Model;
pub const DispatchEntry = dispatcher.DispatchEntry;
pub const DispatchTable = dispatcher.DispatchTable;
pub const DispatchConfig = dispatcher.DispatchConfig;
pub const ExecutionOverride = dispatcher.ExecutionOverride;
pub const ExecutionTarget = dispatcher.ExecutionTarget;
pub const HotColdDispatch = dispatcher.HotColdDispatch;
pub const InstructionContext = instruction.Context;
pub const OpInfo = opcode_info.OpInfo;
pub const OpcodeTier = support.OpcodeTier;
pub const Resolution = support.Resolution;
pub const ProtocolWithDispatch = binding.ProtocolWithDispatch;
pub const StaticGas = dispatcher.StaticGas;
pub const StaticGasBand = support.StaticGasBand;
pub const StaticGasBands = support.StaticGasBands;
pub const resolveDispatchTable = dispatcher.resolveDispatchTable;
pub const RevisionId = support.RevisionId;
pub const revisionId = support.revisionId;
pub const decodeRevision = support.decodeRevision;
pub const revisionSupported = support.revisionSupported;
pub const assertRevisionSupported = support.assertRevisionSupported;
pub const revisionIdForProtocol = support.revisionIdForProtocol;
pub const decodeRevisionForProtocol = support.decodeRevisionForProtocol;

/// Bind a protocol definition to a support window and dispatch options.
///
/// `.support` defaults to the definition's full revision window. Dispatch
/// options accept either `.dispatch.hot_cold` or `.hot_cold_dispatch`.
pub fn Protocol(comptime definition_value: anytype, comptime options: anytype) type {
    const support_window = definitionSupport(definition_value, options);
    const dispatch_config = definitionDispatchConfig(options);
    return ProtocolWithDispatch(definition_value, support_window, dispatch_config);
}

fn definitionSupport(comptime definition_value: anytype, comptime options: anytype) definition.Bound(definition_value).Support {
    const BoundDefinition = definition.Bound(definition_value);
    const Options = @TypeOf(options);
    switch (@typeInfo(Options)) {
        .@"struct" => {},
        else => @compileError("Protocol options must be a struct literal"),
    }

    if (@hasField(Options, "support")) {
        return options.support;
    }

    return BoundDefinition.Support.all;
}

fn definitionDispatchConfig(comptime options: anytype) DispatchConfig {
    const Options = @TypeOf(options);
    var dispatch_config = DispatchConfig{};

    if (@hasField(Options, "dispatch")) {
        const dispatch_options = options.dispatch;
        const DispatchOptions = @TypeOf(dispatch_options);
        if (@hasField(DispatchOptions, "hot_cold")) {
            dispatch_config.hot_cold = dispatch_options.hot_cold;
        }
    }

    if (@hasField(Options, "hot_cold_dispatch")) {
        dispatch_config.hot_cold = options.hot_cold_dispatch;
    }

    return dispatch_config;
}

test {
    _ = @import("./protocol/test.zig");
}
