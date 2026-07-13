#!/usr/bin/env python3
"""Generate typed Zig schemas from a resolved consensus-specs pyspec tree.

The generated Zig is checked in and used directly by the conformance runner.
This script is only an authoring/audit tool: fixture YAML is never interpreted
as a schema at build or run time.
"""

from __future__ import annotations

import argparse
import importlib
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

FORKS = (
    "phase0",
    "altair",
    "bellatrix",
    "capella",
    "deneb",
    "electra",
    "fulu",
    "gloas",
    "heze",
)
PRESETS = ("mainnet", "minimal")
MAX_INLINE_FIXED_STORAGE = 256


def load_dependencies() -> None:
    global boolean, uint
    global Bitlist, Bitvector
    global ByteList, ByteVector
    global Container, List, Vector
    global ProgressiveBitlist, ProgressiveContainer, ProgressiveList

    try:
        from remerkleable.basic import boolean, uint
        from remerkleable.bitfields import Bitlist, Bitvector
        from remerkleable.byte_arrays import ByteList, ByteVector
        from remerkleable.complex import Container, List, Vector
        from remerkleable.progressive import (
            ProgressiveBitlist,
            ProgressiveContainer,
            ProgressiveList,
        )
    except ModuleNotFoundError as error:
        raise SystemExit(
            "missing consensus-specs Python dependencies; run this script through "
            "the pinned consensus-specs `uv run` environment"
        ) from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--pyspec-root",
        type=Path,
        required=True,
        help="directory containing the generated eth_consensus_specs package",
    )
    parser.add_argument(
        "--fixtures-root",
        type=Path,
        required=True,
        help="extracted consensus fixture root containing mainnet/ and minimal/",
    )
    parser.add_argument("--version", required=True, help="consensus-specs release tag")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def is_type(value: Any, base: type) -> bool:
    return isinstance(value, type) and issubclass(value, base)


def kind(value: type) -> str:
    if is_type(value, ProgressiveContainer):
        return "progressive_container"
    if is_type(value, ProgressiveBitlist):
        return "progressive_bitlist"
    if is_type(value, ProgressiveList):
        return "progressive_list"
    if is_type(value, boolean):
        return "boolean"
    if is_type(value, uint):
        return "uint"
    if is_type(value, ByteVector):
        return "byte_vector"
    if is_type(value, ByteList):
        return "byte_list"
    if is_type(value, Bitvector):
        return "bitvector"
    if is_type(value, Bitlist):
        return "bitlist"
    if is_type(value, Vector):
        return "vector"
    if is_type(value, List):
        return "list"
    if is_type(value, Container):
        return "container"
    raise TypeError(f"unsupported SSZ type: {value!r} ({value.__mro__!r})")


def uint_name(value: type) -> str:
    name = value.type_repr()
    if not name.startswith("uint"):
        raise TypeError(f"unsupported basic integer: {name}")
    return f"u{name[4:]}"


@lru_cache(maxsize=None)
def type_fingerprint(value: type) -> tuple[Any, ...]:
    value_kind = kind(value)
    if value_kind == "boolean":
        return (value_kind,)
    if value_kind == "uint":
        return (value_kind, uint_name(value))
    if value_kind in ("byte_vector", "bitvector"):
        return (value_kind, value.vector_length())
    if value_kind in ("byte_list", "bitlist"):
        return (value_kind, value.limit())
    if value_kind == "progressive_bitlist":
        return (value_kind,)
    if value_kind == "vector":
        return (value_kind, value.vector_length(), type_fingerprint(value.element_cls()))
    if value_kind == "list":
        return (value_kind, value.limit(), type_fingerprint(value.element_cls()))
    if value_kind == "progressive_list":
        return (value_kind, type_fingerprint(value.element_cls()))
    if value_kind in ("container", "progressive_container"):
        active = tuple(value._active_fields) if value_kind == "progressive_container" else ()
        fields = tuple(
            (name, type_fingerprint(field_type))
            for name, field_type in value.fields().items()
        )
        # Preserve semantic type names while deduplicating their historical shapes.
        return (value_kind, value.__name__, active, fields)
    raise AssertionError(value_kind)


@dataclass
class Context:
    preset: str
    fork: str
    handlers: dict[str, type]


@dataclass
class Shape:
    fingerprint: tuple[Any, ...]
    name: str
    value: type
    occurrences: set[tuple[str, str]] = field(default_factory=set)
    declaration_fork: str = ""
    symbol: str = ""


def fixture_handlers(fixtures_root: Path, preset: str, fork: str) -> list[str]:
    root = fixtures_root / preset / fork / "ssz_static"
    if not root.is_dir():
        raise FileNotFoundError(root)
    return sorted(path.name for path in root.iterdir() if path.is_dir())


def nested_containers(value: type) -> list[type]:
    value_kind = kind(value)
    if value_kind in ("container", "progressive_container"):
        result = [value]
        for field_type in value.fields().values():
            result.extend(nested_containers(field_type))
        return result
    if value_kind in ("vector", "list", "progressive_list"):
        return nested_containers(value.element_cls())
    return []


def direct_container_dependencies(value: type) -> list[type]:
    value_kind = kind(value)
    if value_kind in ("container", "progressive_container"):
        return [value]
    if value_kind in ("vector", "list", "progressive_list"):
        return direct_container_dependencies(value.element_cls())
    return []


def load_contexts(args: argparse.Namespace) -> list[Context]:
    contexts = []
    for preset in PRESETS:
        for fork in FORKS:
            module = importlib.import_module(f"eth_consensus_specs.{fork}.{preset}")
            handlers = {}
            for name in fixture_handlers(args.fixtures_root, preset, fork):
                value = getattr(module, name)
                if kind(value) not in ("container", "progressive_container"):
                    raise TypeError(f"fixture handler {name} is not a container")
                handlers[name] = value
            contexts.append(Context(preset, fork, handlers))
    return contexts


def collect_shapes(contexts: list[Context]) -> dict[tuple[Any, ...], Shape]:
    shapes: dict[tuple[Any, ...], Shape] = {}
    for context in contexts:
        for root in context.handlers.values():
            for value in nested_containers(root):
                fingerprint = type_fingerprint(value)
                shape = shapes.setdefault(
                    fingerprint,
                    Shape(fingerprint, value.__name__, value),
                )
                shape.occurrences.add((context.preset, context.fork))
    assign_shape_names(shapes)
    return shapes


def occurrence_order(occurrence: tuple[str, str]) -> tuple[int, int]:
    preset, fork = occurrence
    return (FORKS.index(fork), PRESETS.index(preset))


def pascal(name: str) -> str:
    return "".join(part.capitalize() for part in name.split("_"))


def assign_shape_names(shapes: dict[tuple[Any, ...], Shape]) -> None:
    by_name: dict[str, list[Shape]] = defaultdict(list)
    for shape in shapes.values():
        _, first_fork = min(shape.occurrences, key=occurrence_order)
        shape.declaration_fork = first_fork
        by_name[shape.name].append(shape)

    for name, variants in by_name.items():
        if len(variants) == 1:
            variants[0].symbol = name
            continue
        by_base: dict[str, list[Shape]] = defaultdict(list)
        for shape in variants:
            base = f"{name}{pascal(shape.declaration_fork)}"
            by_base[base].append(shape)
        for base, collisions in by_base.items():
            if len(collisions) == 1:
                collisions[0].symbol = base
                continue
            for shape in collisions:
                first_preset, _ = min(shape.occurrences, key=occurrence_order)
                shape.symbol = f"{base}{pascal(first_preset)}"

    symbols: dict[str, Shape] = {}
    for shape in shapes.values():
        old = symbols.setdefault(shape.symbol, shape)
        if old is not shape:
            raise TypeError(f"generated symbol collision: {shape.symbol}")


def shape_for(value: type, shapes: dict[tuple[Any, ...], Shape]) -> Shape:
    return shapes[type_fingerprint(value)]


def shape_ref(shape: Shape, current_fork: str) -> str:
    if shape.declaration_fork == current_fork:
        return shape.symbol
    if FORKS.index(shape.declaration_fork) > FORKS.index(current_fork):
        raise TypeError(f"{shape.symbol} depends on a future fork")
    return f"{shape.declaration_fork}_types.{shape.symbol}"


def zig_type(value: type, shapes: dict[tuple[Any, ...], Shape], current_fork: str) -> str:
    value_kind = kind(value)
    if value_kind == "boolean":
        return "bool"
    if value_kind == "uint":
        return uint_name(value)
    if value_kind == "byte_vector":
        length = value.vector_length()
        return f"[{length}]u8" if length <= MAX_INLINE_FIXED_STORAGE else "[]const u8"
    if value_kind == "byte_list":
        return "[]const u8"
    if value_kind == "bitvector":
        length = value.vector_length()
        return f"[{length}]bool" if length <= MAX_INLINE_FIXED_STORAGE else "[]const bool"
    if value_kind in ("bitlist", "progressive_bitlist"):
        return "[]const bool"
    if value_kind == "vector":
        return f"[]const {zig_type(value.element_cls(), shapes, current_fork)}"
    if value_kind in ("list", "progressive_list"):
        return f"[]const {zig_type(value.element_cls(), shapes, current_fork)}"
    if value_kind in ("container", "progressive_container"):
        return shape_ref(shape_for(value, shapes), current_fork)
    raise AssertionError(value_kind)


def codec_expr(value: type, shapes: dict[tuple[Any, ...], Shape], current_fork: str) -> str:
    value_kind = kind(value)
    if value_kind in ("boolean", "uint"):
        return f"ssz.Fixed({zig_type(value, shapes, current_fork)})"
    if value_kind == "byte_vector":
        base = f"ssz.ByteVector({value.vector_length()})"
        return base if value.vector_length() <= MAX_INLINE_FIXED_STORAGE else f"ssz.Alloc({base})"
    if value_kind == "byte_list":
        return f"ssz.ByteList({value.limit()})"
    if value_kind == "bitvector":
        base = f"ssz.Bitvector({value.vector_length()})"
        return base if value.vector_length() <= MAX_INLINE_FIXED_STORAGE else f"ssz.Alloc({base})"
    if value_kind == "bitlist":
        return f"ssz.Bitlist({value.limit()})"
    if value_kind == "progressive_bitlist":
        return "ssz.ProgressiveBitlist"
    if value_kind == "vector":
        child = codec_expr(value.element_cls(), shapes, current_fork)
        return f"ssz.Alloc(ssz.VectorOf({child}, {value.vector_length()}))"
    if value_kind == "list":
        child = codec_expr(value.element_cls(), shapes, current_fork)
        return f"ssz.ListOf({child}, {value.limit()})"
    if value_kind == "progressive_list":
        child = value.element_cls()
        if kind(child) == "uint" and uint_name(child) == "u8":
            return "ssz.ProgressiveByteList"
        return f"ssz.ProgressiveListOf({codec_expr(child, shapes, current_fork)})"
    if value_kind in ("container", "progressive_container"):
        return f"{shape_ref(shape_for(value, shapes), current_fork)}.Ssz"
    raise AssertionError(value_kind)


def ordered_shapes_for_fork(
    fork: str,
    shapes: dict[tuple[Any, ...], Shape],
) -> list[Shape]:
    selected = [shape for shape in shapes.values() if shape.declaration_fork == fork]
    ordered: list[Shape] = []
    visiting: set[tuple[Any, ...]] = set()
    visited: set[tuple[Any, ...]] = set()

    def visit(shape: Shape) -> None:
        if shape.fingerprint in visited:
            return
        if shape.fingerprint in visiting:
            raise TypeError(f"recursive container dependency at {shape.symbol}")
        visiting.add(shape.fingerprint)
        for field_type in shape.value.fields().values():
            for dependency in direct_container_dependencies(field_type):
                dependency_shape = shape_for(dependency, shapes)
                if dependency_shape.declaration_fork == fork:
                    visit(dependency_shape)
                elif FORKS.index(dependency_shape.declaration_fork) > FORKS.index(fork):
                    raise TypeError(f"{shape.symbol} depends on a future fork")
        visiting.remove(shape.fingerprint)
        visited.add(shape.fingerprint)
        ordered.append(shape)

    for shape in sorted(selected, key=lambda item: item.symbol):
        visit(shape)
    return ordered


def needs_override(value: type) -> bool:
    value_kind = kind(value)
    if value_kind in ("boolean", "uint", "container", "progressive_container"):
        return False
    if value_kind == "byte_vector":
        return value.vector_length() > MAX_INLINE_FIXED_STORAGE
    return True


def emit_container(
    shape: Shape,
    shapes: dict[tuple[Any, ...], Shape],
    fork: str,
) -> list[str]:
    value = shape.value
    lines = [f"pub const {shape.symbol} = struct {{"]
    for name, field_type in value.fields().items():
        lines.append(f'    @"{name}": {zig_type(field_type, shapes, fork)},')
    lines.append("")
    if kind(value) == "progressive_container":
        active = ", ".join("true" if item else "false" for item in value._active_fields)
        lines.append(f"    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{{ {active} }}, .{{")
    else:
        lines.append("    pub const Ssz = ssz.Container(@This(), .{")
    for name, field_type in value.fields().items():
        if needs_override(field_type):
            lines.append(f'        .@"{name}" = {codec_expr(field_type, shapes, fork)},')
    lines.append("    });")
    lines.append("};")
    lines.append("")
    return lines


def emit_fork_module(
    version: str,
    fork: str,
    shapes: dict[tuple[Any, ...], Shape],
) -> str:
    ordered = ordered_shapes_for_fork(fork, shapes)
    lines = [
        f"//! Generated from consensus-specs {version} resolved pyspec.",
        f"//! Unique named schema shapes first required at {fork}.",
        "//! Regenerate with scripts/generate-consensus-ssz-schemas.py.",
        "",
        'const ssz = @import("ssz");',
    ]
    for previous in FORKS[: FORKS.index(fork)]:
        lines.append(f'const {previous}_types = @import("{previous}.zig");')
    lines.append("")
    for shape in ordered:
        lines.extend(emit_container(shape, shapes, fork))
    return "\n".join(lines)


def emit_index(
    version: str,
    contexts: list[Context],
    shapes: dict[tuple[Any, ...], Shape],
) -> str:
    by_context = {(context.preset, context.fork): context for context in contexts}
    lines = [
        f"//! Generated from consensus-specs {version} resolved pyspec.",
        "//! Maps preset/fork fixture names to deduplicated schema codecs.",
        "//! Regenerate with scripts/generate-consensus-ssz-schemas.py.",
        "",
    ]
    lines.append("pub const Preset = enum {")
    lines.extend(f"    {preset}," for preset in PRESETS)
    lines.extend(("};", ""))
    lines.append("pub const Fork = enum {")
    lines.extend(f"    {fork}," for fork in FORKS)
    lines.extend(("};", ""))
    for fork in FORKS:
        lines.append(f'const {fork}_types = @import("{fork}.zig");')
    lines.append("")
    for preset in PRESETS:
        lines.append(f"pub const {preset} = struct {{")
        for fork in FORKS:
            context = by_context[(preset, fork)]
            lines.append(f"    pub const {fork} = struct {{")
            lines.append("        pub const handlers = .{")
            for name, value in context.handlers.items():
                shape = shape_for(value, shapes)
                codec = f"{shape.declaration_fork}_types.{shape.symbol}.Ssz"
                lines.append(f'            .{{ .name = "{name}", .codec = {codec} }},')
            lines.append("        };")
            lines.append("    };")
        lines.append("};")
        lines.append("")
    return "\n".join(lines)


def validate_output_directory(output: Path) -> None:
    expected = {"index.zig", *(f"{fork}.zig" for fork in FORKS)}
    stale = sorted(path.name for path in output.glob("*.zig") if path.name not in expected)
    if stale:
        raise RuntimeError(f"remove stale generated schema files: {', '.join(stale)}")


def main() -> None:
    args = parse_args()
    load_dependencies()
    sys.path.insert(0, str(args.pyspec_root))
    args.output.mkdir(parents=True, exist_ok=True)
    validate_output_directory(args.output)
    contexts = load_contexts(args)
    shapes = collect_shapes(contexts)
    generated = []

    for fork in FORKS:
        output = args.output / f"{fork}.zig"
        count = sum(shape.declaration_fork == fork for shape in shapes.values())
        output.write_text(emit_fork_module(args.version, fork, shapes), encoding="ascii")
        generated.append(output)
        print(f"generated {output}: {count} unique shapes")

    index = args.output / "index.zig"
    index.write_text(emit_index(args.version, contexts, shapes), encoding="ascii")
    generated.append(index)
    print(f"generated {index}: {len(shapes)} total unique named shapes")
    subprocess.run(["zig", "fmt", *(str(path) for path in generated)], check=True)


if __name__ == "__main__":
    main()
