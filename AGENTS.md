`evmz` is a composable EVM-family execution engine written in Zig.

Leverage comptime build for specialized purpose EVM.

Zig conventions:

- Avoid hidden allocation in execution-critical paths.
- Prefer shothand `.{}` and `.empty`. Add method to struct for convenience.
- Use `assert` for boundary conditions, domain invariant and programmer errors.

For performance, measure benchmark and guest cycle, they are not guaranteed to be the same.
