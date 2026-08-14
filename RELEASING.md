# Releasing evmz

One repository, one fetched package, one version. `pkg/rlp`, `pkg/mpt`, and
`pkg/ssz` are directories inside that package, not packages of their own.

Zig versions package roots, not modules: `.version`, `.name`, `.fingerprint`,
and the `.paths` hash all belong to the fetched root, and a dependency is a
whole archive or git ref — the manifest has no way to address a subdirectory.
Independent module versions are not expressible, so evmz does not pretend to
have them.

## Public surface

A release freezes all three of these together. Renaming or removing a build
option is a compatibility break exactly like renaming a function.

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

## Versioning

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
| `guest-<track>@vX.Y.Z[-rc.N]` | guest ELF artifact; on a devnet track, `vX.Y.Z` mirrors the exact fixture release |
| `rlp-v0.1.0`, `ssz-v0.1.0` | frozen historical subtree releases |
| `guest-v0.1.0-rc.0` | frozen historical guest release, predating spec tracks |

The historical tags, their GitHub releases, and the `release/rlp` and
`release/ssz` branches stay reachable for existing consumers. Never retarget,
advance, or delete them, and never create new package-prefixed tags.

A guest release is an artifact identified by its bytes, not a Zig package. It
keeps its own gates and its own cadence; neither tag substitutes for the other.

## Guest releases

A guest ELF validates exactly one Ethereum specification —
`src/stateless/validate.zig` rejects any other at compile time — so the spec is
part of the artifact's identity, not a note attached to it. Guest tags carry it:

~~~
guest-glamsterdam-devnet@v8.1.0-rc.0
      └── track ────┘     └ fixture release ┘
~~~

**Devnet tracks.** The version is not evmz software SemVer. It mirrors the
complete authoritative fixture release: `@v8.1.0` means
`tests-glamsterdam-devnet@v8.1.0`. An `-rc.N` suffix records artifact
qualification without changing that compatibility coordinate. The separately
numbered `tests-zkevm` wire/corpus release remains explicit in the manifest and
release notes.

The claim is enforced, not conventional. The strict benchmark's
`evidence.json` records both the network and exact fixture release compiled
into the tested guest. For a devnet tag the release workflow requires

~~~
network == "<track>-<major>"
fixture_release == "tests-<track>@vX.Y.Z"
~~~

Thus `@v8.1.0` rejects evidence from both devnet-7 and another devnet-8 fixture
line such as `v8.2.0`.

A devnet track offers **no compatibility guarantee at any bump**. Upstream
publishes every `tests-*` release as a pre-release for the same reason: the
spec itself is unstable. Guest releases on a devnet track are published as
GitHub pre-releases, and the release manifest — not the version — is the
authoritative statement of what a given ELF proves. The fixture publisher owns
all three version components; evmz does not use minor or patch to number its own
iterations. RCs may advance while qualifying one fixture line, but each tag is
immutable and there is only one unsuffixed final tag for that line.

Two identities do the work a version number cannot:

- the **stateless schema id** (`-Dstateless-schema`, e.g. `0x1501`) is the wire
  compatibility token — a consumer asks it whether their input decodes;
- the **verification key** is the artifact identity — 32 bytes that change with
  any byte of the ELF, including a toolchain bump that changes no behavior.

**Fork tracks.** When a fork reaches mainnet its track opens at
`guest-amsterdam@v1.0.0` with ordinary semver, because that is the first point
at which a stability promise means anything.

The preferred next tag is `guest-glamsterdam-devnet@v8.1.0-rc.0`, paired with
`tests-glamsterdam-devnet@v8.1.0` and the separately recorded
`tests-zkevm@v0.8.0`. If the older pinned fixture line were given a scoped tag,
its exact coordinate would be `guest-glamsterdam-devnet@v7.2.0`, not
`@v7.0.0`. The already-published `guest-v0.1.0-rc.0` remains untouched as
historical evidence.

Dispatch `Guest benchmark` with `corpus=tests-zkevm` and
`release_gate=true`. A successful run emits one long-lived strict artifact
containing the tested ELF, `evidence.json`, and its report. Dispatch `Guest
release` with that run id and the intended tag. The release workflow verifies
the successful run, source ancestry, strict result counts, tag/spec mapping,
and ELF hash before generating the VK and signatures; it never rebuilds or
searches other runs.

## Changelog

One root `CHANGELOG.md`, one section per version, with module subsections only
where they have entries. Package-wide build, toolchain, and release changes go
in a package-level subsection rather than being repeated under each module.

The RLP and SSZ package changelogs are closed historical records of the subtree
era. Leave their entries and links intact; new entries belong in the root.

## Cutting a release

From a pull request on the exact commit to publish:

1. set the root `.version`;
2. move the unreleased changelog entries into a dated section;
3. describe every break and its migration;
4. run the gates below;
5. merge, then tag the merged commit `vX.Y.Z`.

Releases are never cut from an unmerged branch. A tag that already exists and
points elsewhere is a hard failure — never move it.

## Gates

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
