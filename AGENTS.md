`evmz` is a composable EVM execution engine written in Zig.

Leverage comptime build for specialized purpose EVM.

Zig conventions — follow the [Zig style guide](https://ziglang.org/documentation/master/#Style-Guide); `zig fmt` owns whitespace, aim for 100-column lines:

- Avoid hidden allocation in execution-critical paths.
- Prefer shorthand `.{}` and `.empty`. Add method to struct for convenience.
- Use `assert` for boundary conditions, domain invariant and programmer errors. In doc comments the words are load-bearing: **assert** = safety-checked illegal behavior, **assume** = unchecked illegal behavior.
- Case: `TitleCase` for types, type aliases, and callables returning `type`; `camelCase` for other callables; `snake_case` for everything else, including 0-field structs used as namespaces. Acronyms are ordinary words — `XmlParser`, `readU32Be`.
- File case follows its root: `TitleCase.zig` when the top level has fields (the file _is_ the type), `snake_case.zig` when it's a namespace. Directories are `snake_case`.
- Names are chosen against the fully-qualified path — folder is the prefix, don't repeat it in members (`state.Journal`, not `state.StateJournal`).
- No `_` prefixes — Zig has no private fields. Document the invariant instead of encoding it in the name.
- `pkg/stdx` holds domain-free utilities that could plausibly live in `std`, and **imports `std` and nothing else**. A helper that needs an evmz, MPT, or RLP type belongs with its domain. `stdx` is internal: it is not exported under `-Dcore=false` and carries no compatibility promise.

For performance, measure benchmark and guest cycle, they are not guaranteed to be the same.

Testing:

- `zig build test` compiles only the `dev` forks — cancun, prague, `.stable`, `.latest` — so a test pinned outside that set SKIPs. `-Dtest-forks=head` is the fastest loop; `-Dtest-forks=all` or `zig build ci` is the full matrix. CI is always `all`.
- Filter without recompiling: `zig build test -- <substring>` or `TEST_FILTER=<substring>`; also `TEST_VERBOSE=true`, `TEST_FAIL_FIRST=true`. `-Dtest-filter=` builds a second binary — use it deliberately.
- Build fork engines only through `t` — `t.Vm`, `t.CaptureVm`, `t.CustomVm`, `t.BlockStf`, `t.CaptureBlockStf`. Never `evmz.Vm(evmz.eth.<fork>)`: only `t`'s comptime-null unwrap prunes a disabled fork, turning it into a SKIP instead of dead analysis. Reach for bare `t.forkEnabled` only when no constructor fits.
- Default to `t.Vm(.latest).?` — `.latest` is enabled under every preset, so it never skips. Spell `.latest`/`.stable`, never `.amsterdam`/`.osaka`, in the pin *and* in the binding's name: `const Latest`, not `const StfAmsterdam`. Either spelling rots at the next fork bump.
- Pin an older fork only when the fork *is* the assertion — an activation boundary, a repricing, or behaviour that exists only there — and gate it `orelse return error.SkipZigTest`. Any other pin just deletes the test from `-Dtest-forks=head`. One stray pinned assertion skips the whole test, so split mixed ones.
- Never hard-code a fork's gas number. Derive it: `Vm.spec.instruction.entry(@intFromEnum(Opcode.X)).info.static_gas` for the expectation, `evmz.eth.latest.call.base_gas + 5` for the override. A literal silently becomes a lie at the next repricing.
- To prove a spec hook drives a charge, diff two `t.CustomVm(.latest, ...)` overrides against each other, never one override against the builtin — the builtin is a fork value and moves.
