`evmz` is a composable EVM execution engine written in Zig.

Leverage comptime build for specialized purpose EVM.

Zig conventions:

- Avoid hidden allocation in execution-critical paths.
- Prefer shothand `.{}` and `.empty`. Add method to struct for convenience.
- Use `assert` for boundary conditions, domain invariant and programmer errors.
- Variable case: TitleCase for types, snake_case for variables, camelCase for functions.
- File case follows its root: `TitleCase.zig` when the file _is_ the type, `snake_case.zig` when it's a namespace. Folder is the prefix — don't repeat it in members.

For performance, measure benchmark and guest cycle, they are not guaranteed to be the same.

Testing:

- `zig build test` uses only `dev` forks (cancun–amsterdam), so fork-boundary tests may SKIP. Use `-Dtest-forks=head` for the fastest loop; use `-Dtest-forks=all` or `zig build ci` for the full matrix. CI is always `all`.
- Filter without recompiling: `zig build test -- <substring>` or `TEST_FILTER=<substring> zig build test`; optional: `TEST_VERBOSE=true`, `TEST_FAIL_FIRST=true`. Use compile-time `-Dtest-filter=<substring>` deliberately—it creates a new binary and recompiles.
- Build fork engines only through `t`: `t.Vm(.berlin) orelse return error.SkipZigTest`, `t.CustomVm(.base, patch)` for `.extend`, or `t.BlockStf(.fork)`. Never call `evmz.Vm(evmz.eth.<fork>)` directly: `t`'s comptime-null unwrap prunes disabled forks. Use bare `t.forkEnabled` only with helper-mediated fork work.
