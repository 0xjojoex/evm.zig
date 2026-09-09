# evmz-t8n

Transition tool for `ethereum/execution-specs` (EEST). Given a pre-state, a
block environment, and a transaction list, it applies the block-level state
transition with evmz and writes the post-state, receipts, and roots that EEST
uses to fill fixtures. Paris through Amsterdam are supported.

## Run the binary

```sh
zig build                      # installs zig-out/bin/evmz-t8n
zig build t8n -- <flags>       # or run straight from the build
```

```sh
zig-out/bin/evmz-t8n \
  --input.alloc alloc.json --input.env env.json --input.txs txs.json \
  --state.fork Prague --state.chainid 1 --state.reward 0 \
  --output.basedir out --output.alloc alloc.json --output.result result.json \
  --output.body txs.rlp
```

| Flag | Meaning |
| --- | --- |
| `--input.alloc/env/txs` | input documents; `stdin` is not accepted |
| `--output.alloc/result/body` | outputs, relative to `--output.basedir` |
| `--state.fork` | fork name, case-insensitive; `Paris` is an alias for `merge` |
| `--state.chainid` | positive chain ID, default 1 |
| `--state.reward` | `-1` (disabled) or `0` |
| `--state-test` | skip block-level system calls; EEST passes this for state tests |
| `--trace.callframes` | write `trace-<index>-<txhash>.jsonl` per accepted transaction |

Exit codes: 3 bad configuration (fork rule violated, unsupported option),
4 missing block hash, 10 malformed input, 11 I/O failure, 2 anything else.

## Input documents

The JSON shapes are declared once as Zig structs in `main.zig` (`EnvInput`,
`AllocInput`, `TransactionInput`, and their nested types) and parsed by
`std.json`. Unknown keys, duplicate keys, and missing required keys are
rejected. Quantities follow geth: `0x` means hex, a bare string or JSON number
means decimal. A transaction `to` of `""` or `null` means contract creation.

EEST always sends `0x` quantities, signs transactions in Python, and still
includes `secretKey` and authorization `signer`; the tool accepts them and only
signs itself when `v`, `r`, and `s` are all zero.

## Drive it through EEST

Both steps need an execution-specs checkout passed as `-Deest-source`.

```sh
ES=/path/to/execution-specs

# Fill fixtures with evmz as the transition tool.
zig build t8n-fill -Deest-source=$ES -- \
  --fork Prague tests/prague/eip7702_set_code_tx/test_set_code_txs.py -k chain_specific_id

# Fill with evmz and a reference t8n, diff alloc and result.
zig build t8n-diff -Deest-source=$ES -Dt8n-reference-bin=/path/to/other-t8n -- tests/prague
```

`t8n-diff` defaults to EELS as the reference. Any older `evmz-t8n` build works
too, which is the cheapest way to prove a refactor output-identical. Mismatch
artifacts land in `.zig-cache/eest-diff/mismatches/`.

## Replay a single case

EEST deletes the per-call inputs unless asked to keep them:

```sh
zig build t8n-fill -Deest-source=$ES -- ... --evm-dump-dir /tmp/t8n-dump
```

Each dumped directory holds `input/{alloc,env,txs}.json`, `output/`, and a
`t8n.sh` with the exact command line EEST ran. Run that script, or point the
binary at `input/`, to iterate on one case.

Geth's `cmd/evm/testdata` cases also work after dropping `null` fields and
hexifying bare decimal strings.
