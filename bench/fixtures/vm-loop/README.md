# VM-loop Fixtures

Each fixture directory contains:

- `init.hex`: deploy/init bytecode, deployed once before timing.
- `calldata.hex`: calldata used for each timed runtime call.
- `num-runs.txt`: default timed call count.
- `gas-limit.txt`: optional finite gas limit for each timed runtime call.
- `host-profile.txt`: `null` or `mock`.

The checked-in evm-bench fixtures were built from
`github.com/ziyadedher/evm-bench` Solidity benchmarks. The Solidity 0.8 rows
use local `solc 0.8.28 --optimize --bin`; the legacy `snailtracer` row uses
`solcjs 0.4.26 --optimize --bin`.

The `*-loop` micro fixtures are handrolled bytecode. They use compact counted
loops with repeated opcode bodies so VM-loop reports can separate null-host
interpreter work from mock-host storage and log callbacks.

`recursive-self-call` and `wide-stack-child-call-loop` are executor-only
diagnostics for frame-stack storage. The first amplifies deep frames with empty
suspended stacks. The second retains 1000 words across 256 child calls to make
the suspend/resume copy cost visible; run it with
`--proxy-target-code-path fixtures/vm-loop/stop-target/init.hex`.

`child-return-4k-loop` isolates nested output handling by calling a target that
returns 4096 zero bytes 256 times. Run it through the executor so the real
frame lifecycle is included:

```sh
zig build vm-loop -Doptimize=ReleaseFast -- \
  --engine evmz-executor \
  --fixture fixtures/vm-loop/child-return-4k-loop \
  --proxy-target-code-path fixtures/vm-loop/return-4k-target/init.hex \
  --summary
```

The log matrix keeps 1000 loop iterations and 8 log operations per loop while
varying topics and data independently:

| Fixture | Topics per log | Data per log |
| --- | ---: | ---: |
| `log0-loop` | 0 | 0 bytes |
| `log0-data32-loop` | 0 | 32 bytes |
| `log4-loop` | 4 | 0 bytes |
| `log4-data32-loop` | 4 | 32 bytes |
