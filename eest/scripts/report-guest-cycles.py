#!/usr/bin/env python3
"""Summarise report-only guest cycles against an optional prior result set."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Row:
    name: str
    source: str
    block_number: int | None
    steps: int | None
    public_values: str | None
    upstream_matched: bool | None
    crash: str | None


@dataclass(frozen=True)
class BlockAttributes:
    gas_used: int
    stateless_input_byte_length: int


@dataclass(frozen=True)
class CorpusContext:
    attributes: dict[int, BlockAttributes]
    digest: str | None


@dataclass(frozen=True)
class KnownFailures:
    """Corpus-scoped fixtures expected to fail on this backend, and why.

    The list is strict in both directions: an entry that passes means the
    upstream cause was fixed and the entry must go, and an entry absent from the
    declared corpus means the list no longer describes it. A diagnostic run may
    allow matching failures; release gates remain exact.
    """

    reasons: dict[str, str]

    @staticmethod
    def load(path: Path | None, corpus: str, backend: str) -> KnownFailures:
        if path is None:
            return KnownFailures({})
        document = json.loads(path.read_text())
        if document.get("schema_version") != 1:
            raise ValueError("known-failure manifest schema_version mismatch")
        declared_corpus = document.get("corpus")
        if not isinstance(declared_corpus, str) or not declared_corpus:
            raise ValueError("known-failure manifest corpus is missing or malformed")
        if declared_corpus != corpus:
            return KnownFailures({})
        entries = document.get(backend, {})
        if not isinstance(entries, dict):
            raise ValueError(f"known-failure entries for {backend} are not an object")
        return KnownFailures({str(k): str(v) for k, v in entries.items()})

    def excused(self, row: Row) -> bool:
        return row.name in self.reasons


@dataclass(frozen=True)
class Aggregate:
    fixture_count: int
    crashes: int
    upstream_matches: int
    total: int
    known_failures: int = 0
    unexpected_failures: int = 0
    unexpected_passes: tuple[str, ...] = ()
    stale_known: tuple[str, ...] = ()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--current-ref", required=True)
    parser.add_argument("--baseline-ref", default="none")
    parser.add_argument("--backend", choices=("zisk", "sp1"), default="zisk")
    parser.add_argument("--zisk", default="v1.0.0-alpha (4b9f758fabc4955cac20af837019ccc31b803a46)")
    parser.add_argument("--zisk-rust", default="zisk-1.0.0")
    parser.add_argument("--sp1", default="v6.3.1")
    parser.add_argument("--fixtures", default="tests-zkevm@v0.6.2")
    parser.add_argument("--corpus-manifest", type=Path)
    parser.add_argument("--summary-output", type=Path)
    parser.add_argument("--known-failures", type=Path)
    parser.add_argument("--allow-known-failures", action="store_true")
    parser.add_argument("--summary-only", action="store_true")
    return parser.parse_args()


def load_rows(root: Path) -> dict[str, Row]:
    rows: dict[str, Row] = {}
    for path in sorted(root.rglob("*.json")):
        document = json.loads(path.read_text())
        name = document["name"]
        if name in rows:
            raise ValueError(f"duplicate metric name: {name}")
        execution = document["execution"]
        metadata = document.get("metadata", {})
        if "success" in execution:
            success = execution["success"]
            row = Row(
                name=name,
                source=metadata.get("source_path", "?"),
                block_number=metadata.get("block_number"),
                steps=int(success["total_num_cycles"]),
                public_values=success.get("public_values"),
                upstream_matched=bool(success["output_matched"]),
                crash=None,
            )
        else:
            crash = execution.get("crashed", {})
            row = Row(
                name=name,
                source=metadata.get("source_path", "?"),
                block_number=metadata.get("block_number"),
                steps=None,
                public_values=None,
                upstream_matched=None,
                crash=str(crash.get("reason", "unknown crash")),
            )
        rows[name] = row
    return rows


def pct(delta: int, baseline: int) -> str:
    if baseline == 0:
        return "n/a"
    return f"{delta / baseline * 100:+.2f}%"


def mark(value: bool) -> str:
    return "yes" if value else "NO"


def short_name(row: Row) -> str:
    return f"{row.source}: {row.name}"


def load_corpus_context(path: Path | None) -> CorpusContext:
    if path is None:
        return CorpusContext({}, None)
    document = json.loads(path.read_text())
    attributes = {}
    for block in document.get("blocks", []):
        attributes[int(block["block_number"])] = BlockAttributes(
            gas_used=int(block["gas_used"]),
            stateless_input_byte_length=int(block["stateless_input_byte_length"]),
        )
    digest = document.get("corpus_digest")
    return CorpusContext(attributes, str(digest) if digest else None)


def block_attribute(row: Row, attributes: dict[int, BlockAttributes]) -> BlockAttributes | None:
    return attributes.get(int(row.block_number)) if row.block_number is not None else None


def metric(args: argparse.Namespace) -> str:
    return "steps" if args.backend == "zisk" else "cycles"


def metric_singular(args: argparse.Namespace) -> str:
    return "step" if args.backend == "zisk" else "cycle"


def failed(row: Row) -> bool:
    return row.crash is not None or row.upstream_matched is not True


def aggregate(rows: dict[str, Row], known: KnownFailures = KnownFailures({})) -> Aggregate:
    return Aggregate(
        fixture_count=len(rows),
        crashes=sum(row.crash is not None for row in rows.values()),
        upstream_matches=sum(row.upstream_matched is True for row in rows.values()),
        total=sum(row.steps or 0 for row in rows.values()),
        known_failures=sum(failed(row) and known.excused(row) for row in rows.values()),
        unexpected_failures=sum(
            failed(row) and not known.excused(row) for row in rows.values()
        ),
        unexpected_passes=tuple(sorted(
            name for name in known.reasons if name in rows and not failed(rows[name])
        )),
        stale_known=tuple(sorted(name for name in known.reasons if name not in rows)),
    )


def healthy(current: Aggregate, allow_known_failures: bool) -> bool:
    return (
        current.fixture_count > 0
        and current.unexpected_failures == 0
        and (allow_known_failures or current.known_failures == 0)
        and not current.unexpected_passes
        and not current.stale_known
    )


def failure_lines(rows: Iterable[Row], known: KnownFailures, current: Aggregate) -> list[str]:
    lines: list[str] = []
    unexpected = sorted(
        (row for row in rows if failed(row) and not known.excused(row)),
        key=lambda row: row.name,
    )
    if unexpected:
        lines.extend(("## Failures", ""))
        for row in unexpected:
            lines.append(f"- `{short_name(row)}`: {row.crash or 'upstream output mismatch'}")
        lines.append("")
    if current.unexpected_passes:
        lines.extend((
            "## Known failures that now pass",
            "",
            "These are expected to fail on the pinned backend. They passed, so the",
            "upstream cause is fixed and each must be removed from the manifest.",
            "",
            *[f"- `{name}`: {known.reasons[name]}" for name in current.unexpected_passes],
            "",
        ))
    if current.stale_known:
        lines.extend((
            "## Known failures missing from this corpus",
            "",
            *[f"- `{name}`" for name in current.stale_known],
            "",
        ))
    return lines


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def summary_document(
    args: argparse.Namespace,
    corpus: CorpusContext,
    current: Aggregate,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "backend": args.backend,
        "metric": metric(args),
        "corpus": args.fixtures,
        "corpus_digest": corpus.digest,
        "source_ref": args.current_ref,
        "elf_sha256": args.elf_sha256,
        "fixture_count": current.fixture_count,
        "crashes": current.crashes,
        "upstream_matches": current.upstream_matches,
        "total": current.total,
        "known_failures": current.known_failures,
        "unexpected_failures": current.unexpected_failures,
    }


def header(args: argparse.Namespace, corpus: CorpusContext) -> list[str]:
    lines = [
        f"# {'ZisK' if args.backend == 'zisk' else 'SP1'} execution {metric(args)}",
        "",
        f"- Current: `{args.current_ref}`",
        f"- ELF SHA-256: `{args.elf_sha256}`",
        f"- Baseline: `{args.baseline_ref}`",
    ]
    if args.backend == "zisk":
        lines.extend((f"- ZisK: `{args.zisk}`", f"- ZisK Rust toolchain: `{args.zisk_rust}`"))
    else:
        lines.append(f"- SP1: `{args.sp1}`")
    lines.append(f"- Fixtures: `{args.fixtures}`")
    if corpus.digest:
        lines.append(f"- Corpus digest: `{corpus.digest}`")
    lines.extend((
        f"- Scope: execution {metric(args)} and public outputs only; no proof generation and no {metric_singular(args)}-regression threshold.",
        "",
    ))
    return lines


def render_absolute(
    args: argparse.Namespace,
    current: dict[str, Row],
    corpus: CorpusContext,
    known: KnownFailures,
) -> tuple[str, bool]:
    names = sorted(current)
    current_aggregate = aggregate(current, known)

    lines = header(args, corpus)
    lines.extend((
        f"No baseline result set was given; reporting absolute {metric_singular(args)} counts only.",
        "",
        f"| Fixtures | Known failures | Unexpected failures | Crashes | Upstream matches | Total {metric(args)} |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {current_aggregate.fixture_count} | {current_aggregate.known_failures} | "
        f"{current_aggregate.unexpected_failures} | {current_aggregate.crashes} | "
        f"{current_aggregate.upstream_matches}/{current_aggregate.fixture_count} | "
        f"{current_aggregate.total:,} |",
        "",
    ))
    if args.summary_only:
        lines.extend(failure_lines(current.values(), known, current_aggregate))
        return "\n".join(lines), healthy(current_aggregate, args.allow_known_failures)

    lines.extend((
        "## Per fixture",
        "",
        f"| Fixture | Gas used | Input bytes | {metric(args).title()} | Upstream |",
        "| --- | ---: | ---: | ---: | :---: |",
    ))
    for name in names:
        row = current[name]
        block = block_attribute(row, corpus.attributes)
        gas_used = f"{block.gas_used:,}" if block else "n/a"
        input_bytes = f"{block.stateless_input_byte_length:,}" if block else "n/a"
        steps = "crash" if row.steps is None else f"{row.steps:,}"
        lines.append(
            f"| `{short_name(row)}` | {gas_used} | {input_bytes} | {steps} | "
            f"{mark(row.upstream_matched is True)} |"
        )
    lines.append("")
    lines.extend(failure_lines(current.values(), known, current_aggregate))
    return "\n".join(lines), healthy(current_aggregate, args.allow_known_failures)


def render_comparison(
    args: argparse.Namespace,
    baseline: dict[str, Row],
    current: dict[str, Row],
    corpus: CorpusContext,
    known: KnownFailures,
) -> tuple[str, bool]:
    current_aggregate = aggregate(current, known)
    baseline_names = set(baseline)
    current_names = set(current)
    shared = sorted(baseline_names & current_names)
    added = sorted(current_names - baseline_names)
    dropped = sorted(baseline_names - current_names)

    allowed = {
        name for name in current_names
        if args.allow_known_failures and known.excused(current[name]) and failed(current[name])
    }
    measured = [name for name in shared if name not in allowed]
    baseline_steps = sum(baseline[name].steps or 0 for name in measured)
    current_steps = sum(current[name].steps or 0 for name in measured)
    delta = current_steps - baseline_steps
    public_matches = sum(
        baseline[name].public_values is not None
        and baseline[name].public_values == current[name].public_values
        for name in measured
    )
    baseline_upstream = sum(baseline[name].upstream_matched is True for name in shared)
    current_upstream = sum(current[name].upstream_matched is True for name in current_names)
    unexpected_crashes = sum(
        current[name].crash is not None
        or (name in baseline and baseline[name].crash is not None)
        for name in current_names if name not in allowed
    )
    expected_upstream_matches = len(current_names) - len(allowed)

    is_healthy = (
        bool(shared)
        and not dropped
        and unexpected_crashes == 0
        and public_matches == len(measured)
        and current_upstream == expected_upstream_matches
    )

    lines = header(args, corpus)
    lines.extend((
        f"| Fixtures | Measured fixtures | Public outputs equal | Known failures | Unexpected failures | Crashes | Baseline upstream matches | Current upstream matches | Baseline {metric(args)} | Current {metric(args)} | Delta | Delta % |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {len(shared)} | {len(measured)} | {public_matches}/{len(measured)} | "
        f"{current_aggregate.known_failures} | {current_aggregate.unexpected_failures} | "
        f"{current_aggregate.crashes} | {baseline_upstream}/{len(shared)} | "
        f"{current_upstream}/{expected_upstream_matches} | {baseline_steps:,} | "
        f"{current_steps:,} | {delta:+,} | {pct(delta, baseline_steps)} |",
        "",
    ))

    if args.summary_only:
        lines.extend((
            f"- New since baseline: {len(added)}",
            f"- Missing from current run: {len(dropped)}",
            "",
        ))
        lines.extend(failure_lines(current.values(), known, current_aggregate))
        return "\n".join(lines), is_healthy and healthy(
            current_aggregate, args.allow_known_failures
        )

    if added:
        lines.extend(("## New since baseline", "", *[f"- `{name}`" for name in added], ""))
    if dropped:
        lines.extend(("## Missing from current run", "", *[f"- `{name}`" for name in dropped], ""))

    lines.extend((
        "## Per fixture",
        "",
        "| Fixture | Gas used | Input bytes | Baseline | Current | Delta | Delta % | Public equal | Upstream B/C |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | :---: | :---: |",
    ))
    for name in shared:
        before = baseline[name]
        after = current[name]
        block = block_attribute(after, corpus.attributes)
        gas_used = f"{block.gas_used:,}" if block else "n/a"
        input_bytes = f"{block.stateless_input_byte_length:,}" if block else "n/a"
        if before.steps is None or after.steps is None:
            lines.append(
                f"| `{short_name(before)}` | {gas_used} | {input_bytes} | crash | crash | "
                "n/a | n/a | NO | n/a |"
            )
            continue
        row_delta = after.steps - before.steps
        public_equal = before.public_values is not None and before.public_values == after.public_values
        lines.append(
            f"| `{short_name(before)}` | {gas_used} | {input_bytes} | {before.steps:,} | "
            f"{after.steps:,} | {row_delta:+,} | "
            f"{pct(row_delta, before.steps)} | {mark(public_equal)} | "
            f"{mark(before.upstream_matched is True)}/{mark(after.upstream_matched is True)} |"
        )
    lines.append("")
    lines.extend(failure_lines(current.values(), known, current_aggregate))
    return "\n".join(lines), is_healthy and healthy(
        current_aggregate, args.allow_known_failures
    )


def main() -> int:
    args = parse_args()
    try:
        args.elf_sha256 = sha256(args.elf)
        current = load_rows(args.current)
        corpus = load_corpus_context(args.corpus_manifest)
        known = KnownFailures.load(args.known_failures, args.fixtures, args.backend)
        current_aggregate = aggregate(current, known)
        if args.summary_output:
            args.summary_output.parent.mkdir(parents=True, exist_ok=True)
            args.summary_output.write_text(
                json.dumps(summary_document(args, corpus, current_aggregate), indent=2) + "\n"
            )
        baseline = load_rows(args.baseline) if args.baseline and args.baseline.is_dir() else {}
        if baseline:
            report, is_healthy = render_comparison(args, baseline, current, corpus, known)
        else:
            report, is_healthy = render_absolute(args, current, corpus, known)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        sys.stdout.write(report)
        return 0 if is_healthy else 1
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
