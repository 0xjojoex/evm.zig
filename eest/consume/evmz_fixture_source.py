"""Resolve an execution-spec fixture source and describe its local corpus."""

import argparse
import configparser
import json
from pathlib import Path
from urllib.parse import unquote, urlparse

from execution_testing.cli.pytest_commands.plugins.consume.consume import (
    FixturesSource,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="tests-zkevm@latest")
    parser.add_argument("--cache-folder", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args()


def count_stateless_blocks(root: Path, test_cases: list[dict]) -> tuple[int, int]:
    paths = {
        case["json_path"]
        for case in test_cases
        if case.get("format") == "blockchain_test"
    }
    blocks = 0
    for relative_path in paths:
        path = root / relative_path
        with path.open() as file:
            document = json.load(file)
        for fixture in document.values():
            for block in fixture.get("blocks", []):
                value = block.get("statelessInputBytes")
                if isinstance(value, str):
                    blocks += 1
    return len(paths), blocks


def resolved_id(source: FixturesSource) -> str:
    if not source.release_page:
        return source.input_option
    return unquote(Path(urlparse(source.release_page).path).name)


def main() -> None:
    args = parse_args()
    source = FixturesSource.from_input(args.input, args.cache_folder)
    fixture_root = source.path.resolve()
    index_path = fixture_root / ".meta" / "index.json"
    properties_path = fixture_root / ".meta" / "fixtures.ini"
    blockchain_root = fixture_root / "blockchain_tests"
    if not index_path.is_file() or not blockchain_root.is_dir():
        raise SystemExit(f"not a blockchain fixture corpus: {fixture_root}")

    with index_path.open() as file:
        index = json.load(file)
    root_hash = index.get("root_hash")
    if not isinstance(root_hash, str) or not root_hash.startswith("0x"):
        raise SystemExit(f"fixture index has no root hash: {index_path}")

    properties = configparser.ConfigParser()
    properties.read(properties_path)
    source_commit = properties.get("fixtures", "commit", fallback="")
    test_cases = index.get("test_cases", [])
    fixture_files, fixture_count = count_stateless_blocks(fixture_root, test_cases)
    indexed_tests = sum(
        1 for case in test_cases if case.get("format") == "blockchain_test"
    )
    release_id = resolved_id(source)
    forks = [fork for fork in index.get("forks", []) if "To" not in fork]

    manifest = {
        "schema_version": 1,
        "mode": "tests-zkevm",
        "id": release_id,
        "corpus_digest": root_hash,
        "fixture_release": release_id,
        "network": ",".join(forks) or "unknown",
        "source_commit": source_commit,
        "source_url": source.url,
        "release_page": source.release_page,
        "fixture_root": str(fixture_root),
        "fixture_roots": [str(blockchain_root)],
        "fixture_files": fixture_files,
        "indexed_tests": indexed_tests,
        "fixture_count": fixture_count,
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(
        f"resolved {release_id}: files={fixture_files} "
        f"stateless_blocks={fixture_count} root={fixture_root}"
    )


if __name__ == "__main__":
    main()
