`evmz` is a composable EVM execution engine written in Zig.

Leverage comptime build for specialized purpose EVM.

Zig conventions:

- Avoid hidden allocation in execution-critical paths.
- Prefer shothand `.{}` and `.empty`. Add method to struct for convenience.
- Use `assert` for boundary conditions, domain invariant and programmer errors.
- Variable case: TitleCase for types, snake_case for variables, camelCase for functions.
- File case follows its root: `TitleCase.zig` when the file _is_ the type, `snake_case.zig` when it's a namespace. Folder is the prefix — don't repeat it in members.

For performance, measure benchmark and guest cycle, they are not guaranteed to be the same.
