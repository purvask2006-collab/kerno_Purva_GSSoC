#!/usr/bin/env bash
# scripts/soak-watch.sh
# ─────────────────────────────────────────────────────────────────────────────
# Soak-watch — continuous metric sampler for a running kerno process.
#
# Usage (CI — called from soak.yml):
#   bash scripts/soak-watch.sh \
#       --pid 12345 --duration 86400 --interval 300 \
#       --pprof-port 6060 --metrics-port 9091 \
#       --outdir /tmp/soak
#
# Usage (local quick smoke test — 10 minutes, 60-second intervals):
#   bash scripts/soak-watch.sh \
#       --pid $(pgrep kerno) --duration 600 --interval 60
#
# Collected per interval:
#   RSS (KB)          /proc/<pid>/status
#   Goroutine count   GET http://localhost:<pprof>/debug/pprof/goroutine?debug=1
#   Open FDs          /proc/<pid>/fd
#   Pinned BPF maps   bpftool map list
#   Events total      GET http://localhost:<metrics>/metrics  (kerno_events_total)
#   Doctor p99 ms     GET http://localhost:<metrics>/metrics  (kerno_doctor_cycle_duration_seconds)
#
# pprof snapshots are saved at hours 1, 6, 12, 18, 24 (and pro-rated for
# shorter runs).
#
# All output lands in --outdir (default /tmp/soak).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
PID=""
DURATION=86400
INTERVAL=300
PPROF_PORT=6060
METRICS_PORT=9091
OUTDIR="/tmp/soak"

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)           PID="$2";           shift 2 ;;
    --duration)      DURATION="$2";      shift 2 ;;
    --interval)      INTERVAL="$2";      shift 2 ;;
    --pprof-port)    PPROF_PORT="$2";    shift 2 ;;
    --metrics-port)  METRICS_PORT="$2";  shift 2 ;;
    --outdir)        OUTDIR="$2";        shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PID" ]]; then
  echo "ERROR: --pid is required" >&2
  exit 1
fi

# ── setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR/pprof"
CSV="$OUTDIR/soak.csv"

# Write CSV header only if file does not already exist or is empty
if [[ ! -s "$CSV" ]]; then
  echo "timestamp_utc,elapsed_s,rss_kb,goroutines,open_fds,pinned_bpf_maps,events_total,doctor_p99_ms" \
    > "$CSV"
fi

PPROF_BASE="http://127.0.0.1:${PPROF_PORT}/debug/pprof"
METRICS_URL="http://127.0.0.1:${METRICS_PORT}/metrics"

# Hours at which to save full pprof snapshots.
# We scale them proportionally so a 600-s smoke run still gets a snapshot.
SNAPSHOT_FRACTIONS=(0.042 0.25 0.5 0.75 1.0)   # hour 1,6,12,18,24 ÷ 24

# ── helpers ───────────────────────────────────────────────────────────────────
log() { echo "[soak-watch $(date -u +%H:%M:%S)] $*"; }

rss_kb() {
  # VmRSS line from /proc/<pid>/status
  awk '/^VmRSS:/{print $2}' "/proc/${PID}/status" 2>/dev/null || echo 0
}

goroutine_count() {
  # The goroutine pprof endpoint's first line contains the count when debug=1
  local raw
  raw=$(curl -sf "${PPROF_BASE}/goroutine?debug=1" 2>/dev/null | head -1) || true
  # Line looks like: "goroutine profile: total 47"
  echo "${raw##*total }" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo 0
}

open_fds() {
  ls "/proc/${PID}/fd" 2>/dev/null | wc -l || echo 0
}

pinned_bpf_maps() {
  # bpftool may require root; if unavailable, return 0 gracefully.
  bpftool map list 2>/dev/null | grep -c "^[0-9]" || echo 0
}

events_total() {
  # Sum all kerno_events_total counter values (one per collector label).
  curl -sf "$METRICS_URL" 2>/dev/null \
    | awk '/^kerno_events_total/{sum += $2} END{printf "%.0f", sum}' \
    || echo 0
}

doctor_p99_ms() {
  # kerno_doctor_cycle_duration_seconds{quantile="0.99"}
  local val
  val=$(curl -sf "$METRICS_URL" 2>/dev/null \
    | awk '/kerno_doctor_cycle_duration_seconds{.*quantile="0\.99"/{print $2}' \
    | head -1) || true
  if [[ -n "$val" && "$val" =~ ^[0-9.e+\-]+$ ]]; then
    # Convert seconds → milliseconds
    awk "BEGIN{printf \"%.2f\", $val * 1000}"
  else
    echo 0
  fi
}

save_pprof_snapshot() {
  local tag="$1"
  local base="${OUTDIR}/pprof/${tag}"
  log "Saving pprof snapshot: $tag"
  curl -sf "${PPROF_BASE}/heap"      -o "${base}_heap.pb.gz"      2>/dev/null || true
  curl -sf "${PPROF_BASE}/goroutine?debug=2" -o "${base}_goroutines.txt" 2>/dev/null || true
  curl -sf "${PPROF_BASE}/allocs"    -o "${base}_allocs.pb.gz"    2>/dev/null || true
  curl -sf "${PPROF_BASE}/block"     -o "${base}_block.pb.gz"     2>/dev/null || true
  log "Snapshot saved → ${base}_*"
}

# ── main loop ─────────────────────────────────────────────────────────────────
START_TS=$(date +%s)
END_TS=$(( START_TS + DURATION ))
TICK=0
NEXT_SNAPSHOT_IDX=0

log "Starting soak-watch"
log "  PID=$PID  duration=${DURATION}s  interval=${INTERVAL}s"
log "  pprof=${PPROF_BASE}  metrics=${METRICS_URL}"
log "  output=$OUTDIR"

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TS ))

  # ── check kerno is still alive ────────────────────────────────────────────
  if ! kill -0 "$PID" 2>/dev/null; then
    log "ERROR: kerno process $PID is no longer running after ${ELAPSED}s"
    echo "KERNO_DIED_AT_ELAPSED=${ELAPSED}" > "$OUTDIR/kerno_died.txt"
    exit 1
  fi

  # ── sample ────────────────────────────────────────────────────────────────
  TS_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  RSS=$(rss_kb)
  GOR=$(goroutine_count)
  FDS=$(open_fds)
  BPF=$(pinned_bpf_maps)
  EVT=$(events_total)
  P99=$(doctor_p99_ms)

  # ── append to CSV ─────────────────────────────────────────────────────────
  echo "${TS_UTC},${ELAPSED},${RSS},${GOR},${FDS},${BPF},${EVT},${P99}" >> "$CSV"
  log "elapsed=${ELAPSED}s rss=${RSS}KB gor=${GOR} fds=${FDS} bpf=${BPF} events=${EVT} p99=${P99}ms"

  # ── scheduled pprof snapshots (at fractional marks of the total run) ──────
  if [[ $NEXT_SNAPSHOT_IDX -lt ${#SNAPSHOT_FRACTIONS[@]} ]]; then
    FRAC="${SNAPSHOT_FRACTIONS[$NEXT_SNAPSHOT_IDX]}"
    THRESHOLD=$(awk "BEGIN{printf \"%d\", $FRAC * $DURATION}")
    if [[ $ELAPSED -ge $THRESHOLD ]]; then
      LABEL=$(printf "t%05ds" "$ELAPSED")
      save_pprof_snapshot "$LABEL"
      NEXT_SNAPSHOT_IDX=$(( NEXT_SNAPSHOT_IDX + 1 ))
    fi
  fi

  # ── check for panic / fatal lines in kerno.log ────────────────────────────
  if grep -qiE "^(panic:|fatal |FATAL )" "$OUTDIR/kerno.log" 2>/dev/null; then
    log "ERROR: panic or fatal found in kerno.log"
    grep -iE "^(panic:|fatal |FATAL )" "$OUTDIR/kerno.log" | head -20 \
      > "$OUTDIR/panics_found.txt"
    # Don't exit here — let the run finish and let assert.py catch it.
  fi

  # ── are we done? ──────────────────────────────────────────────────────────
  if [[ $NOW -ge $END_TS ]]; then
    log "Soak duration reached after ${ELAPSED}s. Saving final snapshot."
    save_pprof_snapshot "final"
    break
  fi

  TICK=$(( TICK + 1 ))
  sleep "$INTERVAL"
done

log "soak-watch complete. Rows written: $(( $(wc -l < "$CSV") - 1 ))"
log "Artifact directory: $OUTDIR"
