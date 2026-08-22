"""Register evmz's stateless fixture consumer with consume direct."""

import re
from pathlib import Path

from evmz_consumer_common import CachedRun, consume_fixture
from execution_testing.client_clis.ethereum_cli import EthereumCLI
from execution_testing.client_clis.fixture_consumer_tool import (
    FixtureConsumerTool,
)
from execution_testing.fixtures import (
    BlockchainFixture,
    FixtureFormat,
)


class EvmzZkevmFixtureConsumer(
    FixtureConsumerTool,
    fixture_formats=[BlockchainFixture],
):
    """Consume stateless blockchain fixtures through evmz-eest."""

    default_binary = Path("evmz-eest")
    detect_binary_pattern = re.compile(r"^evmz-eest\b")
    version_flag = "--version"
    cached_version: str | None = None

    def __init__(
        self,
        *,
        binary: Path | None = None,
        trace: bool = False,
    ) -> None:
        EthereumCLI.__init__(self, binary=binary)
        self.trace = trace
        self.cache: dict[tuple[str, Path], CachedRun] = {}

    def consume_fixture(
        self,
        fixture_format: FixtureFormat,
        fixture_path: Path,
        fixture_name: str | None = None,
        debug_output_path: Path | None = None,
    ) -> None:
        if fixture_format is not BlockchainFixture:
            raise ValueError(
                f"unsupported evmz zkEVM fixture format: {fixture_format.format_name}"
            )
        consume_fixture(
            binary=self.binary,
            subcommand="zkevmtest",
            fixture_path=fixture_path,
            fixture_name=fixture_name,
            debug_output_path=debug_output_path,
            cache=self.cache,
        )
