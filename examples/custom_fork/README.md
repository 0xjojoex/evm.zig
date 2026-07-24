# custom_fork

Tour of every customization seam in the exact spec API. A fork is a plain
comptime `Spec` value; `spec.extend(patch)` derives a new one and
`evmz.Vm(spec)` compiles one exact VM per value.

| Module | Seam |
| --- | --- |
| `create_limits.zig` | Scalar value patches; `OptionalPatch` replace vs inherit, including removing an optional limit (`.replace = null`) |
| `gas_rules.zig` | Replacing a semantic `*const fn` policy (calldata pricing) |
| `custom_opcode.zig` | Instruction-table surgery: custom opcode on an unassigned byte, retired opcode, repriced builtin |
| `precompiles.zig` | Derived `precompile.Config` pricing/activation and a fully custom precompile type owning its own address |

`spec.block` (system-call hooks) and `spec.valueTransferLog` follow the same
patch pattern; `examples/op_deposit.zig` composes them into a complete
OP-style family.

Run from `examples/`:

```sh
zig build example -Dexample-name=custom_fork/main.zig
zig build example-test -Dexample-name=custom_fork/main.zig
```
