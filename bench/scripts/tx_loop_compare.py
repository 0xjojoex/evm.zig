#!/usr/bin/env python3
"""Run the transaction-loop lane on every engine and write one comparison."""

from __future__ import annotations

import argparse
import csv
import io
import shlex
import statistics
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
BENCH_DIR = SCRIPT_DIR.parent

CASES = ("eth-transfer", "stop-call", "erc20-transfer")
BASELINE_ROW = "evmz"

# Row name -> (engine family, build step, extra runner flags). The evmz row
# without its prepared-code pool is the one that prepares the callee's code on
# every transaction, as evmone does.
ROWS = {
    "evmz": ("evmz", "tx-loop", ()),
    "evmz-no-code-cache": ("evmz", "tx-loop", ("--no-code-cache",)),
    "evm2-interpreter": ("evm2", "evm2-tx-loop", ()),
    "evmone-baseline": ("evmone", "evmone-tx-loop", ()),
}

ROW_COLUMNS = (
    "suite",
    "engine",
    "case",
    "spec",
    "code_cache",
    "repeat",
    "txs",
    "elapsed_ns",
    "ns_per_tx",
    "gas_per_tx",
)
SUMMARY_COLUMNS = (
    "case",
    "engine",
    "spec",
    "code_cache",
    "repeats",
    "txs",
    "gas_per_tx",
    "median_ns_per_tx",
    "min_ns_per_tx",
    "ratio_vs_evmz",
)


def main() -> int:
    args = parse_args()
    out_dir = resolve_path(args.out_dir)
    raw_dir = out_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    families = selected_families(args.engine)
    row_names = [name for name, (family, _, _) in ROWS.items() if family in families]
    cases = args.case or list(CASES)

    rows: list[dict[str, str]] = []
    for case in cases:
        for row_name in row_names:
            for row in run_row(args, raw_dir, row_name, case):
                rows.append({**row, "engine": row_name})

    write_csv(out_dir / "rows.csv", rows, ROW_COLUMNS)
    summary = summarize(rows, cases, row_names)
    write_csv(out_dir / "summary.csv", summary, SUMMARY_COLUMNS)
    report = render(summary)
    (out_dir / "summary.md").write_text(report)
    sys.stdout.write(report)

    return check_gas(summary)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig-exe", default="zig")
    parser.add_argument("--optimize", default="fast")
    parser.add_argument("--profile", choices=("native", "zkvm"), default="native")
    parser.add_argument("--native-keccak", choices=("std", "xkcp"), default="xkcp")
    parser.add_argument("--spec", default="amsterdam")
    parser.add_argument("--txs", type=int, default=200_000, help="transactions per batch")
    parser.add_argument("--repeats", type=int, default=10, help="measured batches")
    parser.add_argument("--warmups", type=int, default=1, help="untimed batches")
    parser.add_argument("--case", action="append", choices=CASES, help="repeatable; default all")
    parser.add_argument(
        "--engine",
        action="append",
        help="repeatable; evmz, evm2, or evmone, also as a VM-loop row name such as evmone-baseline",
    )
    parser.add_argument("--out-dir", default="zig-out/tx-loop-compare")
    return parser.parse_args()


def resolve_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return (BENCH_DIR / path).resolve()


def selected_families(engines: list[str] | None) -> set[str]:
    families = {family for family, _, _ in ROWS.values()}
    if not engines:
        return families
    selected = set()
    for engine in engines:
        family = next((name for name in sorted(families) if engine.startswith(name)), None)
        if family is None:
            raise SystemExit(f"unknown engine {engine!r}; expected evmz, evm2, or evmone")
        selected.add(family)
    return selected


def run_row(args: argparse.Namespace, raw_dir: Path, row_name: str, case: str) -> list[dict[str, str]]:
    _, step, extra = ROWS[row_name]
    argv = [
        args.zig_exe,
        "build",
        f"-Doptimize={args.optimize}",
        f"-Dprofile={args.profile}",
        f"-Dnative-keccak={args.native_keccak}",
        step,
        "--",
        "--case",
        case,
        "--spec",
        args.spec,
        "--txs",
        str(args.txs),
        "--repeats",
        str(args.repeats),
        "--warmups",
        str(args.warmups),
        *extra,
    ]
    name = f"{case}-{row_name}"
    print(f"[tx-loop-compare] {name}", file=sys.stderr)
    result = subprocess.run(argv, cwd=BENCH_DIR, text=True, capture_output=True, check=False)
    (raw_dir / f"{name}.cmd").write_text(shlex.join(argv) + "\n")
    (raw_dir / f"{name}.stdout").write_text(result.stdout)
    (raw_dir / f"{name}.stderr").write_text(result.stderr)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.stderr.write(result.stdout)
        raise SystemExit(f"{name} failed with exit code {result.returncode}")

    rows = list(csv.DictReader(io.StringIO(result.stdout)))
    if len(rows) != args.repeats:
        raise SystemExit(f"{name} reported {len(rows)} batches, expected {args.repeats}")
    return rows


def summarize(rows: list[dict[str, str]], cases: list[str], row_names: list[str]) -> list[dict[str, str]]:
    summary = []
    for case in cases:
        medians = {}
        for row_name in row_names:
            batches = [row for row in rows if row["case"] == case and row["engine"] == row_name]
            ns_per_tx = [float(row["ns_per_tx"]) for row in batches]
            medians[row_name] = statistics.median(ns_per_tx)
            summary.append(
                {
                    "case": case,
                    "engine": row_name,
                    "spec": only(batches, "spec"),
                    "code_cache": only(batches, "code_cache"),
                    "repeats": str(len(batches)),
                    "txs": only(batches, "txs"),
                    "gas_per_tx": only(batches, "gas_per_tx"),
                    "median_ns_per_tx": f"{medians[row_name]:.3f}",
                    "min_ns_per_tx": f"{min(ns_per_tx):.3f}",
                }
            )
        baseline = medians.get(BASELINE_ROW)
        for entry in summary[-len(row_names) :]:
            ratio = medians[entry["engine"]] / baseline if baseline else None
            entry["ratio_vs_evmz"] = f"{ratio:.3f}" if ratio is not None else ""
    return summary


def only(batches: list[dict[str, str]], column: str) -> str:
    values = {row[column] for row in batches}
    if len(values) != 1:
        raise SystemExit(f"{column} varies across batches: {sorted(values)}")
    return values.pop()


def render(summary: list[dict[str, str]]) -> str:
    header = ("case", "engine", "spec", "gas/tx", "median ns/tx", "min ns/tx", "vs evmz")
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    for entry in summary:
        ratio = f"{entry['ratio_vs_evmz']}x" if entry["ratio_vs_evmz"] else ""
        cells = (
            entry["case"],
            entry["engine"],
            entry["spec"],
            entry["gas_per_tx"],
            entry["median_ns_per_tx"],
            entry["min_ns_per_tx"],
            ratio,
        )
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def check_gas(summary: list[dict[str, str]]) -> int:
    """Equal gas per transaction is the check that the engines ran the same work."""
    status = 0
    for case in dict.fromkeys(entry["case"] for entry in summary):
        gas = {entry["engine"]: entry["gas_per_tx"] for entry in summary if entry["case"] == case}
        if len(set(gas.values())) > 1:
            print(f"[tx-loop-compare] gas mismatch on {case}: {gas}", file=sys.stderr)
            status = 1
    return status


def write_csv(path: Path, rows: list[dict[str, str]], columns: tuple[str, ...]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    raise SystemExit(main())
