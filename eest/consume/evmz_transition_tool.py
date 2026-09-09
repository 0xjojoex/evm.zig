"""Register evmz-t8n with execution-specs fill."""

import re
from pathlib import Path
from typing import ClassVar

from execution_testing.client_clis.transition_tool import Profiler, TransitionTool
from execution_testing.client_clis.cli_types import TransitionToolOutput
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
    """Filesystem transition-tool adapter for evmz-t8n."""

    default_binary = Path("evmz-t8n")
    detect_binary_pattern = re.compile(r"^evmz-t8n\b")
    version_flag = "--version"

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
        """Preserve EEST's state-test mode at the evmz process boundary."""
        if not t8n_data.state_test:
            return super()._evaluate_filesystem(
                t8n_data=t8n_data,
                debug_output_path=debug_output_path,
                profiler=profiler,
            )

        assert self.subcommand is None
        self.subcommand = "--state-test"
        try:
            return super()._evaluate_filesystem(
                t8n_data=t8n_data,
                debug_output_path=debug_output_path,
                profiler=profiler,
            )
        finally:
            self.subcommand = None
