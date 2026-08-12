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

            /// Begin controlled execution for one root message.
            ///
            /// Initialize the session at its final address and do not move it
            /// until `deinit`; live frames borrow its host interface.
            ///
            /// `bytecode` remains borrowed from the caller. The caller also owns
            /// the surrounding transaction attempt and resolves it after this
            /// session finishes or aborts.
            pub fn init(self: *Session, executor: *Executor, msg: Host.Message, bytecode: evmz.Bytecode.View) !void {
                // Establish a deinit-safe closed value here before any fallible steps
                self.* = .{
                    .call_runtime = runtime.CallRuntime.init(executor),
                    .open = false,
                    .intervened = false,
                };
                if (executor.currentCaptureContext() != null) return error.CaptureActive;

                executor.beginPreparedCodeExecution();
                self.open = true;
                // Unwind to a closed session: `deinit` must not close the
                // prepared-code scope a second time.
                errdefer {
                    self.call_runtime.deinit();
                    executor.endPreparedCodeExecution();
                    self.open = false;
                }

                try self.call_runtime.prepare();
                try self.call_runtime.pushRootCall(&msg, bytecode);
            }

            /// Abort unfinished frames and close the prepared-code execution
            /// scope. The caller still resolves the surrounding transaction.
            ///
            /// A no-op on a session that already closed itself or whose `init`
            /// failed, so an unconditional teardown path is safe.
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
                    switch (frame.state) {
                        .running => {
                            if (frame.pc < frame.code.len) {
                                return .{ .opcode = .{
                                    .site = .{ .frame_index = index, .depth = frame.msg.depth },
                                    .pc = frame.pc,
                                    .opcode = frame.code[frame.pc],
                                    .gas_left = frame.gas_left,
                                } };
                            }
                            frame.halt(.success);
                        },
                        .suspended => return .{ .suspended = .{
                            .site = .{ .frame_index = index, .depth = frame.msg.depth },
                            .value = frame.suspendedAction().?,
                        } },
                        .halted => {},
                    }

                    const host_result = try self.call_runtime.finishFrame(index, frame.result());
                    if (self.call_runtime.frames.len() == self.call_runtime.frame_base + 1) {
                        const stable = try runtime.stabilizeFinalResult(self.call_runtime.executor, host_result);
                        const completion: Completion = if (self.intervened)
                            .{ .intervened = stable }
                        else
                            .{ .canonical = stable };
                        self.call_runtime.popResolvedFrame();
                        self.close();
                        return .{ .finished = completion };
                    }

                    const parent_index = self.call_runtime.frames.len() - 2;
                    try self.call_runtime.resumeSuspended(parent_index, host_result);
                    self.call_runtime.popResolvedFrame();
                }
                unreachable;
            }

            /// Borrow the active frame's stack until the next resume.
            pub fn stack(self: *const Session) []const u256 {
                return self.activeFrame().stack.asSlice();
            }

            /// Borrow the active frame's EVM memory until the next resume.
            pub fn memory(self: *const Session) []const u8 {
                const frame = self.activeFrame();
                return frame.memory.readBytes(0, frame.memory.len());
            }

            /// Borrow the code the active frame is executing. For a child this
            /// is the callee's deployed code, or a CREATE's init code.
            pub fn code(self: *const Session) []const u8 {
                return self.activeFrame().code;
            }

            /// Borrow the message the active frame is executing. Its recipient
            /// is the account SSTORE writes to, which an inspector needs to
            /// resolve storage reads against the right account.
            pub fn message(self: *const Session) *const Host.Message {
                return self.activeFrame().msg;
            }

            fn activeFrame(self: *const Session) *Interpreter.CallFrame {
                std.debug.assert(self.open);
                std.debug.assert(self.call_runtime.frames.len() > self.call_runtime.frame_base);
                return self.call_runtime.frames.frame(self.call_runtime.frames.len() - 1);
            }

            /// Whether the caller has changed the execution path.
            pub fn isIntervened(self: *const Session) bool {
                return self.intervened;
            }

            /// Execute exactly one instruction in the active frame.
            pub fn step(self: *Session) !Pause {
                std.debug.assert(self.open);
                const frame = self.call_runtime.frames.frame(self.call_runtime.frames.len() - 1);
                std.debug.assert(frame.isRunning());
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
                if (frame.pc >= frame.code.len and frame.isRunning()) {
                    frame.halt(.success);
                }
            }

            /// Dispatch the suspended frame's pending CALL/CREATE normally.
            pub fn dispatchSuspension(self: *Session) !Pause {
                std.debug.assert(self.open);
                const index = self.call_runtime.frames.len() - 1;
                const frame = self.call_runtime.frames.frame(index);
                const action = frame.suspendedAction() orelse unreachable;
                try self.call_runtime.dispatchSuspension(index, action);
                return self.pause();
            }

            /// Resolve the pending CALL/CREATE with a caller-supplied result
            /// instead of executing the child.
            ///
            /// A successful substitution marks the session intervened, and its
            /// eventual completion carries the same authority loss.
            pub fn substituteResult(self: *Session, result: Host.Result) !Pause {
                std.debug.assert(self.open);
                const index = self.call_runtime.frames.len() - 1;
                std.debug.assert(self.call_runtime.frames.frame(index).isSuspended());
                try self.call_runtime.resumeSuspended(index, result);
                self.intervened = true;
                return self.pause();
            }

            /// Restore unresolved child checkpoints and close the session. The
            /// transaction owner still resolves the root attempt separately.
            pub fn abort(self: *Session) void {
                std.debug.assert(self.open);
                self.close();
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
