//! Opt-in candidate execution over positioned BAL reads.
//!
//! Split by axis, one concern per file:
//!   - `report`      lane status vocabulary and caller-owned diagnostics
//!   - `lane`        one transaction over one positioned read view
//!   - `accumulator` ordered acceptance and block artifact folds
//!   - `schedule`    bounded concurrency and its fallback policy
//!   - `runner`      block lifecycle and status assignment

const std = @import("std");

pub const report = @import("differential/report.zig");
pub const lane = @import("differential/lane.zig");
pub const accumulator = @import("differential/accumulator.zig");
pub const schedule = @import("differential/schedule.zig");
pub const runner = @import("differential/runner.zig");

pub const Status = report.Status;
pub const Report = report.Report;
pub const ParallelSubmission = report.ParallelSubmission;
pub const ParallelFallback = report.ParallelFallback;
pub const ParallelExecution = report.ParallelExecution;

pub const Runner = runner.Runner;

test {
    std.testing.refAllDecls(@This());
}
