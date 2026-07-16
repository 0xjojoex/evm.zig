const evmz = @import("../evm.zig");

const FrameStore = @import("./frame_store.zig");
const Interpreter = evmz.interpreter;
const Journal = @import("../state/Journal.zig");

pub const ChildCreate = struct {
    checkpoint_state: Journal.Checkpoint,
    address: evmz.Address,
    account_pre_existing: bool,
    kind: evmz.Host.CallKind,
    msg: evmz.Host.Message,
    init_code: []const u8,
};

pub const Kind = union(enum) {
    root_call,
    call: Journal.Checkpoint,
    create: ChildCreate,
};

pub const Frame = struct {
    kind: Kind,
    frame: FrameStore.Lease,
    pending_action: ?Interpreter.Action = null,
};
