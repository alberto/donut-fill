#!/bin/bash
# Benchmarks scan engines against `du` on one path.
# Usage: scripts/bench.sh <path> [engine[:workers] ...]
# Each engine runs in its own process, twice (cold-ish, then warm), so peak
# RSS is per engine. `du -skx` runs twice too; -x matches the scanner's
# default of not crossing into other volumes.
set -euo pipefail
cd "$(dirname "$0")/.."
path=${1:?usage: bench.sh <path> [engine[:workers] ...]}
shift
engines=("${@:-posix}")

swift build -c release --product scankit-cli >/dev/null
cli=.build/release/scankit-cli

for i in 1 2; do
    out=$( { /usr/bin/time -p du -skx "$path" 2>/dev/null; } 2>&1 ) || true
    kb=$(echo "$out" | awk '/\t/ {print $1}')
    echo "du run=$i $(echo "$out" | awk '/^real/ {r=$2} /^user/ {u=$2} /^sys/ {s=$2} END {printf "wall=%ss user=%ss sys=%ss", r, u, s}') kb=$kb"
done

for spec in "${engines[@]}"; do
    engine=${spec%%:*}
    args=(--engine "$engine" --repeat 2 --top 0)
    [[ $spec == *:* ]] && args+=(--workers "${spec#*:}")
    "$cli" "$path" "${args[@]}"
done
