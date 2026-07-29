#!/usr/bin/env python3
"""Summarise report-only ZisK BenchmarkRun rows against an optional stored baseline."""

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
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--current-ref", required=True)
    parser.add_argument("--baseline-ref", default="none")
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


def header(args: argparse.Namespace) -> list[str]:
    return [
        "# ZisK execution steps",
        "",
        f"- Current: `{args.current_ref}`",
        f"- Baseline: `{args.baseline_ref}`",
        f"- ZisK: `{args.zisk}`",
        f"- ZisK Rust toolchain: `{args.zisk_rust}`",
        f"- Fixtures: `{args.fixtures}`",
        "- Scope: execution steps and public outputs only; no proof generation and no step-regression threshold.",
        "",
    ]


def render_absolute(args: argparse.Namespace, current: dict[str, Row]) -> tuple[str, bool]:
    names = sorted(current)
    total = sum(current[name].steps or 0 for name in names)
    crashes = sum(current[name].crash is not None for name in names)
    upstream = sum(current[name].upstream_matched is True for name in names)

    lines = header(args)
    lines.extend((
        "No stored baseline was available; reporting absolute step counts only.",
        "",
        "| Fixtures | Crashes | Upstream matches | Total steps |",
        "| ---: | ---: | ---: | ---: |",
        f"| {len(names)} | {crashes} | {upstream}/{len(names)} | {total:,} |",
        "",
        "## Per fixture",
        "",
        "| Fixture | Steps | Upstream |",
        "| --- | ---: | :---: |",
    ))
    for name in names:
        row = current[name]
        steps = "crash" if row.steps is None else f"{row.steps:,}"
        lines.append(f"| `{short_name(row)}` | {steps} | {mark(row.upstream_matched is True)} |")
    lines.append("")
    return "\n".join(lines), bool(names) and crashes == 0


def render_comparison(
    args: argparse.Namespace,
    baseline: dict[str, Row],
    current: dict[str, Row],
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
    current_upstream = sum(current[name].upstream_matched is True for name in shared)
    crashes = sum(baseline[name].crash is not None or current[name].crash is not None for name in shared)

    healthy = bool(shared) and not dropped and crashes == 0 and public_matches == len(shared)

    lines = header(args)
    lines.extend((
        "| Fixtures | Public outputs equal | Crashes | Baseline upstream matches | Current upstream matches | Baseline steps | Current steps | Delta | Delta % |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {len(shared)} | {public_matches}/{len(shared)} | {crashes} | {baseline_upstream}/{len(shared)} | {current_upstream}/{len(shared)} | {baseline_steps:,} | {current_steps:,} | {delta:+,} | {pct(delta, baseline_steps)} |",
        "",
    ))

    if added:
        lines.extend(("## New since baseline", "", *[f"- `{name}`" for name in added], ""))
    if dropped:
        lines.extend(("## Missing from current run", "", *[f"- `{name}`" for name in dropped], ""))

    lines.extend((
        "## Per fixture",
        "",
        "| Fixture | Baseline | Current | Delta | Delta % | Public equal | Upstream B/C |",
        "| --- | ---: | ---: | ---: | ---: | :---: | :---: |",
    ))
    for name in shared:
        before = baseline[name]
        after = current[name]
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
        current = load_rows(args.current)
        # A missing baseline is the first-run case, not a failure: the current
        # rows are still uploaded and become the next run's baseline.
        baseline = load_rows(args.baseline) if args.baseline and args.baseline.is_dir() else {}
        if baseline:
            report, healthy = render_comparison(args, baseline, current)
        else:
            report, healthy = render_absolute(args, current)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
        sys.stdout.write(report)
        return 0 if healthy else 1
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
