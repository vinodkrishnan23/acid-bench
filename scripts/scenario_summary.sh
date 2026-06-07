#!/usr/bin/env bash
# scenario_summary.sh — print a consolidated table from per-scenario bench logs.
# Each log must begin with a `SCENARIO sessions=N tps=M duration=Ks` marker line
# followed by the binary's STEADY-STATE block. Files are read in the order given
# (the scenarios scripts pass them in run order).
#
# Usage: scenario_summary.sh <log1> [log2 ...]
set -euo pipefail

[ $# -lt 1 ] && { echo "usage: $0 <log1> [log2 ...]" >&2; exit 1; }

# header
printf "| %-8s | %-9s | %-8s | %-11s | %-7s | %-6s | %-6s | %-6s | %-6s | %-6s | %-7s | %-5s |\n" \
  "Users" "TargetTPS" "Duration" "Committed" "TPS" "p50" "p95" "p99" "p99.9" "Max" "Retries" "Pass"
echo "|----------|-----------|----------|-------------|---------|--------|--------|--------|--------|--------|---------|-------|"

for log in "$@"; do
  awk '
    /^SCENARIO/ {
      for (i=2; i<=NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "sessions") sessions = kv[2]
        else if (kv[1] == "tps") target_tps = kv[2]
        else if (kv[1] == "duration") duration = kv[2] "s"
      }
    }
    /windowed TPS:/ {
      for (i=1; i<=NF; i++) {
        if ($i == "(post-warmup):") committed = $(i+1)
        else if ($i == "TPS:")      w_tps     = $(i+1)
      }
    }
    /^  retries:/ { retries = $2 }
    /^  median/ {
      for (i=1; i<=NF; i++) {
        if      ($i == "median") median = $(i+1)
        else if ($i == "p95")    p95    = $(i+1)
        else if ($i == "p99")    p99    = $(i+1)
        else if ($i == "p99.9")  p999   = $(i+1)
        else if ($i == "max")    mx     = $(i+1)
      }
    }
    /^  PASS/ { pass = $NF }
    END {
      printf "| %-8s | %-9s | %-8s | %-11s | %-7s | %-6s | %-6s | %-6s | %-6s | %-6s | %-7s | %-5s |\n",
        sessions, target_tps, duration, committed, w_tps, median, p95, p99, p999, mx, retries, pass
    }
  ' "$log"
done
