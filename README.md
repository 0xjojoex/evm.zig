# evm.zig

Zig implementation of the Ethereum Virtual Machine (EVM).

**It is my first Zig project** as my learning path to Zig. I'm sure there are many things that can be improved, feebacks are very welcome.

If you are looking for more comprehensive zig ethereum projects, I recommend checkout [zabi](https://github.com/Raiden1411/zabi).

## EEST fixture runner

There is an early subset runner for Ethereum Execution Spec Tests state-test fixtures:

```sh
scripts/fetch-eest-fixtures.sh
zig build eest -- .eest/fixtures/v5.4.0/fixtures/state_tests/path/to/test.json
scripts/classify-eest-fixtures.sh --exclude-static
```

It currently executes CALL transactions against pre-state accounts and checks comparable `post.*.state` code/storage fields. It intentionally reports unsupported or unchecked vectors separately instead of pretending to be a full client: transaction validation, state roots, logs hash, trie accounting, balances/fees/nonces, and full block tests are still outside this runner.

## TODO
- eof
- precompiles
- full evmc/spec-test integration
