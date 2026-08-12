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
//! - **I0 no third dispatch table.** The driver steps through
//!   definition-owned `Instruction(spec).execute`. Production prepared execution
//!   has a complete tail table; this lane keeps a separate one-op frame switch,
//!   shares the same builtin/custom semantics, and generates no additional table.
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
//!
//! I0 through I4 are the merge gate for every stage. The dependency
//! direction enforcing them is one-way — `debug` reaches into `executor`, and no
//! execution module imports `debug`.

const std = @import("std");

pub const pause = @import("./debug/pause.zig");
pub const session = @import("./debug/session.zig");

pub const Pause = pause.Pause;
pub const Site = pause.Site;
pub const Completion = pause.Completion;

/// Bind the pull-driven driver to one exact executor.
pub const bind = session.bind;

test {
    std.testing.refAllDecls(@This());
}
