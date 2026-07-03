#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/classify-eest-fixtures.sh [options] [fixture-root]

Runs EEST state-test JSON files one-by-one with a timeout and prints a coverage
classification summary.

Prefer `zig build eest-classify -- --exclude-static` for fast local iteration.
Use this script when per-file timeout or crash isolation matters.

Options:
  --exclude-static       skip paths containing /static/
  --limit N              stop after N JSON files
  --timeout SECONDS      per-file timeout, default: 3
  --out PATH             raw output path, default: ../.eest/reports/state-tests.raw.txt
  -h, --help             show this help

Environment:
  EEST_FIXTURE_ROOT      default fixture root
  EEST_RUNNER            compiled runner path, default: ../.eest/bin/evmz-eest
  EEST_TIMEOUT_BIN       timeout binary override

Examples:
  scripts/classify-eest-fixtures.sh --exclude-static
  scripts/classify-eest-fixtures.sh ../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0/fixtures/state_tests/cancun
  scripts/classify-eest-fixtures.sh --limit 50 --timeout 5
USAGE
}

lock_path=""
lock_prefix=""
if [[ -f "../eest.lock" ]]; then
  lock_path="../eest.lock"
  lock_prefix=".."
elif [[ -f "eest.lock" ]]; then
  lock_path="eest.lock"
fi

lock_value() {
  local key="$1"
  [[ -n "${lock_path}" ]] || return 1
  awk -F= -v key="${key}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      lhs=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
      if (lhs == key) {
        sub(/^[^=]*=/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
        exit
      }
    }
  ' "${lock_path}"
}

lock_path_value() {
  local key="$1"
  local value
  value="$(lock_value "${key}")"
  [[ -n "${value}" ]] || return 1
  if [[ "${value}" = /* || -z "${lock_prefix}" ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s/%s\n' "${lock_prefix}" "${value}"
  fi
}

default_root="$(lock_path_value dest || printf '../.eest/fixtures/tests-glamsterdam-devnet-v6.1.0')/fixtures/state_tests"
root="${EEST_FIXTURE_ROOT:-${default_root}}"
runner="${EEST_RUNNER:-../.eest/bin/evmz-eest}"
timeout_seconds=3
out="../.eest/reports/state-tests.raw.txt"
exclude_static=0
limit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude-static)
      exclude_static=1
      shift
      ;;
    --limit)
      [[ $# -ge 2 ]] || { printf 'missing value for --limit\n' >&2; exit 2; }
      limit="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { printf 'missing value for --timeout\n' >&2; exit 2; }
      timeout_seconds="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { printf 'missing value for --out\n' >&2; exit 2; }
      out="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      root="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$root" ]]; then
  printf 'fixture root not found: %s\n' "$root" >&2
  exit 1
fi

timeout_bin="${EEST_TIMEOUT_BIN:-}"
if [[ -z "$timeout_bin" ]]; then
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
fi
if [[ -z "$timeout_bin" ]]; then
  printf 'timeout command not found; install coreutils or set EEST_TIMEOUT_BIN\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$runner")" "$(dirname "$out")"

printf 'Building %s\n' "$runner" >&2
zig build -Doptimize=ReleaseFast --prefix ../.eest
default_runner="../.eest/bin/evmz-eest"
if [[ "$runner" != "$default_runner" ]]; then
  cp "$default_runner" "$runner"
fi

: > "$out"
count=0
timeouts=0
crashes=0
started_at="$(date +%s)"

while IFS= read -r -d '' file; do
  if [[ "$exclude_static" -eq 1 && "$file" == */static/* ]]; then
    continue
  fi

  if [[ "$limit" -gt 0 && "$count" -ge "$limit" ]]; then
    break
  fi
  count=$((count + 1))

  set +e
  "$timeout_bin" "$timeout_seconds" "$runner" "$file" >> "$out" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 124 ]]; then
    timeouts=$((timeouts + 1))
    printf '%s: timeout=%ss\n' "$file" "$timeout_seconds" >> "$out"
  elif [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    crashes=$((crashes + 1))
    printf '%s: crash_rc=%s\n' "$file" "$rc" >> "$out"
  fi

  if (( count % 100 == 0 )); then
    printf 'classified %d files...\n' "$count" >&2
  fi
done < <(find "$root" -type f -name '*.json' -print0)

ended_at="$(date +%s)"
summary="${out}.summary"

python3 - "$out" "$count" "$timeouts" "$crashes" "$((ended_at - started_at))" <<'PY' | tee "$summary"
import collections
import re
import sys

raw_path = sys.argv[1]
files_seen = int(sys.argv[2])
timeouts_seen = int(sys.argv[3])
crashes_seen = int(sys.argv[4])
seconds = int(sys.argv[5])

line_re = re.compile(
    r"^(?P<path>.*?): fixtures=(?P<fixtures>\d+) vectors=(?P<vectors>\d+) "
    r"passed=(?P<passed>\d+) failed=(?P<failed>\d+) skipped=(?P<skipped>\d+) unchecked=(?P<unchecked>\d+)$"
)
reason_re = re.compile(r"^  (?P<kind>fail|unchecked)\.(?P<reason>[^=]+)=(?P<count>\d+)$")
timeout_re = re.compile(r"^(?P<path>.*?): timeout=(?P<timeout>.+)$")
crash_re = re.compile(r"^(?P<path>.*?): crash_rc=(?P<rc>\d+)$")


def cluster(path: str) -> tuple[str, str]:
    parts = path.split("/")
    try:
        i = parts.index("state_tests")
    except ValueError:
        return "unknown", "unknown"
    fork = parts[i + 1] if i + 1 < len(parts) else "unknown"
    if fork == "static":
        # static/state_tests/<legacy-suite>/<file>
        group = f"static/{parts[i + 3]}" if i + 3 < len(parts) else "static/unknown"
    else:
        group = parts[i + 2] if i + 2 < len(parts) else "unknown"
    return fork, group


def empty_stats():
    return collections.Counter({"files": 0, "vectors": 0, "passed": 0, "failed": 0, "skipped": 0, "unchecked": 0})


totals = empty_stats()
by_fork = collections.defaultdict(empty_stats)
by_group = collections.defaultdict(empty_stats)
fail_reasons = collections.Counter()
fail_by_group = collections.Counter()
failed_files = []
timeouts = []
crashes = []
current = None

with open(raw_path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if match := line_re.match(line):
            current = match.group("path")
            fork, group = cluster(current)
            stats = {k: int(match.group(k)) for k in ("vectors", "passed", "failed", "skipped", "unchecked")}
            stats["files"] = 1
            for key, value in stats.items():
                totals[key] += value
                by_fork[fork][key] += value
                by_group[group][key] += value
            if stats["failed"] > 0:
                failed_files.append((stats["failed"], current))
            continue

        if match := reason_re.match(line):
            if current is None:
                continue
            reason = match.group("reason")
            count = int(match.group("count"))
            _, group = cluster(current)
            if match.group("kind") == "fail":
                fail_reasons[reason] += count
                fail_by_group[(group, reason)] += count
            continue

        if match := timeout_re.match(line):
            path = match.group("path")
            _, group = cluster(path)
            timeouts.append((group, path))
            continue

        if match := crash_re.match(line):
            path = match.group("path")
            _, group = cluster(path)
            crashes.append((group, path, match.group("rc")))

completed = totals["files"]
vectors = totals["vectors"]
exercised = totals["passed"] + totals["failed"]

print(f"files_seen={files_seen} completed={completed} timeouts={timeouts_seen} crashes={crashes_seen} seconds={seconds}")
print(
    f"vectors={vectors} passed={totals['passed']} failed={totals['failed']} "
    f"skipped={totals['skipped']} unchecked={totals['unchecked']}"
)
if vectors:
    print(
        f"pct passed={totals['passed'] / vectors * 100:.1f} "
        f"failed={totals['failed'] / vectors * 100:.1f} "
        f"skipped={totals['skipped'] / vectors * 100:.1f}"
    )
if exercised:
    print(f"exercised={exercised} pass_of_exercised={totals['passed'] / exercised * 100:.1f}")

def print_stats(title, rows, key):
    print()
    print(title)
    for name, stats in sorted(rows.items(), key=lambda item: (-item[1][key], item[0])):
        print(
            f"{name:<32} files={stats['files']:5d} vectors={stats['vectors']:7d} "
            f"passed={stats['passed']:7d} failed={stats['failed']:7d} "
            f"skipped={stats['skipped']:7d} unchecked={stats['unchecked']:7d}"
        )

print_stats("by_fork:", by_fork, "vectors")
print_stats("top_failed_clusters:", {k: v for k, v in by_group.items() if v["failed"] > 0}, "failed")

print()
print("fail_reasons:")
for reason, count in fail_reasons.most_common():
    print(f"{reason:<36} {count:8d}")

print()
print("fail_reasons_by_cluster:")
for (group, reason), count in sorted(fail_by_group.items(), key=lambda item: (-item[1], item[0][0], item[0][1]))[:30]:
    print(f"{count:8d} {group:<32} {reason}")

print()
print("top_failed_files:")
for count, path in sorted(failed_files, reverse=True)[:30]:
    print(f"{count:8d} {path}")

print()
print("timeouts_by_cluster:")
timeout_counts = collections.Counter(group for group, _ in timeouts)
for group, count in timeout_counts.most_common():
    print(f"{count:8d} {group}")

print()
print("timeouts:")
for _, path in sorted(timeouts):
    print(path)

print()
print("crashes_by_cluster:")
crash_counts = collections.Counter(group for group, _, _ in crashes)
for group, count in crash_counts.most_common():
    print(f"{count:8d} {group}")

print()
print("crashes:")
for _, path, rc in sorted(crashes):
    print(f"{path} rc={rc}")
PY

printf '\nraw=%s\nsummary=%s\n' "$out" "$summary"
