# custom_fork

Tour of every customization seam in the exact spec API. A fork is a plain
comptime `Spec` value; `spec.extend(patch)` derives a new one and
`evmz.Vm(spec)` compiles one exact VM per value.

| Module              | Seam                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `create_limits.zig` | Scalar value patches; `OptionalPatch` replace vs inherit, including removing an optional limit (`.replace = null`) |
| `gas_rules.zig`     | Replacing a semantic `*const fn` policy (calldata pricing)                                                         |
| `custom_opcode.zig` | Instruction-table surgery: custom opcode on an unassigned byte, retired opcode, repriced builtin                   |
| `precompiles.zig`   | Derived `precompile.Config` pricing/activation and a fully custom precompile type owning its own address           |

`spec.block` (system-call hooks) and `spec.valueTransferLog` follow the same
patch pattern; [`examples/op/`](../op/) composes them into an OP-style rollup
specification.

Run from the repository root (or from `examples/`):

```sh
zig build example -Dexample-name=custom_fork/main.zig
zig build example-test -Dexample-name=custom_fork/main.zig
zig build examples-test-all
```

Other runnable examples in `examples/` (`-Dexample-name=<path>`):

- `basic.zig` — transaction execution and storage write inspection
- `transaction_journal.zig` — embedding state that rolls back with EVM frames
- `bal_parallel.zig` — Block Access List (`BalVm`) parallel execution
- `op/main.zig` — OP Stack family specification and deposit/L1-cost hooks
