//! Pull-driven driver over the executor's call runtime.
//!
//! Normal execution runs `CallRuntime.run` uninterrupted. This module drives the
//! same frame stack, checkpoints, and typed continuations one boundary at a time
//! instead, so a caller can inspect or intervene between opcodes.
//!
//! The driver deliberately reuses `Instruction(spec).execute` — the same cold
//! route production tail dispatch already falls to for host-bound opcodes. It
//! adds no dispatch table, so opcode semantics here are production semantics.
//!
//! Stage 0: functions take the runtime explicitly. Stage 1 wraps them
//! in a `Session` that owns the prepared-code and frame lifetimes across pauses,
//! adds the borrowed `View`, and adds `intervene()` as the sole mutation path.

const std = @import("std");
const evmz = @import("../evm.zig");
const call_runtime = @import("../executor/call_runtime.zig");
const pause_types = @import("./pause.zig");

const Host = evmz.Host;

pub const Pause = pause_types.Pause;
pub const Site = pause_types.Site;

pub fn bind(comptime Executor: type) type {
    const runtime = call_runtime.bind(Executor);
    const Instructions = evmz.instruction.Instruction(Executor.specification);

    return struct {
        pub const CallRuntime = runtime.CallRuntime;

        /// Advance to the next boundary without executing an instruction.
        ///
        /// Finishes and unwinds any frame that is already terminal, resuming each
        /// parent through the same typed continuation normal execution uses.
        pub fn pause(self: *CallRuntime) !Pause {
            std.debug.assert(self.capture_context == null);
            while (self.frames.len() > self.frame_base) {
                const index = self.frames.len() - 1;
                const frame = self.frames.frame(index);
                switch (frame.status) {
                    .running => {
                        if (frame.pc < frame.code.len) {
                            return .{ .opcode = .{
                                .site = .{ .frame_index = index, .depth = frame.msg.depth },
                                .pc = frame.pc,
                                .opcode = frame.code[frame.pc],
                                .gas_left = frame.gas_left,
                            } };
                        }
                        frame.status = .success;
                    },
                    .suspended => return .{ .action = .{
                        .site = .{ .frame_index = index, .depth = frame.msg.depth },
                        .value = frame.pending_action orelse unreachable,
                    } },
                    else => {},
                }

                const host_result = try self.finishFrame(index, frame.getResult());
                if (self.frames.len() == self.frame_base + 1) {
                    const stable = try runtime.stabilizeFinalResult(self.executor, host_result);
                    self.popFrame();
                    return .{ .finished = stable };
                }

                const parent_index = self.frames.len() - 2;
                try self.resumeParentAction(parent_index, host_result);
                self.popFrame();
            }
            unreachable;
        }

        /// Execute exactly one instruction in the active frame.
        pub fn step(self: *CallRuntime) !Pause {
            std.debug.assert(self.capture_context == null);
            const frame = self.frames.frame(self.frames.len() - 1);
            std.debug.assert(frame.status == .running);
            std.debug.assert(frame.pc < frame.code.len);

            const opcode = frame.code[frame.pc];
            frame.pc += 1;
            try Instructions.execute(opcode, frame);
            if (frame.pc >= frame.code.len and frame.status == .running) {
                frame.status = .success;
            }
            return pause(self);
        }

        /// Dispatch the suspended frame's pending CALL/CREATE normally.
        pub fn dispatchAction(self: *CallRuntime) !Pause {
            std.debug.assert(self.capture_context == null);
            const index = self.frames.len() - 1;
            const frame = self.frames.frame(index);
            std.debug.assert(frame.status == .suspended);
            try self.handleAction(index, frame.pending_action orelse unreachable);
            return pause(self);
        }

        /// Resolve the pending CALL/CREATE with a caller-supplied result instead
        /// of executing the child.
        ///
        /// This forfeits canonical authority. Stage 1 moves it behind
        /// `intervene()` and marks the session intervened.
        pub fn substituteAction(self: *CallRuntime, result: Host.Result) !Pause {
            std.debug.assert(self.capture_context == null);
            const index = self.frames.len() - 1;
            std.debug.assert(self.frames.frame(index).status == .suspended);
            try self.resumeParentAction(index, result);
            return pause(self);
        }

        /// Restore unresolved child checkpoints. The transaction owner still
        /// resolves the root attempt separately.
        pub fn abort(self: *CallRuntime) void {
            std.debug.assert(self.capture_context == null);
            while (self.frames.len() > self.frame_base) {
                const index = self.frames.len() - 1;
                switch (self.frames.control(index).kind) {
                    .root_call => {},
                    .call => |checkpoint_state| self.executor.state.revertToCheckpoint(checkpoint_state),
                    .create => |child| self.executor.state.revertToCheckpoint(child.checkpoint_state),
                }
                self.popFrame();
            }
        }
    };
}

test {
    _ = @import("./session_test.zig");
}
