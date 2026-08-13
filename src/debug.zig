//! Live execution control: the pull-driven lane behind an inspector or debugger.
//!
//! `trace` is a flight recorder — execution runs to completion and the artifact
//! reports what happened. This lane is the opposite direction: the caller pulls
//! execution forward one boundary at a time and may intervene.
//!
//! ## Why this module can exist without taxing other lanes
//!
//! The lane is additive by construction, not by convention. Five properties hold
//! and are the reason a debugger does not slow down or enlarge normal execution:
//!
//! - **I0 semantics stay singular.** The driver instantiates a debugger-only
//!   comptime switch into the production tail handlers. It adds code only when
//!   this module is referenced, but it does not maintain a second implementation
//!   of opcode semantics.
//! - **I1 no field growth.** Nothing here adds a field to `Executor`,
//!   `CallFrame`, `FrameStore`, `CaptureContext`, or `Bytecode.View`.
//! - **I2 no branch in the run loops.** `CallRuntime.run` and the captured
//!   variant are untouched; this is a separate entry point over the same frames.
//! - **I3 unreferenced means unemitted.** Zig analyses generic declarations
//!   lazily, so a build that never names this module pays nothing. Verified by
//!   identical ReleaseFast production text, constants, and section sizes with
//!   and without the lane present.
//! - **I4 capture stays a recorder.** Session construction rejects an active
//!   capture context. Combining live control with capture is a later decision,
//!   not an accident.

const std = @import("std");

pub const session = @import("./debug/session.zig");

/// Bind the pull-driven driver to one exact executor.
pub const SessionType = session.SessionType;

pub const Pause = session.Pause;

test {
    std.testing.refAllDecls(@This());
}
