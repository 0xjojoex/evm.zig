# Changelog

All notable changes to the evmz package — every module it exports, and the
build options it accepts — are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases follow [the release policy](https://github.com/0xjojoex/evm.zig/blob/main/RELEASING.md).

`pkg/rlp/CHANGELOG.md` and `pkg/ssz/CHANGELOG.md` are closed records of the
`0.1.0` subtree releases.

## [Unreleased]

### Package

- Requires Zig 0.17.x. Mise and CI pin 0.17.1. Optimization modes use
  `debug`, `safe`, `fast`, and `small`; update build commands from `ReleaseFast` to `fast`
  (and the corresponding names for other modes).

- evmz is released as one Zig package at the repository root. `rlp`, `mpt`, and
  `ssz` ship at the package version instead of being split into standalone
  package trees, and unreleased entries from their changelogs move here.
- `-Dcore=false` exports `rlp`, `mpt`, and `ssz` without configuring the EVM
  core, and the native precompile dependencies (ckzg, blst, mcl) are lazy, so a
  module-only consumer fetches no C sources.
- Removed the subtree split script and its workflow. The published
  `rlp-v0.1.0` and `ssz-v0.1.0` tags and their release branches stay reachable.
- Retained unpublished `0.0.0` package harnesses for focused tests, fuzzers,
  benchmarks, and dependency-boundary checks. Root consumers and releases use
  only the root package identity and version.
- Consolidated guest evidence into the existing `zkevm` command and one
  `evidence.json`, removed the dormant SP1 workflow branches and Python report
  stage, and made guest releases promote one explicit strict-run artifact.
  Fixture roots travel in the resolved corpus manifest, and the `rev8` scan
  joined `check-guest-elf`.
- Updated ERE platform providers and all release images to `v0.19.5`,
  including SP1 verifier exit-code validation and verifier archive linking fixes.
  SP1 now uses upstream `v6.9.0`, which includes the standards-conformance fixes,
  replacing the temporary fork patch. OpenVM retains `v2.1.0-preview` and adopts
  ERE's `openvm-accelerators` provider and matching host revision.
  Updated the ZisK guest and execute-only host to `v1.3.2-alpha` at its exact
  source commit with the `zisk-4.0.0` toolchain.
  ZisK releases require fresh guest qualification and Blake3 key generation.
  The provider retains unaligned scalar-memory lowering; nonzero guest returns
  propagate through the host protocol.

- Pinned the zkEVM fixture corpus to `tests-zkevm@v21.0.6`.
- Updated the execution fixture corpus to `tests@v21.0.1`.

### EVM

Added

- `crypto.secp256k1`: keys, RFC 6979 recoverable signing, verification, and
  raw-x ECDH over libsecp256k1 behind a seeded, allocator-backed `Context`,
  so a node built on evmz shares one curve implementation with the EVM
  instead of linking its own. Native profile only.
- `crypto.bls`: consensus-layer BLS verification over blst (validated
  `PublicKey`, an `Aggregate` of keys, and `verify` with the
  proof-of-possession ciphersuite), which together make `FastAggregateVerify`
  for light clients. Native profile only.
- `CompileOptions.transaction_journal`: an embedding-owned journal whose
  checkpoints pair with EVM checkpoints, so state kept outside the EVM rolls back
  with it. See `examples/transaction_journal.zig`.
- `execution.RootExecutionInit`: per-root entry mode for multi-root sessions.
  `.charge_call_target` charges the target's warm or cold access from the root's
  gas instead of warming sender and recipient, and `is_static` runs the root
  read-only. These are the frame-entry rules of EIP-8141. A charged root whose
  sender cannot fund its value still records the target's access for the block
  access list.
- `eth.bogota` (`Revision.bogota`): Hegotá in development, Amsterdam plus
  EIP-8141 frame transactions with EIP-8250 keyed nonces, as bogota-devnet-2
  runs them. Not `latest` until EIP-8141 is complete. The `dev` test preset
  includes it.
- EIP-8250 keyed nonces (`eth.eip8250`, `transaction.frames.KeyedNonces`): a
  frame transaction carries `nonce_keys` and a `u64` `nonce_seq` in place of
  its nonce. The keys' sequences live in `NONCE_MANAGER` storage; payment
  approval consumes them as protocol bookkeeping, charging first-use state gas
  from the approving frame's pool, and intrinsic gas prices the nonce calldata
  and each key's slot access. `Transaction` gains `nonce_keys`.
- EEST state and transaction fixtures for `Bogota` load: the fixture tools parse
  `frames`, `signatures`, `maxFee`, and `nonceKeys`, and a frame envelope that
  fails to decode maps to EEST's frame exception names.
- Blockchain fixtures on EEST's timestamp transition networks
  (`<From>To<To>AtTime<N>k`, such as `AmsterdamToBogotaAtTime15k`) run: each
  block executes under the fork its timestamp selects, with that fork's blob
  schedule. `fixtures.Network` parses the name, and `fixtures.parseFork` keeps
  EEST's fork spelling; `BogotaBPOIncrease` and `BogotaBPODecrease` map to
  Bogotá.
- EIP-8253 in `eth.bogota`: on the fork block, before the block's system calls
  and at block access index zero, each listed zero-nonce storage account gets
  nonce one. `BlockSpec.bumps_zero_nonce_storage_accounts` enables it, and the
  caller marks the fork block with `BeforeBlockContext.fork_activation`, which
  carries the chain's account list. Blockchain fixtures pass
  `config.zeroNonceStorageAccounts` on the first block past a transition
  boundary.
- EIP-8141 frame transactions (type `0x06`, `TxKind.frame`) for specs whose
  `TransactionSpec.active_kinds` contains `.frame` and whose
  `TransactionSpec.frame` carries `transaction.frames.Params`; specs extended
  from `bogota` inherit both. `transaction.frames` holds the frame and signature
  shapes, the canonical signature hash (eliding empty-`msg` signature bytes to
  their length), static validity, the `max_fee` budget and `max_cost`, GASPRICE,
  SECP256K1 and P256 signature validation, and settlement. The raw decoder reads
  type-`0x06` envelopes, and `Transaction` gains `frames`, `signatures`, and
  `max_fee`.
- The Ethereum transition runs frame transactions through its usual phases.
  `prepare` returns a `Prepared` whose `frame.plan.max_cost` a rollup may widen
  before `transactPrepared`; the completed result's `frame` carries the payer,
  frame receipts, and the settled base fee, priority fee, and payer refund.
  Frames run as roots of one session, with atomic batches, per-frame receipts
  and log ranges, and the default code's VERIFY approval.
- Block execution encodes frame transaction receipts in EIP-8141's shape,
  `[cumulative_gas_used, payer, [[status, [gas_used, state_gas_used], logs]...]]`
  with no transaction status or bloom, and counts a frame transaction's blob
  hashes toward the block's blob gas. `TxReceiptView` gains `frame`, the payer
  and frame receipts.
- The EIP-8141 frame opcodes in `eth.bogota`'s instruction spec: APPROVE
  (`0xaa`), TXPARAM (`0xb0`, with EIP-8250's keyed-nonce parameters),
  FRAMEDATALOAD, FRAMEDATACOPY, FRAMEPARAM, SIGPARAM, and SIGDATACOPY
  (`0xb1`–`0xb5`). `instruction.frame.install` adds them to any instruction
  spec. They read the running frame transaction through
  `TransactionEnvironment.frame_transaction` and halt exceptionally outside one.
  APPROVE from contract code and from the default code share one approval path,
  `Executor.frameApprove`, which hosts expose as the optional
  `Host.VTable.frameApprove`.
- Frame specs compile an executor-owned frame journal into every state
  checkpoint: approval context, frame receipts' state gas, and per-slot
  state-gas ownership roll back with the call, frame, or batch that produced
  them. A frame's state-gas pool is its reservoir and never spills into regular
  gas, so exhausting it is an ordinary out-of-gas at any depth.

Changed

- Program `Context.beginRootSession` takes an `ExecutionScopeInit`, so a
  session's warm set is applied once. `Context.runRoot` takes a
  `RootExecutionInit` in its place and returns the root's `log_range` alongside
  its stage and result; `LogBuffer.View.slice` reads it.
- `TransactionEnvironment.frame_index` names the executing EIP-8141 frame, and
  `frame_transaction` points at the running frame transaction's
  `transaction.frames.Context`.
  `NativeContractLedger.init` takes whether state gas may spill into regular
  gas, and `ValidationError` gains `type_6_tx_pre_fork` and the EEST-named
  `type_6_invalid_frame_format`, `type_6_invalid_signature` and
  `type_6_invalid_frame_execution` rejections.
- A checked system call whose contract has no code fails with the new executor
  error `SystemContractEmpty`, and the block STF reports it as
  `Status.system_contract_empty` instead of `system_contract_failed`, which
  now means only a call that ran and failed. This matches EEST's
  `SYSTEM_CONTRACT_EMPTY` and `SYSTEM_CONTRACT_CALL_FAILED`.
- libsecp256k1 is the only native secp256k1 provider and is always fetched
  for native builds. `-Dnative-secp256k1` is removed; the std recovery path
  survives only as a test oracle. Native builds already compile C for the
  precompiles, so no consumer loses a C-free configuration.
- Native contracts are renamed for the tier, and their code is selected at
  compile time. `Spec.reentrant_native_contract` is `Spec.native_contract`, a type
  that declares `active` and `execute(self, ctx, call)`. `ReentrantNativeContractRuntime`
  and its vtable are gone: the executor option `native_contract` binds an instance
  of that type, and an active address without one fails with `MissingNativeContract`.
  `ReentrantNativeContractCall` is `NativeContractCall` and `NoReentrantNativeContracts`
  is `NoNativeContracts`.
- Native contracts no longer receive a `Host`. `ctx` is the executor's
  `NativeContext`: journaled state, logs, and `addBalance`/`subtractBalance` for
  issuance, with no call. An entry returns a `NativeContractStep`: `.done`, or
  `.call` with one CALL-family child. The executor runs and settles the child, then
  enters the native again, so native recursion no longer uses the Zig stack.
  `ReentrantNativeContractResult` is gone; gas lives in the executor-owned
  `NativeContractLedger`. See `doc/native-contracts.md`.
- Native effects respect static context, and a failed activation unwinds state gas
  and drops refunds like a failed bytecode frame. `@TypeOf(ctx).spec` is the
  executor's own spec, so native pricing follows `Spec.extend` overrides.
- System-call entry rejects native targets with `NativeSystemCallUnsupported`.

Removed

- `SelfDestructPolicy.reset_nonce`. SELFDESTRUCT preserves the contract nonce
  until transaction finalization, so reinvoked CREATE uses the correct address
  and a reverted frame restores its nonce increment.
- `error.TraceIndexOverflow` from `executor.errors.Error` and the trace tape.
  Every raising site was unreachable by construction (`pc`, `memory_size`, and
  `stack_len` are EVM-bounded; step counts are memory-bounded), so the
  narrowing is now a plain `@intCast`.

### RLP

Added

- `decodeInto`/`decodeIntoAs` decode a nonallocating value directly into
  caller-owned storage, leaving the destination undefined on failure.
- `listEncodedLen` sizes a list from its payload length, so callers can reserve
  exact output storage before encoding.
- `Optional(InnerCodec)` encodes `null` as the empty byte string, and `?T` now
  infers it whenever the inner codec can never encode that same empty byte
  string. Codecs report the property with `pub const may_encode_empty`, which
  defaults to `true` for codecs that stay silent.
- `Cursor.peek`/`Decoder.peek` parse the next item without consuming it or
  charging the decode budget.

Changed

- Simplified encoding to reduce cycles.

Removed

- `OptionalFixedBytes(N)`. `?[N]u8` infers the same codec, and
  `Optional(FixedBytes(N))` spells it explicitly.

### MPT

First appearance of the module; it had no subtree release.

Added

- Structural Ethereum Merkle Patricia Trie primitives: canonical roots, proof
  verification against a sealed witness, and sparse updates over raw byte keys.
- Caller-owned allocator policy, so guests can use fixed or bump allocation.
- Caller-supplied Keccak-256 execution context for native and zkVM backends,
  with a stdlib default.
- Verified against the official `ethereum/tests/TrieTests` corpus.
- Authenticated witness catalog (`Catalog`, `Trie.catalogBuilder`): immutable
  topology linked once from a sealed witness index, then served without
  hashing, index search, allocation, or RLP decoding. Hashed children absent
  from the witness stay opaque authenticated references.
- Catalog-backed sparse updates (`updateCatalog`, `updateSortedCatalog`, and
  their `Batch`/`WithWorkspace` forms) over a reusable
  `CatalogUpdateWorkspace`.
- Block-local stateless mutation and commit (`updateStatelessCatalog`,
  `StatelessWorkspace`, `StatelessUpdate`): mutable occurrences are created
  only for selected paths, untouched children stay authenticated references,
  and one post-state root is recomputed bottom-up.
- Allocation-free fixed-32-byte-key batch binding (`fixed_key.bindSorted`),
  walking integer links over an authenticated catalog and sharing prefixes
  between sorted state and storage keys.
- `IndexedNodes.allocationBytes` reports bytes retained by an owned index, so
  guests can budget fixed or bump allocation.

Changed

- Lazily materialize hashed branch children.
- Borrow sparse branches during encoding and updates.
- Decode only the selected proof branches.

### SSZ

Added

- Borrowed SSZ views and packed bitfields.
- Borrowed Merkle child roots on the `hash_tree_root` path.

Changed

- Consolidated borrowed decoding onto a single codec surface.
- `Mapped` takes its mapping as a namespace type with `pub fn toWire`/`fromWire`
  instead of a struct of function pointers, so one `WireMapping` declaration now
  serves both `ssz.Mapped` and `rlp.Mapped`.
