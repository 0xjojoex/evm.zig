"""Register evmz t8n with execution-specs fill."""

import json
import re
import shutil
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import ClassVar

from execution_testing.client_clis.transition_tool import Profiler, TransitionTool
from execution_testing.client_clis.cli_types import LazyAllocFile, TransitionToolOutput
from execution_testing.exceptions import (
    BlockException,
    ExceptionBase,
    ExceptionMapper,
    TransactionException,
)
from execution_testing.forks import Fork


class EvmzExceptionMapper(ExceptionMapper):
    """Map evmz's canonical transaction exception names."""

    mapping_substring: ClassVar[dict[ExceptionBase, str]] = {}
    mapping_regex: ClassVar[dict[ExceptionBase, str]] = {
        exception: rf"^{re.escape(str(exception))}$"
        for exception in (*TransactionException, *BlockException)
    }


class EvmzTransitionTool(TransitionTool):
    """Filesystem transition-tool adapter for evmz t8n."""

    default_binary = Path("evmz")
    detect_binary_pattern = re.compile(r"^evmz\s")
    version_flag = "--version"
    subcommand = "t8n"

    supported_forks: ClassVar[set[str]] = {
        "Merge",
        "Paris",
        "Shanghai",
        "Cancun",
        "Prague",
        "Osaka",
        "Amsterdam",
    }

    def __init__(
        self,
        *,
        binary: Path | None = None,
        trace: bool = False,
    ) -> None:
        """Initialize the evmz transition tool."""
        super().__init__(
            exception_mapper=EvmzExceptionMapper(),
            binary=binary,
            trace=trace,
        )

    def is_fork_supported(self, fork: Fork) -> bool:
        """Return whether evmz implements this exact transition-tool fork."""
        return fork.transition_tool_name() in self.supported_forks

    def _evaluate_filesystem(
        self,
        *,
        t8n_data: TransitionTool.TransitionToolData,
        debug_output_path: Path | None,
        profiler: Profiler,
    ) -> TransitionToolOutput:
        """Pass the subcommand and state-test mode as distinct argv entries."""
        temp_dir = tempfile.TemporaryDirectory()
        directory = Path(temp_dir.name)
        (directory / "input").mkdir()
        (directory / "output").mkdir()
        inputs = t8n_data.to_input().to_files(
            directory / "input", by_alias=True, exclude_none=True
        )
        args = [str(self.binary), "t8n"]
        for name in ("alloc", "env", "txs"):
            args.extend([f"--input.{name}", str(inputs[name])])
        args.extend([
            "--state.fork", self.fork_name_map.get(t8n_data.fork_name, t8n_data.fork_name),
            "--state.chainid", str(t8n_data.chain_id),
            "--state.reward", str(t8n_data.reward),
            "--output.basedir", str(directory),
            "--output.alloc", "output/alloc.json",
            "--output.result", "output/result.json",
            "--output.body", "output/txs.rlp",
        ])
        if t8n_data.state_test:
            args.append("--state-test")
        if self.trace:
            args.append("--trace")
        result = subprocess.run(args, capture_output=True)
        if debug_output_path:
            with profiler.pause():
                if debug_output_path.exists():
                    shutil.rmtree(debug_output_path)
                shutil.copytree(directory, debug_output_path)
                replay_args = [arg.replace(str(directory), str(debug_output_path)) for arg in args]
                (debug_output_path / "args.py").write_text(json.dumps(replay_args, indent=2))
                (debug_output_path / "t8n.sh").write_text("#!/bin/sh\n" + shlex.join(replay_args) + "\n")
                (debug_output_path / "returncode.txt").write_text(str(result.returncode))
                (debug_output_path / "stdout.txt").write_bytes(result.stdout)
                (debug_output_path / "stderr.txt").write_bytes(result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f"evmz t8n failed: {result.stderr.decode()}")
        output = TransitionToolOutput.model_validate_files(
            directory / "output", context={"exception_mapper": self.exception_mapper}
        )
        if isinstance(output.alloc, LazyAllocFile):
            output.alloc._keepalive = temp_dir
        return output
