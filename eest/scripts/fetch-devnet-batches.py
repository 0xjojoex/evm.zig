#!/usr/bin/env python3
"""Resolve, verify, and extract a rolling devnet R2 corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class CorpusError(ValueError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-url", required=True)
    parser.add_argument("--latest-batches", type=int, default=10)
    parser.add_argument("--network", required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--resolved-manifest", type=Path, required=True)
    return parser.parse_args()


def fetch_bytes(url: str, attempts: int = 3) -> bytes:
    try:
        return subprocess.run(
            [
                "curl",
                "-fsSL",
                "--proto",
                "=https",
                "--tlsv1.2",
                "--retry",
                str(attempts),
                "--user-agent",
                "evmz-ci/1",
                url,
            ],
            check=True,
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError as error:
        message = error.stderr.decode(errors="replace").strip()
        raise CorpusError(f"failed to download {url}: {message}") from error


def sha256_hex(value: Any) -> str:
    text = str(value)
    if text.startswith("0x"):
        text = text[2:]
    if len(text) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in text):
        raise CorpusError(f"invalid sha256: {value}")
    return text.lower()


def validate_batch(batch: dict[str, Any], network: str) -> dict[str, Any]:
    required = {
        "schemaVersion",
        "network",
        "batchStartBlock",
        "batchEndBlock",
        "batchSize",
        "artifactCount",
        "byteLength",
        "sha256",
        "path",
    }
    missing = sorted(required - batch.keys())
    if missing:
        raise CorpusError(f"batch is missing fields: {', '.join(missing)}")
    if batch["schemaVersion"] != 2:
        raise CorpusError(f"unsupported batch schema: {batch['schemaVersion']}")
    if batch["network"] != network:
        raise CorpusError(f"batch network {batch['network']} does not match {network}")

    start = int(batch["batchStartBlock"])
    end = int(batch["batchEndBlock"])
    size = int(batch["batchSize"])
    artifacts = int(batch["artifactCount"])
    byte_length = int(batch["byteLength"])
    path = str(batch["path"])
    if start < 0 or end < start or end - start + 1 != size:
        raise CorpusError(f"invalid batch range: {start}-{end} size={size}")
    if artifacts < size:
        raise CorpusError(f"incomplete batch {start}-{end}: {artifacts}/{size} artifacts")
    if byte_length <= 0:
        raise CorpusError(f"empty batch {start}-{end}")
    if path.startswith("/") or ".." in Path(path).parts or not path.endswith(".tar.zst"):
        raise CorpusError(f"unsafe batch path: {path}")

    validated = dict(batch)
    validated["sha256"] = f"0x{sha256_hex(batch['sha256'])}"
    return validated


def validate_sequence(batches: list[dict[str, Any]]) -> None:
    if not batches:
        raise CorpusError("corpus has no batches")
    for previous, current in zip(batches, batches[1:]):
        if int(previous["batchEndBlock"]) + 1 != int(current["batchStartBlock"]):
            raise CorpusError(
                f"non-contiguous batches: {previous['batchStartBlock']}-"
                f"{previous['batchEndBlock']} then {current['batchStartBlock']}-"
                f"{current['batchEndBlock']}"
            )


def resolve_catalog(catalog_url: str, network: str, count: int) -> dict[str, Any]:
    if count <= 0:
        raise CorpusError("latest batch count must be positive")
    catalog_url = catalog_url.rstrip("/")
    manifest = json.loads(fetch_bytes(f"{catalog_url}/manifest.json"))
    if manifest.get("schemaVersion") != 2:
        raise CorpusError(f"unsupported catalog schema: {manifest.get('schemaVersion')}")
    if manifest.get("network") != network:
        raise CorpusError(f"catalog network {manifest.get('network')} does not match {network}")

    records = []
    for line_number, line in enumerate(
        fetch_bytes(f"{catalog_url}/batches.jsonl").splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            records.append(validate_batch(json.loads(line), network))
        except (CorpusError, json.JSONDecodeError) as error:
            raise CorpusError(f"invalid batches.jsonl line {line_number}: {error}") from error
    records.sort(key=lambda batch: int(batch["batchStartBlock"]))
    batches = records[-count:]
    if len(batches) != count:
        raise CorpusError(f"catalog contains only {len(batches)} batches, expected {count}")
    validate_sequence(batches)

    digest = hashlib.sha256(
        json.dumps(batches, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    start = int(batches[0]["batchStartBlock"])
    end = int(batches[-1]["batchEndBlock"])
    return {
        "schema_version": 1,
        "id": f"{network}-{start}-{end}-{digest[:16]}",
        "network": network,
        "catalog_url": catalog_url,
        "catalog_generated_at": manifest.get("generatedAt"),
        "corpus_digest": digest,
        "mode": "rolling",
        "batches": batches,
    }


def safe_archive_members(archive: Path) -> None:
    result = subprocess.run(
        ["tar", "--zstd", "-tf", str(archive)],
        check=True,
        capture_output=True,
        text=True,
    )
    for name in result.stdout.splitlines():
        normalized = posixpath.normpath(name)
        if (
            normalized.startswith("/")
            or normalized == ".."
            or normalized.startswith("../")
        ):
            raise CorpusError(f"unsafe archive member: {name}")


def download_batch(
    catalog_url: str,
    batch: dict[str, Any],
    output_root: Path,
) -> list[dict[str, Any]]:
    start = int(batch["batchStartBlock"])
    end = int(batch["batchEndBlock"])
    batch_id = f"{start}-{end}"
    archive = output_root / f"{batch_id}.tar.zst"
    extract_root = output_root / batch_id
    payload = fetch_bytes(f"{catalog_url}/{batch['path']}")
    if len(payload) != int(batch["byteLength"]):
        raise CorpusError(f"batch {batch_id} length mismatch")
    actual_hash = hashlib.sha256(payload).hexdigest()
    expected_hash = sha256_hex(batch["sha256"])
    if actual_hash != expected_hash:
        raise CorpusError(f"batch {batch_id} sha256 mismatch: {actual_hash} != {expected_hash}")

    archive.write_bytes(payload)
    safe_archive_members(archive)
    extract_root.mkdir()
    subprocess.run(
        [
            "tar",
            "--zstd",
            "--no-same-owner",
            "--no-same-permissions",
            "-xf",
            str(archive),
            "-C",
            str(extract_root),
        ],
        check=True,
    )
    archive.unlink()

    fixtures = [
        path
        for path in extract_root.rglob("*.json")
        if "blockchain_tests" in path.relative_to(extract_root).parts
    ]
    expected_artifacts = int(batch["artifactCount"])
    if len(fixtures) != expected_artifacts:
        raise CorpusError(
            f"batch {batch_id} extracted {len(fixtures)} fixtures, expected {expected_artifacts}"
        )

    archive_manifest = json.loads((extract_root / ".meta" / "manifest.json").read_text())
    archive_identity = (
        archive_manifest.get("schemaVersion"),
        archive_manifest.get("network"),
        archive_manifest.get("batchStartBlock"),
        archive_manifest.get("batchEndBlock"),
    )
    expected_identity = (2, batch["network"], start, end)
    if archive_identity != expected_identity:
        raise CorpusError(f"batch {batch_id} has mismatched archive metadata")
    artifacts = archive_manifest.get("artifacts")
    if (
        not isinstance(artifacts, list)
        or len(artifacts) != expected_artifacts
        or any(not isinstance(artifact, dict) for artifact in artifacts)
    ):
        raise CorpusError(f"batch {batch_id} has invalid artifact metadata")
    fixture_names = {str(path.relative_to(extract_root)) for path in fixtures}
    artifact_names = {str(artifact.get("archivePath")) for artifact in artifacts}
    if fixture_names != artifact_names:
        raise CorpusError(f"batch {batch_id} artifact paths do not match extracted fixtures")

    blocks = []
    for artifact in artifacts:
        try:
            blocks.append(
                {
                    "block_number": int(artifact["blockNumber"]),
                    "block_hash": str(artifact["blockHash"]),
                    "slot_number": int(artifact["slotNumber"]),
                    "gas_used": int(artifact["gasUsed"]),
                    "stateless_input_byte_length": int(artifact["statelessInputByteLength"]),
                    "fixture": str(artifact["archivePath"]),
                }
            )
        except (KeyError, TypeError, ValueError) as error:
            raise CorpusError(f"batch {batch_id} has malformed block metadata") from error
    return blocks


def main() -> int:
    args = parse_args()
    try:
        corpus = resolve_catalog(args.catalog_url, args.network, args.latest_batches)
        if args.output_root.exists() and any(args.output_root.iterdir()):
            raise CorpusError(f"output root is not empty: {args.output_root}")
        args.output_root.mkdir(parents=True, exist_ok=True)

        blocks = []
        for batch in corpus["batches"]:
            blocks.extend(download_batch(corpus["catalog_url"], batch, args.output_root))
        fixture_roots = sorted(
            str(path.resolve())
            for path in args.output_root.rglob("blockchain_tests")
            if path.is_dir()
        )
        if len(fixture_roots) != len(corpus["batches"]):
            raise CorpusError(
                f"extracted {len(fixture_roots)} fixture roots for "
                f"{len(corpus['batches'])} batches"
            )

        resolved = {
            **corpus,
            "resolved_at": datetime.now(timezone.utc).isoformat(),
            "fixture_count": sum(int(batch["artifactCount"]) for batch in corpus["batches"]),
            "fixture_roots": fixture_roots,
            "blocks": sorted(blocks, key=lambda block: int(block["block_number"])),
        }
        args.resolved_manifest.parent.mkdir(parents=True, exist_ok=True)
        args.resolved_manifest.write_text(json.dumps(resolved, indent=2, sort_keys=True) + "\n")
        print(
            f"resolved {resolved['id']}: {len(resolved['batches'])} batches, "
            f"{resolved['fixture_count']} fixtures"
        )
        return 0
    except (CorpusError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
