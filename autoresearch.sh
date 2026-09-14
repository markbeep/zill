#!/usr/bin/env bash
#
# Benchmark harness for the Dijkstra optimisation in src/graph/solve.zig.
#
# Runs the whole test suite in ReleaseFast. The unit tests in
# src/graph/solve.zig gate correctness: a failing test fails this script, so a
# faster but wrong search never counts as an improvement. The
# "solve: benchmark dijkstra" test then measures a fixed workload on
# data/switzerland_walkable.zl and prints the METRIC lines below.
#
# Workload (all constants live in BenchWorkload in src/graph/solve.zig):
#   local    - 128 start nodes, 1 km budget   (short walk, small search)
#   regional -   8 start nodes, 10 km budget  (long walk, large search)
#   both run Dijkstra(.Elevation) and Dijkstra(.Path), 5 repetitions per start
#   node; per start node the median repetition is reported.
#
# Primary metric:
#   dijkstra_us - geometric mean of the per-run microseconds of the two
#                 regimes, i.e. sqrt(local_us * regional_us). Lower is better.
#
# Secondary metrics:
#   dijkstra_local_peak_us, dijkstra_local_path_us,
#   dijkstra_regional_peak_us, dijkstra_regional_path_us,
#   dijkstra_local_us, dijkstra_regional_us,
#   dijkstra_alloc_bytes         - bytes requested by the largest single run
#   dijkstra_local_checksum,
#   dijkstra_regional_checksum   - result checksums; any semantic change moves
#                                  these, and every repetition is required to
#                                  match the first one inside the test
#   dijkstra_path_distance_mismatches,
#   dijkstra_path_elevation_mismatches
#                                - returned paths whose reported distance (resp.
#                                  elevation) does not match the returned node
#                                  chain (known quirk of the current code: the
#                                  totals come from the relaxation that produced
#                                  the best node, the indices are rebuilt from
#                                  the final search state)
set -euo pipefail

cd "$(dirname "$0")"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

if ! zig build -Doptimize=ReleaseFast test -- --test-filter "solve" >"$log" 2>&1; then
    cat "$log"
    echo "autoresearch: test suite failed" >&2
    exit 1
fi

# The test runner prefixes its first output line, so match METRIC anywhere.
metrics=$(sed -n 's/.*\(METRIC [a-z_]*=[0-9.]*\).*/\1/p' "$log")

if [ -z "$metrics" ]; then
    cat "$log"
    echo "autoresearch: benchmark produced no METRIC lines" >&2
    exit 1
fi

printf '%s\n' "$metrics"
