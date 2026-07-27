//! Pull-driven pause vocabulary.
//!
//! Every type here is spec-free. `Interpreter.Action`, `Interpreter.Result`, and
//! `Host.Result` are module-level non-generic types, so a caller can match on a
//! pause without naming a specification. Only the driver in `./session.zig`
//! binds an executor.
//!
//! Stage 0 moves the spike's three pause kinds here unchanged. The
//! `frame_exit` kind, borrowed `View`, `Budget`, and `Authority` arrive in stage
//! 1 with the full session shape.

const evmz = @import("../evm.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

/// Where a pause happened. Frame index is relative to the whole frame store, so
/// it stays valid for the driver that produced it and no other.
pub const Site = struct {
    frame_index: usize,
    depth: u16,
};

/// One boundary the driver can stop at.
///
/// A payload borrows driver-owned frame state and is valid only until the next
/// resume. Anything retained must be copied.
pub const Pause = union(enum) {
    /// The active frame is stable before this opcode executes. Mutation happens
    /// against a pre-state, and executing one instruction lands at the next
    /// `opcode` boundary.
    opcode: struct {
        site: Site,
        pc: usize,
        opcode: u8,
        gas_left: i64,
    },
    /// The parent prepared a semantic CALL/CREATE and is suspended before the
    /// child is dispatched.
    action: struct {
        site: Site,
        value: Interpreter.Action,
    },
    /// The root execution resolved. The driver's frame span is empty.
    finished: Host.Result,
};
