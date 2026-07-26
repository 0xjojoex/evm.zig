#!/usr/bin/env python3
"""Compare report-only ZisK BenchmarkRun rows and write a Markdown summary."""

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
    steps: int | None
    public_values: str | None
    upstream_matched: bool | None
    crash: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--candidate-ref", required=True)
    parser.add_argument("--zisk", default="v1.0.0-alpha (4b9f758fabc4955cac20af837019ccc31b803a46)")
    parser.add_argument("--zisk-rust", default="zisk-1.0.0")
    parser.add_argument("--fixtures", default="tests-zkevm@v0.6.2")
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


def render(args: argparse.Namespace, baseline: dict[str, Row], candidate: dict[str, Row]) -> tuple[str, bool]:
    baseline_names = set(baseline)
    candidate_names = set(candidate)
    shared = sorted(baseline_names & candidate_names)
    missing_baseline = sorted(candidate_names - baseline_names)
    missing_candidate = sorted(baseline_names - candidate_names)

    baseline_steps = sum(baseline[name].steps or 0 for name in shared)
    candidate_steps = sum(candidate[name].steps or 0 for name in shared)
    delta = candidate_steps - baseline_steps
    public_matches = sum(
        baseline[name].public_values is not None
        and baseline[name].public_values == candidate[name].public_values
        for name in shared
    )
    baseline_upstream = sum(baseline[name].upstream_matched is True for name in shared)
    candidate_upstream = sum(candidate[name].upstream_matched is True for name in shared)
    crashes = sum(baseline[name].crash is not None or candidate[name].crash is not None for name in shared)

    healthy = (
        bool(shared)
        and not missing_baseline
        and not missing_candidate
        and crashes == 0
        and public_matches == len(shared)
    )

    lines = [
        "# ZisK execution-step A/B",
        "",
        f"- Baseline: `{args.baseline_ref}`",
        f"- Candidate: `{args.candidate_ref}`",
        f"- ZisK: `{args.zisk}`",
        f"- ZisK Rust toolchain: `{args.zisk_rust}`",
        f"- Fixtures: `{args.fixtures}`",
        "- Compatibility: v0.6.2 wire adapter, guarded ZisK DMA-memset source adjustment, and RV64IMA-only provider applied identically.",
        "- Scope: execution steps and public outputs only; no proof generation and no step-regression threshold.",
        "",
        "| Fixtures | Public outputs equal | Crashes | Baseline upstream matches | Candidate upstream matches | Baseline steps | Candidate steps | Delta | Delta % |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {len(shared)} | {public_matches}/{len(shared)} | {crashes} | {baseline_upstream}/{len(shared)} | {candidate_upstream}/{len(shared)} | {baseline_steps:,} | {candidate_steps:,} | {delta:+,} | {pct(delta, baseline_steps)} |",
        "",
    ]

    if missing_baseline:
        lines.extend(("## Missing from baseline", "", *[f"- `{name}`" for name in missing_baseline], ""))
    if missing_candidate:
        lines.extend(("## Missing from candidate", "", *[f"- `{name}`" for name in missing_candidate], ""))

    lines.extend((
        "## Per fixture",
        "",
        "| Fixture | Baseline | Candidate | Delta | Delta % | Public equal | Upstream B/C |",
        "| --- | ---: | ---: | ---: | ---: | :---: | :---: |",
    ))
    for name in shared:
        before = baseline[name]
        after = candidate[name]
        if before.steps is None or after.steps is None:
            lines.append(f"| `{short_name(before)}` | crash | crash | n/a | n/a | NO | n/a |")
            continue
        row_delta = after.steps - before.steps
        public_equal = before.public_values is not None and before.public_values == after.public_values
        lines.append(
            f"| `{short_name(before)}` | {before.steps:,} | {after.steps:,} | {row_delta:+,} | "
            f"{pct(row_delta, before.steps)} | {mark(public_equal)} | "
            f"{mark(before.upstream_matched is True)}/{mark(after.upstream_matched is True)} |"
        )
    lines.append("")
    return "\n".join(lines), healthy


def main() -> int:
    args = parse_args()
    try:
        baseline = load_rows(args.baseline)
        candidate = load_rows(args.candidate)
        report, healthy = render(args, baseline, candidate)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        sys.stdout.write(report)
        return 0 if healthy else 1
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
