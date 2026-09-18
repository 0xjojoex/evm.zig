# evmz statetest

Executes one General State Test vector and writes the observed state root and
optional EIP-3155 opcode trace. It is an evmz tool: goevmlab and EEST consume
the same tool-owned parsing/execution code. The binary does not import EEST.

```sh
zig build cli-build -Doptimize=ReleaseSafe
zig-out/bin/evmz statetest --trace case.json
zig-out/bin/evmz statetest --trace-summary case.json
zig build statetest-test -Doptimize=ReleaseSafe
```
