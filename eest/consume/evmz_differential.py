"""Differentially evaluate EEST-generated transitions with evmz."""

import difflib
import hashlib
import io
import json
import re
from contextlib import redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

import pytest

from execution_testing.client_clis import TransitionTool
from execution_testing.client_clis.cli_types import TransitionToolOutput
from execution_testing.client_clis.transition_tool import Profiler
from execution_testing.exceptions import ExceptionWithMessage
from execution_testing.forks import Fork


def pytest_addoption(parser: pytest.Parser) -> None:
    """Add local differential-run options."""
    group = parser.getgroup("evmz differential")
    group.addoption(
        "--evmz-diff-reference",
        type=Path,
        default=None,
        help="Reference t8n binary; defaults to the in-process EELS tool.",
    )
    group.addoption(
        "--evmz-diff-output",
        type=Path,
        required=True,
        help="Directory where the first transition mismatch is preserved.",
    )
    group.addoption(
        "--evmz-diff-arbitrate",
        action="store_true",
        help=(
            "Use the in-process EELS tool to classify disagreements with an "
            "external reference."
        ),
    )


@pytest.hookimpl(trylast=True)
def pytest_sessionstart(session: pytest.Session) -> None:
    """Wrap the configured evmz tool after the EEST filler creates it."""
    config = session.config
    primary: TransitionTool = config.t8n  # type: ignore[attr-defined]
    reference_path: Path | None = config.getoption("evmz_diff_reference")
    arbitrate: bool = config.getoption("evmz_diff_arbitrate")
    arbiter: TransitionTool | None = None
    if reference_path is None:
        if arbitrate:
            raise pytest.UsageError(
                "--evmz-diff-arbitrate requires --evmz-diff-reference"
            )
        assert TransitionTool.default_tool is not None
        reference = TransitionTool.default_tool(trace=False)
    else:
        # Binary detection probes every registered class. The in-process EELS
        # default has no version matcher, and the pinned framework prints that
        # expected probe failure even when a later client matches.
        with redirect_stdout(io.StringIO()):
            reference = TransitionTool.from_binary_path(
                binary_path=reference_path,
                trace=False,
            )
        if arbitrate:
            assert TransitionTool.default_tool is not None
            arbiter = TransitionTool.default_tool(trace=False)
    config.t8n = DifferentialTransitionTool(  # type: ignore[attr-defined]
        primary=primary,
        reference=reference,
        arbiter=arbiter,
        output_root=config.getoption("evmz_diff_output"),
    )


def pytest_runtest_setup(item: pytest.Item) -> None:
    """Give mismatch artifacts the exact upstream pytest identity."""
    tool = item.config.t8n  # type: ignore[attr-defined]
    if isinstance(tool, DifferentialTransitionTool):
        tool.begin_test(item.nodeid)


@dataclass
class Evaluation:
    """One tool's answer to a transition: its output or the exception it raised."""

    name: str
    output: TransitionToolOutput | None = None
    error: Exception | None = None


class DifferentialTransitionTool(TransitionTool):
    """Run one EEST transition through evmz and an independent reference."""

    supports_opcode_count = False
    supports_blob_params = False

    def __init__(
        self,
        *,
        primary: TransitionTool,
        reference: TransitionTool,
        arbiter: TransitionTool | None,
        output_root: Path,
    ) -> None:
        self.primary = primary
        self.reference = reference
        self.arbiter = arbiter
        self.output_root = output_root
        self.exception_mapper = reference.exception_mapper
        self.trace = False
        self._info_metadata: dict[str, Any] = {}
        self.supports_xdist = all(tool.supports_xdist for tool in self.tools.values())
        self.test_id = "session"
        self.test_call = 0

    @property
    def tools(self) -> dict[str, TransitionTool]:
        """Every wrapped implementation, keyed by its role."""
        tools = {"primary": self.primary, "reference": self.reference}
        if self.arbiter is not None:
            tools["arbiter"] = self.arbiter
        return tools

    def begin_test(self, nodeid: str) -> None:
        """Reset the transition identity for a new EEST test parameter."""
        self.test_id = nodeid
        self.test_call = 0

    def version(self) -> str:
        """Report every implementation used by the differential."""
        versions = {name: tool.version().strip() for name, tool in self.tools.items()}
        versions["primary"] = f"evmz differential: {versions['primary']}"
        return " | ".join(f"{name}: {version}" for name, version in versions.items())

    def is_fork_supported(self, fork: Fork) -> bool:
        """Only advertise forks understood by every implementation."""
        return all(tool.is_fork_supported(fork) for tool in self.tools.values())

    def shutdown(self) -> None:
        """Release every transition-tool implementation."""
        for tool in self.tools.values():
            tool.shutdown()

    def _evaluate(
        self,
        *,
        transition_tool_data: TransitionTool.TransitionToolData,
        debug_output_path: Path | None,
        slow_request: bool,
        profiler: Profiler,
    ) -> TransitionToolOutput:
        del debug_output_path, profiler
        call = self.test_call
        self.test_call += 1

        def evaluate(name: str, tool: TransitionTool) -> Evaluation:
            evaluation = Evaluation(name)
            try:
                evaluation.output = tool.evaluate(
                    transition_tool_data=transition_tool_data,
                    slow_request=slow_request,
                )
            except Exception as error:  # noqa: BLE001 - any tool failure is an artifact
                evaluation.error = error
            return evaluation

        def fail(classification: str, evaluations: list[Evaluation], message: str) -> NoReturn:
            artifact = self._dump(transition_tool_data, call, classification, evaluations)
            error = AssertionError(f"{message}; differential preserved at {artifact}")
            cause = next((e.error for e in evaluations if e.error is not None), None)
            if cause is not None:
                raise error from cause
            raise error

        evmz = evaluate("evmz", self.primary)
        if evmz.output is None:
            fail("tool_error", [evmz], "evmz t8n failed")
        reference = evaluate("reference", self.reference)
        if self.arbiter is None:
            if reference.output is None:
                fail("tool_error", [evmz, reference], "reference t8n failed")
            if not outputs_equivalent(evmz.output, reference.output):
                fail("unclassified_divergence", [evmz, reference], "t8n outputs differ")
            return reference.output

        arbiter = evaluate("arbiter", self.arbiter)
        evaluations = [evmz, reference, arbiter]
        if arbiter.output is None:
            classification = (
                "arbiter_error" if reference.output else "reference_and_arbiter_error"
            )
            fail(classification, evaluations, "EELS arbitration failed")
        if outputs_equivalent(evmz.output, arbiter.output):
            if reference.output is None or not outputs_equivalent(
                evmz.output, reference.output
            ):
                self._dump(transition_tool_data, call, "reference_divergence", evaluations)
            return arbiter.output
        if reference.output is None:
            classification = "evmz_divergence_with_reference_error"
        elif outputs_equivalent(reference.output, arbiter.output):
            classification = "evmz_divergence"
        elif outputs_equivalent(evmz.output, reference.output):
            classification = "evmz_and_reference_divergence"
        else:
            classification = "three_way_divergence"
        fail(classification, evaluations, classification.replace("_", " "))

    def _dump(
        self,
        transition_tool_data: TransitionTool.TransitionToolData,
        call: int,
        classification: str,
        evaluations: list[Evaluation],
    ) -> Path:
        digest = hashlib.sha256(self.test_id.encode()).hexdigest()[:12]
        slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", self.test_id).strip("-")
        artifact = self.output_root / f"{slug[:120]}-{digest}" / f"call-{call}"
        input_dir = artifact / "input"
        input_dir.mkdir(parents=True, exist_ok=True)
        transition_tool_data.to_input().to_files(
            input_dir,
            by_alias=True,
            exclude_none=True,
        )
        context = {
            "classification": classification,
            "pytest_node_id": self.test_id,
            "transition_call": call,
            "fork": transition_tool_data.fork_name,
            "chain_id": transition_tool_data.chain_id,
            "reward": transition_tool_data.reward,
        }
        for name, tool in self.tools.items():
            context[f"{name}_version"] = tool.version().strip()
        write_json(artifact / "context.json", context)

        outputs: dict[str, dict[str, Any]] = {}
        for evaluation in evaluations:
            if evaluation.output is not None:
                outputs[evaluation.name] = canonical_output(evaluation.output)
                write_json(artifact / f"{evaluation.name}.json", outputs[evaluation.name])
            if evaluation.error is not None:
                (artifact / f"{evaluation.name}-error.txt").write_text(
                    repr(evaluation.error) + "\n"
                )
        if "evmz" in outputs and "reference" in outputs:
            local = format_json(outputs["evmz"]).splitlines(keepends=True)
            expected = format_json(outputs["reference"]).splitlines(keepends=True)
            (artifact / "diff.txt").write_text(
                "".join(
                    difflib.unified_diff(
                        expected,
                        local,
                        fromfile="reference",
                        tofile="evmz",
                    )
                )
            )
        return artifact


def canonical_output(output: TransitionToolOutput) -> dict[str, Any]:
    """Normalize typed EEST output while retaining every consensus field."""
    # Receipt presentation fields differ by tool; receiptsRoot, logsHash and
    # logsBloom commit the consensus receipt content compared below.
    result = output.result.model_dump(
        mode="json",
        by_alias=True,
        exclude={
            "rejected_transactions",
            "block_exception",
            "receipts",
            "traces",
            "opcode_count",
        },
    )
    result["rejected"] = [
        canonical_rejected(rejected) for rejected in output.result.rejected_transactions
    ]
    result["blockException"] = canonical_exception(output.result.block_exception)
    return {
        "alloc": output.alloc.materialize().model_dump(
            mode="json",
            by_alias=True,
        ),
        "result": result,
    }


def outputs_equivalent(
    left: TransitionToolOutput | None,
    right: TransitionToolOutput | None,
) -> bool:
    """Compare transition results using EEST's alternative-exception semantics."""
    assert left is not None and right is not None
    left_json = canonical_output(left)
    right_json = canonical_output(right)
    left_rejected = left_json["result"].pop("rejected")
    right_rejected = right_json["result"].pop("rejected")
    if left_json != right_json or len(left_rejected) != len(right_rejected):
        return False

    for left_tx, right_tx in zip(left_rejected, right_rejected, strict=True):
        left_error = left_tx.pop("error")
        right_error = right_tx.pop("error")
        if left_tx != right_tx or not exceptions_equivalent(left_error, right_error):
            return False
    return True


def exceptions_equivalent(left: Any, right: Any) -> bool:
    """Treat mapped exception lists as alternatives, as EEST verification does."""
    if isinstance(left, list) and isinstance(right, list):
        return not set(left).isdisjoint(right)
    return left == right


def canonical_rejected(rejected: Any) -> dict[str, Any]:
    """Discard client wording after both mappers resolve an EEST exception."""
    value = rejected.model_dump(
        mode="json",
        by_alias=True,
        exclude={"error"},
    )
    value["error"] = canonical_exception(rejected.error)
    return value


def canonical_exception(error: Any) -> Any:
    """Compare canonical exception identities, not client-specific prose."""
    if error is None:
        return None
    if isinstance(error, ExceptionWithMessage):
        return sorted(str(exception) for exception in error.exceptions)
    return {"undefined": str(error)}


def format_json(value: Any) -> str:
    """Produce stable human-readable mismatch output."""
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def write_json(path: Path, value: Any) -> None:
    """Write one deterministic artifact document."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(format_json(value))
