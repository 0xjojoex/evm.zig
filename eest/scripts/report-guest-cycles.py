#!/usr/bin/env python3
"""Summarise report-only guest cycles against an optional release baseline."""

from __future__ import annotations

import argparse
import json
import sys
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
class Aggregate:
    fixture_count: int
    crashes: int
    upstream_matches: int
    total: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=Path, required=True)
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
    parser.add_argument("--baseline-summary", type=Path)
    parser.add_argument("--summary-output", type=Path)
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


def aggregate(rows: dict[str, Row]) -> Aggregate:
    return Aggregate(
        fixture_count=len(rows),
        crashes=sum(row.crash is not None for row in rows.values()),
        upstream_matches=sum(row.upstream_matched is True for row in rows.values()),
        total=sum(row.steps or 0 for row in rows.values()),
    )


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
        "fixture_count": current.fixture_count,
        "crashes": current.crashes,
        "upstream_matches": current.upstream_matches,
        "total": current.total,
    }


def load_summary(args: argparse.Namespace, corpus: CorpusContext) -> Aggregate | None:
    if args.baseline_summary is None:
        return None
    document = json.loads(args.baseline_summary.read_text())
    expected = {
        "schema_version": 1,
        "backend": args.backend,
        "metric": metric(args),
        "corpus": args.fixtures,
        "corpus_digest": corpus.digest,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            raise ValueError(f"baseline summary {key} mismatch")
    baseline = Aggregate(
        fixture_count=int(document["fixture_count"]),
        crashes=int(document["crashes"]),
        upstream_matches=int(document["upstream_matches"]),
        total=int(document["total"]),
    )
    if baseline.fixture_count <= 0 or baseline.crashes != 0:
        raise ValueError("baseline summary is not a successful release run")
    if baseline.upstream_matches != baseline.fixture_count:
        raise ValueError("baseline summary has incomplete upstream matches")
    return baseline


def header(args: argparse.Namespace, corpus: CorpusContext) -> list[str]:
    lines = [
        f"# {'ZisK' if args.backend == 'zisk' else 'SP1'} execution {metric(args)}",
        "",
        f"- Current: `{args.current_ref}`",
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
) -> tuple[str, bool]:
    names = sorted(current)
    total = sum(current[name].steps or 0 for name in names)
    crashes = sum(current[name].crash is not None for name in names)
    upstream = sum(current[name].upstream_matched is True for name in names)

    lines = header(args, corpus)
    lines.extend((
        f"No stored baseline was available; reporting absolute {metric_singular(args)} counts only.",
        "",
        f"| Fixtures | Crashes | Upstream matches | Total {metric(args)} |",
        "| ---: | ---: | ---: | ---: |",
        f"| {len(names)} | {crashes} | {upstream}/{len(names)} | {total:,} |",
        "",
    ))
    if args.summary_only:
        failures = [
            current[name]
            for name in names
            if current[name].crash is not None or current[name].upstream_matched is not True
        ]
        if failures:
            lines.extend(("## Failures", ""))
            for row in failures:
                reason = row.crash or "upstream output mismatch"
                lines.append(f"- `{short_name(row)}`: {reason}")
            lines.append("")
        return "\n".join(lines), bool(names) and crashes == 0 and upstream == len(names)

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
    return "\n".join(lines), bool(names) and crashes == 0 and upstream == len(names)


def render_aggregate_comparison(
    args: argparse.Namespace,
    baseline: Aggregate,
    current: dict[str, Row],
    corpus: CorpusContext,
) -> tuple[str, bool]:
    current_aggregate = aggregate(current)
    delta = current_aggregate.total - baseline.total
    healthy = (
        current_aggregate.fixture_count > 0
        and current_aggregate.crashes == 0
        and current_aggregate.upstream_matches == current_aggregate.fixture_count
    )
    lines = header(args, corpus)
    lines.extend((
        f"| Baseline fixtures | Current fixtures | Crashes | Current upstream matches | Baseline {metric(args)} | Current {metric(args)} | Delta | Delta % |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {baseline.fixture_count} | {current_aggregate.fixture_count} | "
        f"{current_aggregate.crashes} | "
        f"{current_aggregate.upstream_matches}/{current_aggregate.fixture_count} | "
        f"{baseline.total:,} | {current_aggregate.total:,} | {delta:+,} | "
        f"{pct(delta, baseline.total)} |",
        "",
    ))
    failures = [
        row
        for row in current.values()
        if row.crash is not None or row.upstream_matched is not True
    ]
    if failures:
        lines.extend(("## Failures", ""))
        for row in sorted(failures, key=lambda item: item.name):
            reason = row.crash or "upstream output mismatch"
            lines.append(f"- `{short_name(row)}`: {reason}")
        lines.append("")
    return "\n".join(lines), healthy


def render_comparison(
    args: argparse.Namespace,
    baseline: dict[str, Row],
    current: dict[str, Row],
    corpus: CorpusContext,
) -> tuple[str, bool]:
    baseline_names = set(baseline)
    current_names = set(current)
    shared = sorted(baseline_names & current_names)
    added = sorted(current_names - baseline_names)
    dropped = sorted(baseline_names - current_names)

    baseline_steps = sum(baseline[name].steps or 0 for name in shared)
    current_steps = sum(current[name].steps or 0 for name in shared)
    delta = current_steps - baseline_steps
    public_matches = sum(
        baseline[name].public_values is not None
        and baseline[name].public_values == current[name].public_values
        for name in shared
    )
    baseline_upstream = sum(baseline[name].upstream_matched is True for name in shared)
    current_upstream = sum(current[name].upstream_matched is True for name in current_names)
    crashes = sum(
        current[name].crash is not None
        or (name in baseline and baseline[name].crash is not None)
        for name in current_names
    )

    healthy = (
        bool(shared)
        and not dropped
        and crashes == 0
        and public_matches == len(shared)
        and current_upstream == len(current_names)
    )

    lines = header(args, corpus)
    lines.extend((
        f"| Fixtures | Public outputs equal | Crashes | Baseline upstream matches | Current upstream matches | Baseline {metric(args)} | Current {metric(args)} | Delta | Delta % |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {len(shared)} | {public_matches}/{len(shared)} | {crashes} | {baseline_upstream}/{len(shared)} | {current_upstream}/{len(current_names)} | {baseline_steps:,} | {current_steps:,} | {delta:+,} | {pct(delta, baseline_steps)} |",
        "",
    ))

    if args.summary_only:
        lines.extend((
            f"- New since baseline: {len(added)}",
            f"- Missing from current run: {len(dropped)}",
            "",
        ))
        failures = [
            current[name]
            for name in sorted(current_names)
            if current[name].crash is not None or current[name].upstream_matched is not True
        ]
        if failures:
            lines.extend(("## Failures", ""))
            for row in failures:
                reason = row.crash or "upstream output mismatch"
                lines.append(f"- `{short_name(row)}`: {reason}")
            lines.append("")
        return "\n".join(lines), healthy

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
    return "\n".join(lines), healthy


def main() -> int:
    args = parse_args()
    try:
        current = load_rows(args.current)
        corpus = load_corpus_context(args.corpus_manifest)
        current_aggregate = aggregate(current)
        if args.summary_output:
            args.summary_output.parent.mkdir(parents=True, exist_ok=True)
            args.summary_output.write_text(
                json.dumps(summary_document(args, corpus, current_aggregate), indent=2) + "\n"
            )
        baseline = load_rows(args.baseline) if args.baseline and args.baseline.is_dir() else {}
        baseline_summary = load_summary(args, corpus)
        if baseline:
            report, healthy = render_comparison(args, baseline, current, corpus)
        elif baseline_summary:
            report, healthy = render_aggregate_comparison(args, baseline_summary, current, corpus)
        else:
            report, healthy = render_absolute(args, current, corpus)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        sys.stdout.write(report)
        return 0 if healthy else 1
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
