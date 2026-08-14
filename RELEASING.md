# Releasing evmz

One repository and one versioned Zig package. `pkg/rlp`, `pkg/mpt`, and
`pkg/ssz` are directories inside that package, not packages of their own.
Guest ELFs are separately released artifacts, not additional Zig packages.

Zig versions package roots, not modules: `.version`, `.name`, `.fingerprint`,
and the `.paths` hash all belong to the fetched root, and a dependency is a
whole archive or git ref — the manifest has no way to address a subdirectory.
Independent module versions are not expressible, so evmz does not pretend to
have them.

## Public surface

A package release freezes its exported modules, consumer-visible build options,
and supported configurations together. Renaming or removing a build option is
a compatibility break exactly like renaming a function.

| Fetch | Options | Modules | Native dependencies fetched |
| --- | --- | --- | --- |
| root | *(none)* | `evmz`, `rlp`, `mpt`, `ssz` | ckzg, blst, mcl — lazy, on demand |
| root | `-Dcore=false` | `rlp`, `mpt`, `ssz` | none |
| root | `-Dprofile=zkvm` | `evmz` (guest) | none |

Other options that consumers may set — `-Dnative-keccak`, `-Dnative-secp256k1`,
`-Dstateless-schema`, `-Dpic`, `-Dguest-heap-bytes` — are part of the surface
with the same rules. Steps (`test`, `ci`, `bench-*`, …) are not: they are
development entry points and may change freely.

The dependency table describes configuration by a parent build. A repository
checkout may configure native providers for its test and guest-development
steps even when its selected public module uses the zkVM profile.

The root manifest allowlist is the consumer distribution boundary. Repository
tools and examples remain available in the Git tag but are excluded from the
fetched package and its content hash. Commands backed by those files run from a
source checkout before release; consumers receive the exported module graph and
the sources, headers, licenses, and documentation needed to use it.

The nested `pkg/*/build.zig.zon` files remain unpublished `0.0.0` development
descriptors. They preserve focused tests, fuzzers, benchmarks, and package
dependency checks without owning versions or release tags. MPT's local harness
resolves RLP through the sibling path; root consumers never execute it.

`include/evmz/evmz.h` is a reserved slot with no declarations. It enters the
compatibility surface when it gets one.

## Package versioning

The root `build.zig.zon` `.version` is authoritative and the tag is `vX.Y.Z`
for exactly that string. It is evmz's own semver, not a mirror of Zig's.

While below `1.0.0`:

- any break in an exported module, a build option, or observed execution
  behavior bumps the minor;
- backward-compatible fixes bump the patch;
- every break is spelled out in the changelog with its migration.

`.version` is bumped only in the release commit. There is no `-dev` suffix on
`main`: nothing in the tree reads `.version`, and consumers pin a URL and hash,
so the suffix would carry no signal. Adopt it if an artifact ever stamps its
own version into output or attestation — a guest built from `main` claiming a
released version is a conformance hazard.

## Zig toolchain

`.minimum_zig_version` pins a *released* Zig, never a dev build, so consumers
can stay on a stable toolchain. Each evmz release line supports one Zig minor;
adopting a new Zig minor is itself a minor bump, and README carries the
compatibility table.

## Tags

| Tag | Meaning |
| --- | --- |
| `vX.Y.Z` | evmz package release; versions every exported module |
| `guest-<track>@vX.Y.Z[-rc.N]` | current devnet guest convention; `vX.Y.Z` mirrors the exact fixture release |
| `guest-v0.1.0-rc.0` | frozen historical guest release, predating spec tracks |

The historical tags, their GitHub releases, and the `release/rlp` and
`release/ssz` branches stay reachable for existing consumers. Never retarget,
advance, or delete them, and never create new package-prefixed tags.

A guest release is an artifact identified by its bytes, not a Zig package. It
keeps its own gates and its own cadence; neither tag substitutes for the other.

## Guest releases

A guest build can compile a router for one or more known stateless schemas. A
released guest pins its accepted schema set explicitly; the current production
policy pins one schema and specification per artifact. The evidence record, not
the tag alone, states what the artifact accepts and what corpus it passed.

Three identities serve different purposes:

- the accepted **schema ids** select wire decoders, but do not by themselves
  prove the complete input/output contract;
- the **ELF SHA-256** identifies the exact released bytes;
- the **verification key** identifies the corresponding proving program and
  must be generated from those verified bytes.

### Current devnet naming convention

Devnet tags make the tested specification visible to operators:

~~~
guest-<track>@vX.Y.Z-rc.0
      └ track ┘ └ fixture release ┘
~~~

The version is not evmz software SemVer. It mirrors the complete authoritative
fixture release: `@vX.Y.Z` means `tests-<track>@vX.Y.Z`. An `-rc.N` suffix
records artifact qualification without changing that compatibility coordinate.
The separately numbered `tests-zkevm` wire/corpus release remains explicit in
`evidence.json` and the release notes.

The release qualification's `evidence.json` records both the network and exact
fixture release compiled into the tested guest. The naming policy pairs a
devnet tag with that evidence as follows:

~~~
network == "<track>-<major>"
fixture_release == "tests-<track>@vX.Y.Z"
~~~

Thus `@v8.1.0` names neither devnet-7 nor another devnet-8 fixture line such as
`v8.2.0`. The release pipeline does not derive this mapping from the tag: it
runs the guest benchmark as its qualification job, promotes that job's tested
artifact, and keeps `evidence.json` as the reviewable compatibility record.

A devnet track offers **no compatibility guarantee at any bump**. Upstream
publishes every `tests-*` release as a pre-release for the same reason: the
spec itself is unstable. Guest releases on a devnet track are published as
GitHub pre-releases, and the evidence record — not the version — is the
authoritative statement of what a given ELF proves. The fixture publisher owns
all three version components; evmz does not use minor or patch to number its own
iterations. RCs may advance while qualifying one fixture line, but each tag is
immutable and there is only one unsuffixed final tag for that line.

This convention does not define future stable guest versioning. Adopt an
evmz-owned artifact version only when a stable compatibility promise requires
one, and update this policy explicitly rather than changing the meaning of the
existing tag syntax.

### Cutting a guest release

Dispatch `Guest release` with the intended tag. The workflow calls `Guest
benchmark` internally with the release corpus and qualification checks, then
passes that same run's tested ELF, `evidence.json`, and report to the release
jobs. It verifies source ancestry and the ELF hash before generating the VK and
signatures; it never rebuilds the guest or searches another run. Correctness
and corpus qualification belong to the benchmark job that produced the
artifact.

## Changelog

One root `CHANGELOG.md`, one section per version, with module subsections only
where they have entries. Package-wide build, toolchain, and release changes go
in a package-level subsection rather than being repeated under each module.

The RLP and SSZ package changelogs are closed historical records of the subtree
era. Leave their entries and links intact; new entries belong in the root.

## Cutting a package release

From a pull request on the exact commit to publish:

1. set the root `.version`;
2. move the unreleased changelog entries into a dated section;
3. describe every break and its migration;
4. run the gates below;
5. merge, then tag the merged commit `vX.Y.Z`.

Releases are never cut from an unmerged branch. A tag that already exists and
points elsewhere is a hard failure — never move it.

## Package release gates

~~~sh
zig build ci -j2 --summary all    # broad repository gate
zig build ssz-bench -- --help     # core-less consumer compiles
(cd pkg/rlp && zig build test)
(cd pkg/mpt && zig build test)
(cd pkg/ssz && zig build test)
~~~

`pkg/ssz/bench` depends on the repository root with `-Dcore=false`, so it is
the checked-in proof that a module-only consumer builds without fetching any
native dependency.

Additionally, when the corresponding code changed:

- RLP: `zig build fuzz-rlp`;
- MPT: `zig build fuzz-mpt` and the pinned TrieTests;
- SSZ: pinned consensus SSZ conformance;
- execution or fork behavior: the applicable full-fork EEST lanes;
- guest code or guest ABI: the guest release gates, which are separate.

Native unit tests alone do not carry a release. Record the source commit and
each gate's result in the release notes.
