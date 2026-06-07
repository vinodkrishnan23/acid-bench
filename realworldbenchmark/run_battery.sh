#!/usr/bin/env bash
# run_battery.sh — N runs per variant, report p99 distribution + side-by-side stats.
# All standard knobs are inherited from env.sh / env vars: SESSIONS, TARGET_TPS, DURATION.
#
# Usage:
#   ./run_battery.sh                          # default 5 runs, both variants
#   ./run_battery.sh 10                       # 10 runs each
#   SESSIONS=4000 TARGET_TPS=6000 DURATION=300 ./run_battery.sh 7
#   VARIANTS=perop ./run_battery.sh 5         # only per-op
#   VARIANTS=clientbulk ./run_battery.sh 5    # only client-bulk
#
# Outputs:
#   - live bench output for each run (tee'd to disk)
#   - per-variant per-run table (TPS / p50 / p95 / p99 / p99.9 / max / retry% / pass)
#   - per-variant p99 distribution (n / min / median / avg / max / stddev)
#   - side-by-side comparison summary
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

RUNS="${1:-${RUNS:-5}}"
VARIANTS="${VARIANTS:-perop clientbulk}"

TS=$(date +%Y%m%d_%H%M%S)
BATTERY_DIR="$RESULTS_DIR/battery_${TS}"
mkdir -p "$BATTERY_DIR"

echo "============================================================"
echo " Battery: ${RUNS} runs per variant"
echo " Workload: SESSIONS=${SESSIONS}  TARGET_TPS=${TARGET_TPS}  DURATION=${DURATION}s"
echo " Variants: ${VARIANTS}"
echo " Logs:     ${BATTERY_DIR}"
echo "============================================================"

for variant in $VARIANTS; do
  case "$variant" in
    perop)      BIN="$GO_DIR/perop_bin" ;;
    clientbulk) BIN="$GO_DIR/clientbulk_bin" ;;
    *) echo "skipping unknown variant: $variant"; continue ;;
  esac

  echo ""
  echo "============================================================"
  echo " Variant: ${variant}  (${RUNS} consecutive runs)"
  echo "============================================================"

  for i in $(seq 1 "$RUNS"); do
    log="$BATTERY_DIR/${variant}_run_$(printf '%02d' "$i").log"
    echo ""
    echo "--- ${variant} run ${i}/${RUNS} → ${log} ---"
    "$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION" | tee "$log"
  done
done

# --- aggregation / reporting ---

parse_one() {
  awk '
    /windowed TPS:/ {
      for (i=1; i<=NF; i++) if ($i == "TPS:") tps = $(i+1)
    }
    /^  retries:/ {
      retries = $2
      # "(0.04%" → "0.04"
      gsub(/[()%]/, "", $3); retry_pct = $3
    }
    /^  median/ {
      for (i=1; i<=NF; i++) {
        if      ($i == "median") median = $(i+1)
        else if ($i == "p95")    p95    = $(i+1)
        else if ($i == "p99")    p99    = $(i+1)
        else if ($i == "p99.9")  p999   = $(i+1)
        else if ($i == "max")    mx     = $(i+1)
      }
    }
    /^  PASS/ { pass = ($NF == "true") ? "PASS" : "FAIL" }
    END {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        tps, median, p95, p99, p999, mx, retry_pct, pass
    }
  ' "$1"
}

print_variant_block() {
  local variant=$1
  echo ""
  echo "=== ${variant} — per-run table ==="
  printf "| %-3s | %-7s | %-6s | %-6s | %-6s | %-8s | %-9s | %-6s | %-4s |\n" \
    "Run" "TPS" "p50" "p95" "p99" "p99.9" "Max" "Retry%" "Pass"
  echo   "|-----|---------|--------|--------|--------|----------|-----------|--------|------|"

  local i=0
  for log in "$BATTERY_DIR/${variant}"_run_*.log; do
    [ -f "$log" ] || continue
    i=$((i + 1))
    fields=$(parse_one "$log")
    IFS=$'\t' read -r tps median p95 p99 p999 mx retry_pct pass <<< "$fields"
    printf "| %-3d | %-7s | %-6s | %-6s | %-6s | %-8s | %-9s | %-6s | %-4s |\n" \
      "$i" "$tps" "$median" "$p95" "$p99" "$p999" "$mx" "$retry_pct" "$pass"
  done

  echo ""
  echo "=== ${variant} — p99 distribution ==="
  for log in "$BATTERY_DIR/${variant}"_run_*.log; do
    [ -f "$log" ] || continue
    parse_one "$log" | awk -F'\t' '{print $4}'
  done | awk -v variant="$variant" '
    {
      vals[NR] = $1 + 0
      sum += $1
      if (NR == 1 || $1+0 < min) min = $1+0
      if (NR == 1 || $1+0 > max) max = $1+0
    }
    END {
      n = NR
      if (n == 0) { print "  (no data)"; exit }
      avg = sum / n
      # sort for median + stddev
      isort(vals, n)
      median = (n % 2 == 1) ? vals[(n+1)/2] : (vals[n/2] + vals[n/2+1]) / 2
      sd_sum = 0
      for (i=1; i<=n; i++) sd_sum += (vals[i] - avg) * (vals[i] - avg)
      sd = (n > 1) ? sqrt(sd_sum / (n - 1)) : 0
      printf "  n=%d  min=%.2f  median=%.2f  avg=%.2f  max=%.2f  stddev=%.2f  range=%.2f\n",
        n, min, median, avg, max, sd, max - min
    }
    function isort(a, n,   i, j, t) {
      for (i = 2; i <= n; i++) {
        t = a[i]; j = i - 1
        while (j >= 1 && a[j] > t) { a[j+1] = a[j]; j-- }
        a[j+1] = t
      }
    }
  '
}

print_side_by_side() {
  echo ""
  echo "============================================================"
  echo "Side-by-side p99 summary"
  echo "============================================================"
  printf "| %-12s | %-6s | %-7s | %-7s | %-7s | %-7s | %-7s | %-7s |\n" \
    "Variant" "n" "min" "median" "avg" "max" "stddev" "range"
  echo  "|--------------|--------|---------|---------|---------|---------|---------|---------|"

  for variant in $VARIANTS; do
    case "$variant" in
      perop|clientbulk) ;;
      *) continue ;;
    esac
    p99_values=""
    for log in "$BATTERY_DIR/${variant}"_run_*.log; do
      [ -f "$log" ] || continue
      p99=$(parse_one "$log" | awk -F'\t' '{print $4}')
      p99_values+="${p99}"$'\n'
    done
    stats=$(echo -n "$p99_values" | awk '
      NF > 0 {
        vals[NR] = $1 + 0
        sum += $1
        if (NR == 1 || $1+0 < min) min = $1+0
        if (NR == 1 || $1+0 > max) max = $1+0
      }
      END {
        n = NR
        if (n == 0) { print "0\t0\t0\t0\t0\t0\t0"; exit }
        avg = sum / n
        for (i=2; i<=n; i++) { t = vals[i]; j = i-1; while (j >= 1 && vals[j] > t) { vals[j+1] = vals[j]; j-- } vals[j+1] = t }
        median = (n % 2 == 1) ? vals[(n+1)/2] : (vals[n/2] + vals[n/2+1]) / 2
        sd_sum = 0
        for (i=1; i<=n; i++) sd_sum += (vals[i] - avg) * (vals[i] - avg)
        sd = (n > 1) ? sqrt(sd_sum / (n - 1)) : 0
        printf "%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f", n, min, median, avg, max, sd, max - min
      }
    ')
    IFS=$'\t' read -r n mn med avg mx sd rng <<< "$stats"
    printf "| %-12s | %-6s | %-7s | %-7s | %-7s | %-7s | %-7s | %-7s |\n" \
      "$variant" "$n" "$mn" "$med" "$avg" "$mx" "$sd" "$rng"
  done
  echo ""
  echo "All log files: $BATTERY_DIR"
}

echo ""
echo "============================================================"
echo " Battery summary"
echo "============================================================"

for variant in $VARIANTS; do
  case "$variant" in
    perop|clientbulk) print_variant_block "$variant" ;;
  esac
done

print_side_by_side
