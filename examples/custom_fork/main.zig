//! Custom-fork showcase: every seam of the exact spec API in one tour.
//!
//! A fork is a plain comptime `Spec` value. `extend` patches any subset of
//! it and `evmz.Vm(spec)` compiles one exact VM per value — no revision
//! checks survive into execution. Each module demonstrates one seam:
//!
//! - `create_limits`: scalar value patches and `OptionalPatch` replacement,
//!   including removing an optional limit outright.
//! - `gas_rules`: replacing a semantic `*const fn` policy (calldata pricing).
//! - `custom_opcode`: instruction-table surgery — a new custom opcode on an
//!   unassigned byte, a retired opcode, and a repriced builtin.
//! - `precompiles`: a derived precompile config plus a fully custom
//!   precompile type owning its own address.
//!
//! `spec.block` (system-call hooks) and `spec.valueTransferLog` follow the
//! same patch pattern; `examples/op_deposit.zig` composes them — together
//! with a family-owned transaction type — into a complete OP-style fork.

const std = @import("std");

const create_limits = @import("create_limits.zig");
const custom_opcode = @import("custom_opcode.zig");
const gas_rules = @import("gas_rules.zig");
const precompiles = @import("precompiles.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    try create_limits.run(allocator);
    try gas_rules.run(allocator);
    try custom_opcode.run(allocator);
    try precompiles.run(allocator);
}

test {
    _ = create_limits;
    _ = custom_opcode;
    _ = gas_rules;
    _ = precompiles;
}
