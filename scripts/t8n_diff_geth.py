#!/usr/bin/env python3
"""Sweep EEST-generated transitions through evmz and Geth locally."""

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = REPO_ROOT / "eest" / "consume" / "pyproject.toml"


@dataclass(frozen=True)
class Partition:
    name: str
    fork: str
    path: str


PARTITIONS = (
    Partition("paris", "Paris", "tests/paris"),
    Partition("shanghai", "Shanghai", "tests/shanghai"),
    Partition("cancun", "Cancun", "tests/cancun"),
    Partition("prague", "Prague", "tests/prague"),
    Partition("osaka", "Osaka", "tests/osaka"),
    Partition("amsterdam", "Amsterdam", "tests/amsterdam"),
)


class PreflightError(Exception):
    """The sweep cannot start reproducibly."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run EEST source transitions through evmz-t8n and Geth, "
            "using EELS to classify disagreements and stopping at the first "
            "evmz-relevant mismatch in each fork."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  scripts/t8n_diff_geth.py --eest-source /path/to/execution-specs --geth-bin /path/to/evm
  scripts/t8n_diff_geth.py --eest-source /path/to/execution-specs --geth-bin /path/to/evm --fork cancun
  scripts/t8n_diff_geth.py --eest-source /path/to/execution-specs --geth-bin /path/to/evm --node-id 'tests/...::test_name[...]'
""",
    )
    parser.add_argument(
        "--eest-source",
        required=True,
        type=Path,
        help="execution-specs checkout at the revision pinned by eest/consume",
    )
    parser.add_argument(
        "--geth-bin",
        required=True,
        type=Path,
        help="Geth evm binary providing the t8n command",
    )
    parser.add_argument(
        "--fork",
        action="append",
        choices=[partition.name for partition in PARTITIONS],
        help="fork partition to run; repeatable, defaults to all",
    )
    parser.add_argument(
        "--node-id",
        help="run one exact EEST pytest node ID instead of fork partitions",
    )
    parser.add_argument(
        "--jobs",
        type=non_negative_int,
        default=min(os.cpu_count() or 1, 8),
        help="pytest-xdist workers; 0 runs serially (default: up to 8)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / ".zig-cache" / "eest-diff" / "sweeps",
        help="parent directory for versioned sweep results",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="continue to later forks after one partition finds an evmz mismatch",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate inputs and print commands without executing transitions",
    )
    args = parser.parse_args()
    if args.node_id and args.fork:
        parser.error("--node-id cannot be combined with --fork")
    return args


def non_negative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def command_output(argv: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        argv,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise PreflightError(
            f"command failed ({result.returncode}): {shlex.join(argv)}\n{result.stdout}"
        )
    return result.stdout.strip()


def pinned_execution_specs_revision() -> str:
    revisions = set(re.findall(r'rev = "([0-9a-f]{40})"', PYPROJECT.read_text()))
    if len(revisions) != 1:
        raise PreflightError(f"expected one execution-specs revision in {PYPROJECT}")
    return revisions.pop()


def preflight(args: argparse.Namespace) -> dict[str, object]:
    if shutil.which("zig") is None:
        raise PreflightError("zig is not available in PATH")
    if shutil.which("uv") is None:
        raise PreflightError("uv is not available in PATH")

    eest_source = args.eest_source.resolve()
    geth_bin = args.geth_bin.resolve()
    if not (eest_source / "tests").is_dir():
        raise PreflightError(
            f"execution-specs tests directory is missing: {eest_source}"
        )
    if not geth_bin.is_file() or not os.access(geth_bin, os.X_OK):
        raise PreflightError(f"Geth evm binary is not executable: {geth_bin}")

    expected_revision = pinned_execution_specs_revision()
    actual_revision = command_output(
        ["git", "rev-parse", "HEAD"],
        cwd=eest_source,
    )
    if actual_revision != expected_revision:
        raise PreflightError(
            "execution-specs checkout does not match the Python dependency pin: "
            f"expected {expected_revision}, got {actual_revision}"
        )

    geth_version = command_output([str(geth_bin), "--version"])
    command_output([str(geth_bin), "t8n", "--help"])
    repository_revision = command_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT)
    repository_dirty = bool(command_output(["git", "status", "--short"], cwd=REPO_ROOT))
    return {
        "execution_specs_source": str(eest_source),
        "execution_specs_revision": actual_revision,
        "geth_binary": str(geth_bin),
        "geth_version": geth_version,
        "repository_revision": repository_revision,
        "repository_dirty": repository_dirty,
    }


def selected_partitions(args: argparse.Namespace) -> list[Partition]:
    if args.node_id:
        fork = next(
            (
                partition.fork
                for partition in PARTITIONS
                if args.node_id.startswith(f"{partition.path}/")
            ),
            "",
        )
        return [Partition("replay", fork, args.node_id)]
    selected = set(args.fork or ())
    return [
        partition
        for partition in PARTITIONS
        if not selected or partition.name in selected
    ]


def sweep_command(
    args: argparse.Namespace,
    metadata: dict[str, object],
    partition: Partition,
    mismatch_dir: Path,
) -> list[str]:
    command = [
        "zig",
        "build",
        "t8n-diff",
        f"-Deest-source={metadata['execution_specs_source']}",
        f"-Dt8n-reference-bin={metadata['geth_binary']}",
        f"-Dt8n-diff-output={mismatch_dir}",
        "--",
        "--evmz-diff-arbitrate",
    ]
    if partition.fork:
        command.extend(["--fork", partition.fork, partition.path])
    else:
        command.append(partition.path)
    command.extend(["-n", str(args.jobs)])
    return command


def run_streamed(command: list[str], log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            log.write(line)
        return process.wait()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(args: argparse.Namespace) -> int:
    metadata = preflight(args)
    partitions = selected_partitions(args)
    started = datetime.now(UTC)
    run_id = started.strftime("%Y%m%dT%H%M%S.%fZ") + "-geth"
    run_dir = args.output.resolve() / run_id
    manifest = {
        **metadata,
        "started_at": started.isoformat(),
        "jobs": args.jobs,
        "fail_fast": not args.keep_going,
        "partitions": [asdict(partition) for partition in partitions],
    }

    commands = [
        sweep_command(
            args,
            metadata,
            partition,
            run_dir / "mismatches" / partition.name,
        )
        for partition in partitions
    ]
    if args.dry_run:
        print(json.dumps(manifest, indent=2, sort_keys=True))
        for command in commands:
            print(shlex.join(command))
        return 0

    write_json(run_dir / "manifest.json", manifest)
    print(f"sweep: {run_dir}")
    print(f"geth: {metadata['geth_version']}")
    print(f"execution-specs: {metadata['execution_specs_revision']}")

    results: list[dict[str, object]] = []
    mismatch_found = False
    reference_divergence_found = False
    infrastructure_failed = False
    for partition, command in zip(partitions, commands, strict=True):
        print(f"partition: {partition.name}")
        print("command: " + shlex.join(command))
        log_path = run_dir / "logs" / f"{partition.name}.log"
        mismatch_dir = run_dir / "mismatches" / partition.name
        began = time.monotonic()
        returncode = run_streamed(command, log_path)
        duration = round(time.monotonic() - began, 3)
        artifacts: list[tuple[str, str]] = []
        for context_path in mismatch_dir.rglob("context.json"):
            context = json.loads(context_path.read_text())
            artifacts.append(
                (
                    str(context_path.parent),
                    context.get("classification", "unclassified_divergence"),
                )
            )
        artifacts.sort()
        reference_divergences = [
            path
            for path, classification in artifacts
            if classification == "reference_divergence"
        ]
        mismatches = [
            path
            for path, classification in artifacts
            if classification != "reference_divergence"
        ]
        reference_divergence_found |= bool(reference_divergences)
        if returncode == 0 and not mismatches:
            status = "passed"
        elif mismatches:
            status = "mismatch"
            mismatch_found = True
        else:
            status = "error"
            infrastructure_failed = True
        result = {
            "partition": partition.name,
            "status": status,
            "returncode": returncode,
            "duration_seconds": duration,
            "log": str(log_path),
            "mismatches": mismatches,
            "reference_divergences": reference_divergences,
        }
        results.append(result)
        write_json(run_dir / "results.json", results)
        print(f"result: {partition.name} {status} ({duration:.1f}s)")
        for mismatch in mismatches:
            print(f"mismatch: {mismatch}")
        if reference_divergences:
            print(f"reference divergences: {len(reference_divergences)}")
            for divergence in reference_divergences[:3]:
                print(f"reference divergence: {divergence}")
            if len(reference_divergences) > 3:
                print(
                    "reference divergence: "
                    f"... {len(reference_divergences) - 3} more in {mismatch_dir}"
                )
        if returncode != 0 and not args.keep_going:
            break

    manifest["finished_at"] = datetime.now(UTC).isoformat()
    manifest["status"] = (
        "error"
        if infrastructure_failed
        else "mismatch"
        if mismatch_found
        else "passed_with_reference_divergences"
        if reference_divergence_found
        else "passed"
    )
    write_json(run_dir / "manifest.json", manifest)
    print(f"summary: {run_dir / 'results.json'}")
    if infrastructure_failed:
        return 2
    if mismatch_found:
        return 1
    return 0


def main() -> int:
    args = parse_args()
    try:
        return run(args)
    except PreflightError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
