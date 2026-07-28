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
//! `Session` owns the runtime frame span and prepared-code execution scope across
//! pauses. The caller keeps ownership of the transaction attempt, root bytecode,
//! and retain/discard policy.

const std = @import("std");
const evmz = @import("../evm.zig");
const call_runtime = @import("../executor/call_runtime.zig");
const pause_types = @import("./pause.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

pub const Pause = pause_types.Pause;
pub const Site = pause_types.Site;
pub const Completion = pause_types.Completion;

pub fn bind(comptime Executor: type) type {
    const runtime = call_runtime.bind(Executor);
    const Instructions = evmz.instruction.Instruction(Executor.specification);

    return struct {
        pub const Session = struct {
            call_runtime: runtime.CallRuntime,
            open: bool,
            intervened: bool,
            /// Set between a frame's `finishFrame` and its matching `popFrame`.
            /// That frame already resolved its own checkpoint, so `abort` must
            /// not revert it again if an error unwinds through the gap.
            top_frame_resolved: bool,

            /// Begin controlled execution for one root message.
            ///
            /// Initialize the session at its final address and do not move it
            /// until `deinit`; live frames borrow its host interface.
            ///
            /// `bytecode` remains borrowed from the caller. The caller also owns
            /// the surrounding transaction attempt and resolves it after this
            /// session finishes or aborts.
            pub fn init(self: *Session, executor: *Executor, msg: Host.Message, bytecode: evmz.Bytecode.View) !void {
                if (executor.currentCaptureContext() != null) return error.CaptureActive;

                executor.beginPreparedCodeExecution();
                errdefer executor.endPreparedCodeExecution();

                self.* = .{
                    .call_runtime = runtime.CallRuntime.init(executor),
                    .open = true,
                    .intervened = false,
                    .top_frame_resolved = false,
                };
                errdefer self.call_runtime.deinit();

                try self.call_runtime.prepare();
                try self.call_runtime.pushRootCall(msg, bytecode);
            }

            /// Abort unfinished frames and close the prepared-code execution
            /// scope. The caller still resolves the surrounding transaction.
            pub fn deinit(self: *Session) void {
                if (self.open) self.abort();
            }

            /// Advance to the next boundary without executing an instruction.
            ///
            /// Finishes and unwinds any frame that is already terminal, resuming
            /// each parent through the same typed continuation normal execution
            /// uses.
            pub fn pause(self: *Session) !Pause {
                std.debug.assert(self.open);
                while (self.call_runtime.frames.len() > self.call_runtime.frame_base) {
                    const index = self.call_runtime.frames.len() - 1;
                    const frame = self.call_runtime.frames.frame(index);
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

                    const host_result = try self.call_runtime.finishFrame(index, frame.getResult());
                    self.top_frame_resolved = true;
                    if (self.call_runtime.frames.len() == self.call_runtime.frame_base + 1) {
                        const stable = try runtime.stabilizeFinalResult(self.call_runtime.executor, host_result);
                        const completion: Completion = if (self.intervened)
                            .{ .intervened = stable }
                        else
                            .{ .canonical = stable };
                        self.popResolvedFrame();
                        self.close();
                        return .{ .finished = completion };
                    }

                    const parent_index = self.call_runtime.frames.len() - 2;
                    try self.call_runtime.resumeParentAction(parent_index, host_result);
                    self.popResolvedFrame();
                }
                unreachable;
            }

            /// Borrow the active frame's stack until the next resume.
            pub fn stack(self: *const Session) []const u256 {
                std.debug.assert(self.open);
                std.debug.assert(self.call_runtime.frames.len() > self.call_runtime.frame_base);
                const index = self.call_runtime.frames.len() - 1;
                return self.call_runtime.frames.frame(index).stack.asSlice();
            }

            /// Whether the caller has changed the execution path.
            pub fn isIntervened(self: *const Session) bool {
                return self.intervened;
            }

            /// Execute exactly one instruction in the active frame.
            pub fn step(self: *Session) !Pause {
                std.debug.assert(self.open);
                const frame = self.call_runtime.frames.frame(self.call_runtime.frames.len() - 1);
                std.debug.assert(frame.status == .running);
                std.debug.assert(frame.pc < frame.code.len);
                try self.executeOne(frame);
                return self.pause();
            }

            /// One instruction under the depth rebinding production applies
            /// around every interpreter run, so host-bound opcodes observe the
            /// depth they execute at rather than whatever the last call left.
            fn executeOne(self: *Session, frame: *Interpreter.CallFrame) !void {
                const previous_depth = self.call_runtime.executor.trace_depth;
                self.call_runtime.executor.trace_depth = frame.msg.depth;
                defer self.call_runtime.executor.trace_depth = previous_depth;

                const opcode = frame.code[frame.pc];
                frame.pc += 1;
                try Instructions.execute(opcode, frame);
                if (frame.pc >= frame.code.len and frame.status == .running) {
                    frame.status = .success;
                }
            }

            /// Dispatch the suspended frame's pending CALL/CREATE normally.
            pub fn dispatchAction(self: *Session) !Pause {
                std.debug.assert(self.open);
                const index = self.call_runtime.frames.len() - 1;
                const frame = self.call_runtime.frames.frame(index);
                std.debug.assert(frame.status == .suspended);
                try self.call_runtime.handleAction(index, frame.pending_action orelse unreachable);
                return self.pause();
            }

            /// Resolve the pending CALL/CREATE with a caller-supplied result
            /// instead of executing the child.
            ///
            /// This immediately marks the session intervened, and its eventual
            /// completion carries the same authority loss.
            pub fn substituteAction(self: *Session, result: Host.Result) !Pause {
                std.debug.assert(self.open);
                const index = self.call_runtime.frames.len() - 1;
                std.debug.assert(self.call_runtime.frames.frame(index).status == .suspended);
                self.intervened = true;
                try self.call_runtime.resumeParentAction(index, result);
                return self.pause();
            }

            /// Restore unresolved child checkpoints and close the session. The
            /// transaction owner still resolves the root attempt separately.
            pub fn abort(self: *Session) void {
                std.debug.assert(self.open);
                if (self.top_frame_resolved) self.popResolvedFrame();
                while (self.call_runtime.frames.len() > self.call_runtime.frame_base) {
                    const index = self.call_runtime.frames.len() - 1;
                    switch (self.call_runtime.frames.control(index).kind) {
                        .root_call => {},
                        .call => |checkpoint_state| self.call_runtime.executor.state.revertToCheckpoint(checkpoint_state),
                        .create => |child| self.call_runtime.executor.state.revertToCheckpoint(child.checkpoint_state),
                    }
                    self.call_runtime.popFrame();
                }
                self.close();
            }

            /// Drop a frame whose checkpoint `finishFrame` already resolved.
            fn popResolvedFrame(self: *Session) void {
                std.debug.assert(self.top_frame_resolved);
                self.top_frame_resolved = false;
                self.call_runtime.popFrame();
            }

            fn close(self: *Session) void {
                std.debug.assert(self.open);
                self.call_runtime.deinit();
                self.call_runtime.executor.endPreparedCodeExecution();
                self.open = false;
            }
        };
    };
}

test {
    _ = @import("./session_test.zig");
}
