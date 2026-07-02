#!/usr/bin/env python3
"""Run evm.zig benchmark layers and write a compact comparison report."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import platform
import re
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
BENCH_DIR = SCRIPT_DIR.parent
REPO_ROOT = BENCH_DIR.parent
EEST_DIR = REPO_ROOT / "eest"

DEFAULT_EEST_ROOT = (
    REPO_ROOT
    / ".eest"
    / "benchmarks"
    / "tests-benchmark-v0.0.9"
    / "fixtures"
    / "blockchain_tests"
    / "benchmark"
    / "compute"
)

VM_LOOP_FIXTURES = (
    "fixtures/vm-loop/arithmetic-loop",
    "fixtures/vm-loop/memory-mstore-loop",
    "fixtures/vm-loop/keccak-loop",
    "fixtures/vm-loop/ten-thousand-hashes",
    "fixtures/vm-loop/storage-sload-loop",
    "fixtures/vm-loop/storage-sstore-loop",
    "fixtures/vm-loop/log0-loop",
    "fixtures/vm-loop/erc20-mint",
    "fixtures/vm-loop/erc20-transfer",
)

VM_LOOP_BASELINE_ENGINE = "evmz"
VM_LOOP_ENGINES = (VM_LOOP_BASELINE_ENGINE, "evmone-baseline", "evmone", "revm")

EEST_CASES = (
    {
        "name": "arith_add_1m",
        "path": "instruction/arithmetic/arithmetic.json",
        "matches": ("opcode_ADD--", "value_1M"),
    },
    {
        "name": "memory_mstore_1m",
        "path": "instruction/memory/memory_access.json",
        "matches": (
            "mem_size_0",
            "offset_initialized_False",
            "offset_0",
            "opcode_MSTORE-benchmark",
            "value_1M",
        ),
    },
    {
        "name": "control_jump_1m",
        "path": "instruction/control_flow/jump_benchmark.json",
        "matches": ("value_1M",),
    },
    {
        "name": "storage_tload_1m",
        "path": "instruction/storage/tload.json",
        "matches": ("fixed_value_False", "fixed_key_False", "value_1M"),
    },
)

EEST_ENGINES = ("evmz", "evmone-baseline", "evmone")


def main() -> int:
    args = parse_args()
    out_dir = resolve_path(args.out_dir)
    raw_dir = out_dir / "raw"
    out_dir.mkdir(parents=True, exist_ok=True)
    raw_dir.mkdir(parents=True, exist_ok=True)

    checkpoint_path = resolve_path(args.checkpoint) if args.checkpoint else out_dir / "evmz-checkpoint.json"
    report_path = resolve_path(args.report) if args.report else out_dir / "report.md"
    eest_root = resolve_path(args.eest_root)

    env = collect_environment(args)
    vm_loop_rows = run_vm_loop(args, raw_dir)
    host_rows = run_host_matrix(args, raw_dir, out_dir)
    kernel_rows = run_kernel(args, raw_dir, out_dir)
    eest_rows = run_eest(args, raw_dir, out_dir, eest_root)

    checkpoint = build_checkpoint(env, args, vm_loop_rows, host_rows, kernel_rows, eest_rows)
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    checkpoint_path.write_text(json.dumps(checkpoint, indent=2, sort_keys=True) + "\n")

    baseline = load_json(resolve_path(args.baseline)) if args.baseline else None
    report = render_report(
        env=env,
        args=args,
        vm_loop_rows=vm_loop_rows,
        host_rows=host_rows,
        kernel_rows=kernel_rows,
        eest_rows=eest_rows,
        checkpoint_path=checkpoint_path,
        baseline_path=resolve_path(args.baseline) if args.baseline else None,
        checkpoint=checkpoint,
        baseline=baseline,
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report)

    print(f"report={report_path}")
    print(f"checkpoint={checkpoint_path}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig-exe", default="zig")
    parser.add_argument("--optimize", default="ReleaseFast")
    parser.add_argument("--out-dir", default="../output/bench-report")
    parser.add_argument("--report")
    parser.add_argument("--checkpoint")
    parser.add_argument("--baseline")
    parser.add_argument("--eest-root", default=str(DEFAULT_EEST_ROOT))
    parser.add_argument("--skip-eest", action="store_true")
    parser.add_argument("--kernel-iterations", type=int, default=100_000)
    parser.add_argument("--host-iterations", type=int, default=100_000)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--eest-iterations", type=int, default=3)
    parser.add_argument("--eest-warmups", type=int, default=1)
    return parser.parse_args()


def resolve_path(value: str | Path) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return (BENCH_DIR / path).resolve()


def collect_environment(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "platform": f"{platform.system()} {platform.machine()}",
        "zig": command_version([args.zig_exe, "version"]),
        "rustc": tool_major_version(command_version(["rustc", "--version"])),
        "cargo": tool_major_version(command_version(["cargo", "--version"])),
        "solc": solc_version(),
        "lane": "portable-release",
    }


def command_version(argv: list[str]) -> str:
    try:
        result = subprocess.run(argv, text=True, capture_output=True, check=False)
    except FileNotFoundError:
        return "not found"
    output = (result.stdout or result.stderr).strip()
    return output or f"exit {result.returncode}"


def solc_version() -> str:
    output = command_version(["solc", "--version"])
    for line in output.splitlines():
        if line.startswith("Version:"):
            version = line.removeprefix("Version:").strip().split("+", 1)[0]
            return f"solc {version}"
    return output.splitlines()[0] if output else "not found"


def tool_major_version(output: str) -> str:
    match = re.match(r"^([A-Za-z0-9_.-]+)\s+([0-9][^\s)]*)", output.strip())
    if match:
        return f"{match.group(1)} {match.group(2)}"
    return output


def run_vm_loop(args: argparse.Namespace, raw_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for fixture in VM_LOOP_FIXTURES:
        name = Path(fixture).name
        for engine in VM_LOOP_ENGINES:
            stdout, stderr = run_vm_loop_engine(args, raw_dir, fixture, name, engine)
            times = [float(line.strip()) for line in stdout.splitlines() if line.strip()]
            summary = parse_key_values(first_line(stderr))
            timed_counters = parse_prefixed_key_values(stderr, "timed.")
            logs = int_value(summary.get("logs"))
            if logs is None:
                logs = int_value(timed_counters.get("log"))
            rows.append(
                {
                    "fixture": name,
                    "engine": summary.get("engine", engine_name(engine)),
                    "scope": summary.get("scope") or vm_loop_scope(engine),
                    "host_profile": summary.get("host_profile", ""),
                    "spec": summary.get("spec", ""),
                    "runs": len(times),
                    "runtime_bytes": int_value(summary.get("runtime_bytes")),
                    "deploy_host_calls": int_value(summary.get("deploy_host_calls")),
                    "timed_host_calls": int_value(summary.get("timed_host_calls")),
                    "logs": logs,
                    "median_ms": median(times),
                    "min_ms": min(times) if times else None,
                    "max_ms": max(times) if times else None,
                }
            )
    write_csv(
        raw_dir.parent / "vm_loop_summary.csv",
        rows,
        (
            "fixture",
            "engine",
            "scope",
            "host_profile",
            "spec",
            "runs",
            "runtime_bytes",
            "deploy_host_calls",
            "timed_host_calls",
            "logs",
            "median_ms",
            "min_ms",
            "max_ms",
        ),
    )
    return rows


def run_vm_loop_engine(
    args: argparse.Namespace,
    raw_dir: Path,
    fixture: str,
    fixture_name: str,
    engine: str,
) -> tuple[str, str]:
    if engine == "revm":
        return run_command(
            f"vm-loop-{fixture_name}-revm",
            [
                args.zig_exe,
                "build",
                "revm-vm-loop",
                "--",
                "--fixture",
                fixture,
                "--summary",
            ],
            BENCH_DIR,
            raw_dir,
        )

    if engine.startswith("evmone"):
        evmone_args = [
            args.zig_exe,
            "build",
            f"-Doptimize={args.optimize}",
            "evmone-vm-loop",
            "--",
            "--fixture",
            fixture,
            "--summary",
        ]
        if engine == "evmone-baseline":
            evmone_args.extend(["--mode", "baseline"])
        return run_command(
            f"vm-loop-{fixture_name}-{engine_name(engine)}",
            evmone_args,
            BENCH_DIR,
            raw_dir,
        )

    return run_command(
        f"vm-loop-{fixture_name}-{engine_name(engine)}",
        [
            args.zig_exe,
            "build",
            f"-Doptimize={args.optimize}",
            "vm-loop",
            "--",
            "--engine",
            engine,
            "--fixture",
            fixture,
            "--summary",
        ],
        BENCH_DIR,
        raw_dir,
    )


def engine_name(engine: str) -> str:
    return "evmone-advanced" if engine == "evmone" else engine


def vm_loop_scope(engine: str) -> str:
    if engine == VM_LOOP_BASELINE_ENGINE:
        return "interpreter-prepared-execute"
    if engine == "evmone":
        return "advanced-analyzed-execute"
    if engine == "evmone-baseline":
        return "baseline-analyzed-execute"
    if engine == "revm":
        return "raw-interpreter"
    return ""


def run_host_matrix(args: argparse.Namespace, raw_dir: Path, out_dir: Path) -> list[dict[str, Any]]:
    stdout, _ = run_command(
        "host-matrix",
        [
            args.zig_exe,
            "build",
            f"-Doptimize={args.optimize}",
            "host-matrix",
            "--",
            "--iterations",
            str(args.host_iterations),
            "--repeats",
            str(args.repeats),
            "--warmups",
            str(args.warmups),
            "--include-bytecode",
        ],
        BENCH_DIR,
        raw_dir,
    )
    path = out_dir / "host_matrix_summary.csv"
    path.write_text(stdout)
    return read_csv_rows(path)


def run_kernel(args: argparse.Namespace, raw_dir: Path, out_dir: Path) -> list[dict[str, Any]]:
    zig_stdout, _ = run_command(
        "kernel-zig",
        [
            args.zig_exe,
            "build",
            f"-Doptimize={args.optimize}",
            "kernel",
            "--",
            "--engine",
            "evmz",
            "--engine",
            "evmone-baseline",
            "--engine",
            "evmone",
            "--tier",
            "all",
            "--iterations",
            str(args.kernel_iterations),
            "--repeats",
            str(args.repeats),
            "--warmups",
            str(args.warmups),
        ],
        BENCH_DIR,
        raw_dir,
    )
    revm_stdout, _ = run_command(
        "kernel-revm",
        [
            args.zig_exe,
            "build",
            "revm-kernel",
            "--",
            "--tier",
            "all",
            "--iterations",
            str(args.kernel_iterations),
            "--repeats",
            str(args.repeats),
            "--warmups",
            str(args.warmups),
        ],
        BENCH_DIR,
        raw_dir,
    )
    path = out_dir / "kernel_summary.csv"
    path.write_text(combine_csv_text((zig_stdout, revm_stdout)))
    return read_csv_rows(path)


def run_eest(args: argparse.Namespace, raw_dir: Path, out_dir: Path, eest_root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if args.skip_eest:
        write_csv(out_dir / "eest_summary.csv", rows, eest_columns())
        return rows
    if not eest_root.exists():
        print(f"[bench-report] skip EEST: missing {eest_root}", file=sys.stderr)
        write_csv(out_dir / "eest_summary.csv", rows, eest_columns())
        return rows

    for case in EEST_CASES:
        path = eest_root / case["path"]
        for engine in EEST_ENGINES:
            argv = [
                args.zig_exe,
                "build",
                f"-Dbench-optimize={args.optimize}",
                "bench",
                "--",
                "--engine",
                engine,
                "--iterations",
                str(args.eest_iterations),
                "--warmups",
                str(args.eest_warmups),
                "--max-tests",
                "1",
            ]
            for match in case["matches"]:
                argv.extend(("--match", match))
            argv.append(os.path.relpath(path, EEST_DIR))
            stdout, stderr = run_command(f"eest-{case['name']}-{engine}", argv, EEST_DIR, raw_dir)
            rows.extend(parse_eest_rows(case["name"], stdout + "\n" + stderr))

    write_csv(out_dir / "eest_summary.csv", rows, eest_columns())
    return rows


def run_command(name: str, argv: list[str], cwd: Path, raw_dir: Path) -> tuple[str, str]:
    print(f"[bench-report] {name}", file=sys.stderr)
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False)
    (raw_dir / f"{name}.cmd").write_text(" ".join(shell_quote(arg) for arg in argv) + "\n")
    (raw_dir / f"{name}.stdout").write_text(result.stdout)
    (raw_dir / f"{name}.stderr").write_text(result.stderr)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.stderr.write(result.stdout)
        raise SystemExit(f"{name} failed with exit code {result.returncode}")
    return result.stdout, result.stderr


def shell_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=+-]+", value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def parse_eest_rows(case_name: str, text: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if ": engine=" not in line or ".json::" not in line:
            continue
        left, rest = line.split(": engine=", 1)
        json_sep = ".json::"
        idx = left.find(json_sep)
        if idx < 0:
            continue
        fixture = left[: idx + len(".json")]
        test = left[idx + len(json_sep) :]
        fields = parse_key_values("engine=" + rest)
        rows.append(
            {
                "case": case_name,
                "engine": fields.get("engine", ""),
                "fixture": fixture,
                "test": test,
                "txs": int_value(fields.get("txs")),
                "gas_used": int_value(fields.get("gas_used")),
                "iterations": int_value(fields.get("iterations")),
                "elapsed_ns": int_value(fields.get("elapsed_ns")),
                "mgas_per_s": float_value(fields.get("mgas_per_s")),
                "vm_elapsed_ns": int_value(fields.get("vm_elapsed_ns")),
                "vm_mgas_per_s": float_value(fields.get("vm_mgas_per_s")),
                "opcode_count": int_value(fields.get("opcode_count")),
            }
        )
    return rows


def parse_key_values(line: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in line.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value
    return fields


def parse_prefixed_key_values(text: str, prefix: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith(prefix):
            fields.update(parse_key_values(line[len(prefix) :]))
    return fields


def first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def read_csv_rows(path: Path) -> list[dict[str, Any]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]], columns: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(columns))
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def combine_csv_text(parts: Iterable[str]) -> str:
    header: str | None = None
    lines: list[str] = []
    for text in parts:
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            if header is None:
                header = line
                lines.append(line)
                continue
            if line == header:
                continue
            lines.append(line)
    return "\n".join(lines).rstrip() + "\n"


def eest_columns() -> tuple[str, ...]:
    return (
        "case",
        "engine",
        "fixture",
        "test",
        "txs",
        "gas_used",
        "iterations",
        "elapsed_ns",
        "mgas_per_s",
        "vm_elapsed_ns",
        "vm_mgas_per_s",
        "opcode_count",
    )


def build_checkpoint(
    env: dict[str, Any],
    args: argparse.Namespace,
    vm_loop_rows: list[dict[str, Any]],
    host_rows: list[dict[str, Any]],
    kernel_rows: list[dict[str, Any]],
    eest_rows: list[dict[str, Any]],
) -> dict[str, Any]:
    kernel = grouped_medians(kernel_rows, ("engine", "case"), "ns_per_iter")
    host = grouped_medians(host_rows, ("op", "boundary"), "ns_per_op")
    eest = grouped_medians(eest_rows, ("engine", "case"), "vm_mgas_per_s")
    return {
        "schema": 1,
        "environment": env,
        "parameters": {
            "optimize": args.optimize,
            "kernel_iterations": args.kernel_iterations,
            "host_iterations": args.host_iterations,
            "repeats": args.repeats,
            "warmups": args.warmups,
            "eest_iterations": args.eest_iterations,
            "eest_warmups": args.eest_warmups,
        },
        "evmz": {
            "vm_loop_engine": VM_LOOP_BASELINE_ENGINE,
            "vm_loop_median_ms": {
                row["fixture"]: row["median_ms"]
                for row in vm_loop_rows
                if row.get("engine") == VM_LOOP_BASELINE_ENGINE and row.get("median_ms") is not None
            },
            "kernel_ns_per_iter": flatten_engine_map(kernel, "evmz"),
            "host_bytecode_ns_per_op": {
                op: value
                for (op, boundary), value in host.items()
                if boundary == "evmz-interpreter-zig-host" and op.startswith("bytecode_")
            },
            "eest_vm_mgas_per_s": flatten_engine_map(eest, "evmz"),
        },
    }


def flatten_engine_map(grouped: dict[tuple[str, ...], float], engine: str) -> dict[str, float]:
    values: dict[str, float] = {}
    for key, value in grouped.items():
        if len(key) != 2:
            continue
        key_engine, name = key
        if key_engine == engine:
            values[name] = value
    return dict(sorted(values.items()))


def grouped_medians(rows: list[dict[str, Any]], keys: tuple[str, ...], value_key: str) -> dict[tuple[str, ...], float]:
    groups: dict[tuple[str, ...], list[float]] = {}
    for row in rows:
        value = float_value(row.get(value_key))
        if value is None:
            continue
        key = tuple(str(row.get(part, "")) for part in keys)
        groups.setdefault(key, []).append(value)
    return {key: median(values) for key, values in groups.items()}


def render_report(
    env: dict[str, Any],
    args: argparse.Namespace,
    vm_loop_rows: list[dict[str, Any]],
    host_rows: list[dict[str, Any]],
    kernel_rows: list[dict[str, Any]],
    eest_rows: list[dict[str, Any]],
    checkpoint_path: Path,
    baseline_path: Path | None,
    checkpoint: dict[str, Any],
    baseline: dict[str, Any] | None,
) -> str:
    lines: list[str] = []
    lines.append("# evm.zig Benchmark Report")
    lines.append("")
    lines.append(f"- generated_at: `{env['generated_at']}`")
    lines.append(f"- lane: `{env['lane']}`")
    lines.append(f"- platform: `{env['platform']}`")
    lines.append(f"- zig: `{env['zig']}`")
    lines.append(f"- rustc: `{env['rustc']}`")
    lines.append(f"- cargo: `{env['cargo']}`")
    lines.append(f"- solc: `{env['solc']}`")
    lines.append(f"- checkpoint: `{display_path(checkpoint_path)}`")
    if baseline_path:
        lines.append(f"- baseline: `{display_path(baseline_path)}`")
    lines.append("")
    lines.append(
        "Portable release means Zig `ReleaseFast` for Zig/C++ runners and revm `cargo --release`. "
        "No native CPU flags are enabled by this reporter."
    )
    lines.append("")

    lines.extend(render_vm_loop(vm_loop_rows))
    lines.extend(render_host(host_rows))
    lines.extend(render_kernel(kernel_rows))
    lines.extend(render_eest(eest_rows))
    lines.extend(render_checkpoint_delta(checkpoint, baseline))

    return "\n".join(lines) + "\n"


def render_vm_loop(rows: list[dict[str, Any]]) -> list[str]:
    by_fixture_engine = {
        (str(row.get("fixture", "")), str(row.get("engine", ""))): float_value(row.get("median_ms"))
        for row in rows
    }
    table = [["fixture", "engine", "scope", "host", "runs", "runtime bytes", "host calls", "logs", "median ms", f"{VM_LOOP_BASELINE_ENGINE}/engine"]]
    for row in rows:
        evmz_ms = by_fixture_engine.get((str(row["fixture"]), VM_LOOP_BASELINE_ENGINE))
        row_ms = float_value(row.get("median_ms"))
        table.append(
            [
                row["fixture"],
                row["engine"],
                row.get("scope", ""),
                row["host_profile"],
                str(row["runs"]),
                fmt_int(row["runtime_bytes"]),
                fmt_int(row["timed_host_calls"]),
                fmt_int(row.get("logs")),
                fmt_float(row["median_ms"], 3),
                fmt_ratio(evmz_ms / row_ms if evmz_ms and row_ms else None),
            ]
        )
    return [
        "## VM-loop comparison",
        "",
        "VM-core comparison over the same deployed-runtime fixture protocol. Deploy/runtime setup is outside the timed call. evmz times direct `Interpreter.execute` with prepared metadata, evmone baseline/advanced use analyzed-code execution from the standalone C++ runner, and revm times its low-level interpreter loop with analyzed `Bytecode`. The executor/transaction lane is intentionally left out of this default report until it has matching revm/evmone transaction-level adapters.",
        "",
        *markdown_table(table),
        "",
    ]


def render_host(rows: list[dict[str, Any]]) -> list[str]:
    medians = grouped_medians(rows, ("op", "boundary"), "ns_per_op")
    selected = (
        ("host_call", "zig-host-vtable"),
        ("host_call", "evmc-host-to-zig"),
        ("host_storage_read", "zig-host-vtable"),
        ("host_storage_read", "evmc-host-to-zig"),
        ("host_storage_write", "zig-host-vtable"),
        ("host_storage_write", "evmc-host-to-zig"),
        ("host_log", "zig-host-vtable"),
        ("host_log", "evmc-host-to-zig"),
        ("bytecode_sload", "evmz-interpreter-zig-host"),
        ("bytecode_sstore", "evmz-interpreter-zig-host"),
    )
    table = [["op", "boundary", "median ns/op", "evmc/zig"]]
    for op, boundary in selected:
        value = medians.get((op, boundary))
        ratio = None
        if boundary == "evmc-host-to-zig":
            zig = medians.get((op, "zig-host-vtable"))
            if zig is not None and value is not None and zig != 0:
                ratio = value / zig
        table.append([op, boundary, fmt_float(value, 2), fmt_ratio(ratio)])
    return ["## Host-boundary checkpoint", "", *markdown_table(table), ""]


def render_kernel(rows: list[dict[str, Any]]) -> list[str]:
    medians = grouped_medians(rows, ("engine", "case"), "ns_per_iter")
    cases = sorted({case for _, case in medians.keys()})
    ranked: list[tuple[float, str]] = []
    for case in cases:
        evmz = medians.get(("evmz", case))
        candidates = [
            medians.get(("evmone-baseline", case)),
            medians.get(("evmone-advanced", case)),
            medians.get(("revm", case)),
        ]
        best_other = min((value for value in candidates if value), default=None)
        if evmz and best_other:
            ranked.append((evmz / best_other, case))
    ranked.sort(reverse=True)

    table = [["case", "evmz", "evmone base", "evmone adv", "revm", "evmz/best"]]
    for ratio, case in ranked[:14]:
        table.append(
            [
                case,
                fmt_float(medians.get(("evmz", case)), 2),
                fmt_float(medians.get(("evmone-baseline", case)), 2),
                fmt_float(medians.get(("evmone-advanced", case)), 2),
                fmt_float(medians.get(("revm", case)), 2),
                fmt_ratio(ratio),
            ]
        )
    return [
        "## Opcode kernel comparison",
        "",
        "Median ns/iteration. Zig and evmone kernel rows are direct execution paths; the revm kernel sidecar currently uses its transaction API, so treat that row as a diagnostic baseline rather than a perfectly identical interpreter-only kernel.",
        "",
        *markdown_table(table),
        "",
    ]


def render_eest(rows: list[dict[str, Any]]) -> list[str]:
    if not rows:
        return ["## EEST integration slice", "", "Skipped: benchmark fixtures not found or `--skip-eest` was set.", ""]
    medians = grouped_medians(rows, ("engine", "case"), "vm_mgas_per_s")
    cases = sorted({case for _, case in medians.keys()})
    table = [["case", "evmz VM MGas/s", "evmone base", "evmone adv", "base/evmz", "adv/evmz"]]
    for case in cases:
        evmz = medians.get(("evmz", case))
        base = medians.get(("evmone-baseline", case))
        adv = medians.get(("evmone-advanced", case))
        table.append(
            [
                case,
                fmt_float(evmz, 1),
                fmt_float(base, 1),
                fmt_float(adv, 1),
                fmt_ratio(base / evmz if base and evmz else None),
                fmt_ratio(adv / evmz if adv and evmz else None),
            ]
        )
    return [
        "## EEST integration slice",
        "",
        "VM MGas/s uses the EEST runner's VM-timed scope. This slice is representative, not a full corpus run.",
        "",
        *markdown_table(table),
        "",
    ]


def render_checkpoint_delta(checkpoint: dict[str, Any], baseline: dict[str, Any] | None) -> list[str]:
    if not baseline:
        return ["## Evmz checkpoint delta", "", "No baseline supplied. Pass `--baseline <checkpoint.json>` after an optimization branch.", ""]

    rows: list[list[str]] = [["metric", "case", "baseline", "current", "delta"]]
    for section, direction in (
        ("kernel_ns_per_iter", "lower"),
        ("eest_vm_mgas_per_s", "higher"),
        ("vm_loop_median_ms", "lower"),
    ):
        current_map = checkpoint.get("evmz", {}).get(section, {})
        baseline_map = baseline.get("evmz", {}).get(section, {})
        for name in sorted(set(current_map) & set(baseline_map)):
            current = float_value(current_map.get(name))
            old = float_value(baseline_map.get(name))
            if current is None or old is None or old == 0:
                continue
            if direction == "lower":
                delta = (old - current) / old
            else:
                delta = (current - old) / old
            rows.append([section, name, fmt_float(old, 2), fmt_float(current, 2), fmt_percent(delta)])

    return ["## Evmz checkpoint delta", "", *markdown_table(rows[:24]), ""]


def markdown_table(rows: list[list[str]]) -> list[str]:
    if not rows:
        return []
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(rows[0]))]
    rendered = []
    for index, row in enumerate(rows):
        rendered.append("| " + " | ".join(str(value).ljust(widths[i]) for i, value in enumerate(row)) + " |")
        if index == 0:
            rendered.append("| " + " | ".join("-" * widths[i] for i in range(len(widths))) + " |")
    return rendered


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def median(values: Iterable[float]) -> float:
    return float(statistics.median(list(values)))


def int_value(value: Any) -> int | None:
    if value is None or value == "" or value == "unknown":
        return None
    return int(value)


def float_value(value: Any) -> float | None:
    if value is None or value == "" or value == "unknown":
        return None
    return float(value)


def fmt_int(value: Any) -> str:
    parsed = int_value(value)
    return "-" if parsed is None else f"{parsed}"


def fmt_float(value: Any, digits: int) -> str:
    parsed = float_value(value)
    return "-" if parsed is None else f"{parsed:.{digits}f}"


def fmt_ratio(value: Any) -> str:
    parsed = float_value(value)
    return "-" if parsed is None else f"{parsed:.2f}x"


def fmt_percent(value: float) -> str:
    sign = "+" if value >= 0 else ""
    return f"{sign}{value * 100:.1f}%"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


if __name__ == "__main__":
    raise SystemExit(main())
