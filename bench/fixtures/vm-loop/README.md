# VM-loop Fixtures

Each fixture directory contains:

- `init.hex`: deploy/init bytecode, deployed once before timing.
- `calldata.hex`: calldata used for each timed runtime call.
- `num-runs.txt`: default timed call count.
- `gas-limit.txt`: optional finite gas limit for each timed runtime call.
- `host-profile.txt`: `null` or `mock`.

The checked-in evm-bench fixtures were built from
`github.com/ziyadedher/evm-bench` Solidity benchmarks with local
`solc 0.8.28 --optimize --bin`.

The `*-loop` micro fixtures are handrolled bytecode. They use compact counted
loops with repeated opcode bodies so VM-loop reports can separate null-host
interpreter work from mock-host storage and log callbacks.
