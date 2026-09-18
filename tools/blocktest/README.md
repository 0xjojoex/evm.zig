# evmz blocktest

The native block-test tool imports raw signed blocks from blockchain fixture JSON.
`tools/blocktest/root.zig` owns decoding, state seeding, and the execution session.
EEST imports that module and owns expected-exception checks and consume-direct
reporting. No tool imports EEST.

```sh
zig build cli-build
zig-out/bin/evmz blocktest --trace-summary tools/blocktest/testdata/chain.json
zig-out/bin/evmz blocktest --trace --run rollback_then_children tools/blocktest/testdata/chain.json
```
