# Stateless API and Wire Boundary

Status: draft

## Decision

The stateless state-transition function is a stable library surface. Serialized
guest inputs and outputs are immutable, versioned wire contracts. EEST, ERE,
and zkVM runtimes are adapters around those contracts; none of them owns
Ethereum block-transition semantics.

```text
                         stable library boundary
                                   |
                                   v
fixture JSON ---- adapter ----> stateless.Input
wire bytes ---- wire codec ----> stateless.Input ----> eth.BlockSTF
                                   |                       |
                                   |                       v
                                   +------------------ eth.BlockSTF.Result
                                                           |
                      +------------------+------------------+
                      |                  |                  |
                      v                  v                  v
                wire output       ERE commitment     native diagnostics
```

The external wire may contain compatibility fields or representations that are
not useful to execution. Those fields remain part of their versioned codec but
must be discarded or verified during normalization rather than becoming trusted
Ethereum facts.

## Vocabulary

Three interfaces currently risk being described as the stateless ABI:

1. **Library API**: typed Zig values passed to stateless validation and
   `eth.BlockSTF`.
2. **Wire contract**: schema-prefixed serialized input and its corresponding
   serialized output.
3. **Runtime ABI**: zkVM-specific private-input and public-output syscalls.

They should be named and versioned independently.

## Ownership

### Stateless library

The stateless library owns:

- normalization from a decoded wire value into Ethereum execution facts;
- construction of the witness-backed state reader and header-history source;
- conversion of raw signed transactions into canonical Ethereum transactions;
- invocation of `eth.BlockSTF`;
- mapping the detailed `eth.BlockSTF.Result` into a public wire result.

It does not own block lifecycle semantics. Withdrawals, requests, system calls,
transaction ordering, header reconstruction, and derived-vs-claimed checks stay
in `eth.BlockSTF`.

The first library entry should remain conceptually small:

```zig
pub fn validate(
    allocator: std.mem.Allocator,
    input: stateless.Input,
) !eth.block_stf.Result;
```

`stateless.Input` is a normalized Ethereum/proof model. It must not contain
fixture names, JSON fields, expected fixture outputs, ERE framing, schema ids,
or untrusted sender overrides.

### Versioned wire

Each wire version owns an exact byte contract:

```text
schema id -> exact input decoder -> normalize -> validate -> exact output encoder
```

For a released version:

- field count, order, byte order, SSZ limits, and hash-tree-root behavior are
  immutable;
- an existing schema id is never reinterpreted;
- canonical but unused fields are decoded and explicitly discarded or verified;
- unknown schema ids are rejected;
- the output codec is selected by the decoded input schema version;
- byte-for-byte and hash-tree-root vectors lock the contract.

The current `0x0001` target should mean the exact pinned tests-zkevm v0.5
contract, not a locally simplified interpretation of it.

### EEST adapters

EEST has two separate jobs:

```text
EEST ABI conformance
  statelessInputBytes -> wire validator -> statelessOutputBytes comparison

EEST direct BlockSTF conformance
  fixture JSON + pre-state or executionWitness -> BlockInput -> BlockSTF
```

The first lane treats serialized bytes as canonical vectors. The second lane is
intentionally fixture-shaped and may understand `blocks`, `executionWitness`,
`genesisBlockHeader`, `expectException`, and other EEST fields. That knowledge
must remain under `eest/`.

### ERE adapter

ERE owns workload and host integration concerns:

- input framing expected by an ERE host;
- execution of the selected guest artifact;
- conversion of canonical wire output into the public-value convention expected
  by that host;
- benchmark metadata and output comparison.

ERE does not define `stateless.Input`, Ethereum validation status, witness
semantics, or the meaning of schema `0x0001`. If the current ERE host contract
differs from the pinned tests-zkevm contract, it receives a separate adapter or
wire version rather than changing an existing codec.

### Guest runtime

The guest runtime owns only transport and resource policy:

```text
read private bytes
allocate bounded scratch memory
call wire dispatcher
commit public bytes
```

Guest error framing and heap telemetry are runtime diagnostics. They are not
fields in the Ethereum validation result.

## Trust Boundary

| Wire material | Normalized meaning |
| --- | --- |
| `new_payload_request` | Block body and header claims to validate |
| `witness.state` | MPT proof-node material for `WitnessStateReader` |
| `witness.codes` | Code preimages verified by code hash |
| `witness.headers` | Verified parent context and `BLOCKHASH` history |
| `chain_config` | Chain id, revision activation, and blob schedule |
| `public_keys` | Untrusted compatibility hints; ignore or verify |

Sender identity always comes from canonical signed-transaction recovery. A wire
version may still require `public_keys` for compatibility; accepting that field
does not grant it authority.

## Proposed Module Shape

```text
src/stateless.zig
src/stateless/input.zig       normalized stateless library types
src/stateless/validate.zig    normalization-independent validation entry
src/stateless/wire.zig        public versioned-wire facade
src/stateless/wire/v1.zig     immutable schema 0x0001 codec and mapping
src/stateless/wire/v1_smoke.zig
                              synthetic native/guest smoke input
src/stateless/wire/v1_test.zig
                              schema-v1 regression tests
src/stateless/ssz.zig         bounded SSZ primitives
src/stateless/ere.zig         ERE public-value adapter

guest/io.zig                  zkVM runtime IO only
eest/src/stateless.zig        wire conformance runner
eest/src/stateless_block_stf.zig
                              direct witness fixture adapter
```

The final filenames can change. The required boundary is that a versioned codec
can be replaced or added without changing `eth.BlockSTF` or the normalized
library API.

`src/stateless/tx.zig` currently performs canonical Ethereum transaction
decoding and sender recovery. Moving that primitive under `src/eth/` is a
separate ownership decision; it is not required to split the wire boundary.

## Validation Flow

```zig
pub fn validateWireBytes(allocator: Allocator, bytes: []const u8) ![]u8 {
    const version = try wire.detectVersion(bytes);
    return switch (version) {
        .v1 => {
            const decoded = try wire.v1.decodeInput(allocator, bytes);
            const input = try wire.v1.normalize(allocator, decoded);
            const result = try stateless.validate(allocator, input);
            return wire.v1.encodeOutput(allocator, decoded, result);
        },
    };
}
```

This is illustrative. In guest builds, decoded and normalized values should
borrow input bytes where possible and use one block-lifetime arena.

## Result Layers

The detailed native result and public result serve different consumers:

```text
eth.BlockSTF.Result
  detailed status, transaction index, derived roots and commitments
        |
        v
wire.v1.ValidationResult
  exact public fields required by schema v1
        |
        v
ERE/zkVM public commitment
  host-specific committed bytes or digest
```

A failed wire decode may map to the sentinel failure output required by that
wire version. Native callers should retain a detailed decode error rather than
having every malformed input appear as `invalid_witness`.

## Current Status

The first boundary split is implemented:

- `stateless.Input` carries runtime `eth.Revision`, chain id, block context, and
  witness material without schema or fixture fields;
- `wire.v1` decodes the four-field `0x0001` input, including `public_keys`;
- normalization deliberately drops `public_keys` and canonical signed
  transaction recovery remains authoritative;
- Amsterdam-shaped payload requests decode through the v1 adapter;
- header-witness parsing, transaction preparation, and `BlockSTF` invocation
  live in `stateless/validate.zig`;
- EEST, ERE, and guest payloads call the versioned wire dispatcher.

Remaining wire work is narrower:

- decide whether schema v1 should continue accepting historical fork-specific
  payload variants or be tightened to only the exact pinned v0.5 shapes;
- define a policy or remove the currently empty `ValidationOptions`;
- keep ERE output evolution separate from the pinned v1 fixture output;
- continue reducing allocations in SSZ decode/hash without changing bytes.

The direct `eest-stateless-block-stf` runner does not prove these ABI properties
because it builds `BlockInput` from fixture JSON and bypasses the serialized
wire.

## Migration Sequence

1. Lock the exact pinned `0x0001` input, output, limits, and roots with upstream
   vectors. In progress: a pinned Amsterdam v0.5 vector passes byte-for-byte.
2. Extract schema dispatch and `wire.v1` without changing validation behavior.
   Done.
3. Introduce the normalized stateless input and a single mapping into
   `eth.BlockSTF.BlockInput`. Done.
4. Keep detailed native results and wire/public results as explicit mappings.
   Done for v1; preserve this when ERE output evolves.
5. Point EEST byte conformance, direct BlockSTF fixtures, ERE, and the guest at
   their respective adapters. Done.
6. Add a new wire version only when an external contract genuinely changes.

## Non-Goals

- Designing witness generation or an execution-client RPC.
- Making `eth.BlockSTF` depend on SSZ, EEST, ERE, or a zkVM runtime.
- Treating public-key hints as trusted sender identity.
- Creating a generic repository-wide SSZ framework before the stateless codec
  needs it.
- Hiding detailed native failures behind the public boolean result.

## Open Decisions

1. Whether the current ERE host output becomes `wire.v2` or remains an ERE-only
   projection over `wire.v1`. Keep it adapter-only unless another producer must
   exchange those bytes directly.
2. Whether canonical raw transaction decoding moves from `stateless/tx.zig` to
   `eth/`. Move it only when a second non-stateless caller needs the same
   primitive.
3. Whether SSZ types continue with manual implementations or move toward a
   comptime `derive(T, overrides)` codec. This is an implementation choice and
   must not alter released wire bytes.
