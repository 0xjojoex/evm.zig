//! Pull-driven pause vocabulary.
//!
//! Every type here is spec-free. `Interpreter.Action`, `Interpreter.FrameResult`, and
//! `Host.Result` are module-level non-generic types, so a caller can match on a
//! pause without naming a specification. Only the driver in `./session.zig`
//! binds an executor.
//!
//! The vocabulary stays at the three boundaries the current driver proves.
//! Additional pause kinds or inspection containers belong to a concrete
//! debugger consumer, not this ownership layer.

const evmz = @import("../evm.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

/// Where a pause happened. Frame index is relative to the whole frame store, so
/// it stays valid for the driver that produced it and no other.
pub const Site = struct {
    frame_index: usize,
    depth: u16,
};

/// Whether controlled execution followed canonical EVM semantics throughout.
pub const Completion = union(enum) {
    canonical: Host.Result,
    intervened: Host.Result,
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
    suspended: struct {
        site: Site,
        value: *const Interpreter.Action,
    },
    /// The root execution resolved. The driver's frame span is empty.
    finished: Completion,
};
