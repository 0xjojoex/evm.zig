"""Shared subprocess boundary for evmz consume-direct adapters."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest
from execution_testing.client_clis.transition_tool import (
    dump_files_to_directory,
)

CachedRun = tuple[list[str], int, str, str, list[object]]


def consume_fixture(
    *,
    binary: Path,
    subcommand: str,
    fixture_path: Path,
    fixture_name: str | None,
    debug_output_path: Path | None,
    cache: dict[tuple[str, Path], CachedRun],
) -> None:
    """Run evmz once per fixture file and report one indexed fixture result."""
    key = (subcommand, fixture_path)
    if key not in cache:
        command = [str(binary), subcommand, str(fixture_path)]
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode == 0:
            try:
                parsed = json.loads(completed.stdout)
            except json.JSONDecodeError as error:
                raise RuntimeError(
                    f"invalid evmz {subcommand} JSON: {completed.stdout}"
                ) from error
            if not isinstance(parsed, list):
                raise RuntimeError(f"invalid evmz {subcommand} result: {parsed!r}")
        else:
            parsed = []
        cache[key] = (
            command,
            completed.returncode,
            completed.stdout,
            completed.stderr,
            parsed,
        )

    command, returncode, stdout, stderr, records = cache[key]
    if debug_output_path is not None:
        dump_files_to_directory(
            debug_output_path,
            {
                "consume_direct_args.py": command,
                "consume_direct_returncode.txt": returncode,
                "consume_direct_stdout.txt": stdout,
                "consume_direct_stderr.txt": stderr,
            },
        )
        shutil.copyfile(fixture_path, debug_output_path / "fixtures.json")

    if returncode != 0:
        raise RuntimeError(f"evmz {subcommand} exited {returncode}:\n{stderr}")

    selected = records
    if fixture_name is not None:
        selected = [
            record
            for record in records
            if isinstance(record, dict) and record.get("name") == fixture_name
        ]
        if len(selected) != 1:
            raise RuntimeError(
                f"expected one result for {fixture_name}, got {len(selected)}"
            )

    failures = []
    skips = []
    for record in selected:
        if not isinstance(record, dict):
            raise TypeError(f"invalid evmz {subcommand} record: {record!r}")
        name = record.get("name")
        passed = record.get("pass")
        skipped = record.get("skip", False)
        message = record.get("error")
        if (
            not isinstance(name, str)
            or not isinstance(passed, bool)
            or not isinstance(skipped, bool)
            or not isinstance(message, str)
            or (passed and skipped)
        ):
            raise RuntimeError(f"invalid evmz {subcommand} record: {record!r}")
        if skipped:
            skips.append(f"{name}: {message}")
        elif not passed:
            failures.append(f"{name}: {message}")

    if failures:
        raise RuntimeError(f"evmz {subcommand} failed:\n" + "\n".join(failures))
    if skips and len(skips) == len(selected):
        pytest.skip(f"evmz {subcommand}: fixture has no inputs for this adapter")
