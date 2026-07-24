const evmz = @import("../evm.zig");

const FrameStore = @import("./frame_store.zig");
const Interpreter = evmz.interpreter;
const ScopeCheckpoint = @import("../state/TrackedState.zig").Checkpoint;
const CallToken = @import("../trace/call_arena.zig").Token;

pub const ChildCreate = struct {
    checkpoint_state: ScopeCheckpoint,
    address: evmz.Address,
    kind: evmz.Host.CallKind,
    msg: evmz.Host.Message,
    init_code: []const u8,
};

pub const Kind = union(enum) {
    root_call,
    call: ScopeCheckpoint,
    create: ChildCreate,
};

pub const Frame = struct {
    kind: Kind,
    frame: FrameStore.Lease,
    pending_action: ?Interpreter.Action = null,
    call_capture: ?CallToken = null,
};
