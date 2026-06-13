# Kerno 24-hour Soak Test

> **One-line summary:** a nightly CI job that runs `kerno` under continuous
> chaos load for 24 hours and asserts that RSS, goroutine count, file
> descriptors, BPF maps, and event throughput all stay within defined bounds.

---

## Table of contents

1. [Why we soak test](#why-we-soak-test)
2. [What gets measured](#what-gets-measured)
3. [Pass criteria](#pass-criteria)
4. [Running the soak locally](#running-the-soak-locally)
5. [Interpreting a failed run](#interpreting-a-failed-run)
6. [CI workflow details](#ci-workflow-details)
7. [Badge](#badge)
8. [FAQ](#faq)

---

## Why we soak test

Unit tests and 5-minute integration tests cannot catch:

| Failure mode | Why short tests miss it |
|---|---|
| Slow goroutine leak | The spawn rate barely exceeds cleanup; only visible after thousands of cycles |
| File-descriptor / BPF-map accumulation | Each handle leak is tiny; only measurable over hours |
| Histogram key-cardinality cliff | A label-cardinality regime that was never exercised at short timescales |
| Kernel-side BPF map fragmentation | Manifests under sustained allocation churn, not bursts |

The soak test finds these in CI so customers do not find them in production.

---

## What gets measured

Every `--interval` seconds (default 5 minutes) `scripts/soak-watch.sh` records:

| Column in `soak.csv` | Source |
|---|---|
| `timestamp_utc` | `date -u` |
| `elapsed_s` | Seconds since soak start |
| `rss_kb` | `VmRSS` from `/proc/<pid>/status` |
| `goroutines` | `GET /debug/pprof/goroutine?debug=1` |
| `open_fds` | `ls /proc/<pid>/fd \| wc -l` |
| `pinned_bpf_maps` | `bpftool map list \| grep -c …` |
| `events_total` | `kerno_events_total` counter from `/metrics` |
| `doctor_p99_ms` | `kerno_doctor_cycle_duration_seconds{quantile="0.99"}` × 1000 |

Full **pprof snapshots** (heap + goroutine + allocs + block) are saved at
approximately hours 1, 6, 12, 18, and 24 into `$OUTDIR/pprof/`.

---

## Pass criteria

`scripts/soak-assert.py` enforces these at the end of every run:

| # | Criterion | Hard limit |
|---|---|---|
| 1 | `kerno` process survived | must not have crashed |
| 2 | No panics or Fatals in `kerno.log` | zero occurrences |
| 3 | RSS growth | final RSS < 1.5 × hour-1 RSS |
| 4 | Goroutine delta | final goroutines ≤ hour-1 goroutines + 50 |
| 5 | FD count flatness | second-half max ≤ first-half max + 20 |
| 6 | Event throughput stability | ≤10% of intervals may deviate > ±20% from the median |

---

## Running the soak locally

### Prerequisites

Make sure you have:

- Go toolchain (same version as `go.mod`)
- `bpftool` (`sudo apt install linux-tools-$(uname -r)` on Ubuntu)
- `libcap2-bin` (for `setcap`)
- Python 3.8+

### Step-by-step (PowerShell on Windows with WSL2, or native Linux)

> All commands below are bash. On Windows, open a WSL2 terminal
> (`wsl` from PowerShell) and run them there. Kerno requires a real
> Linux kernel with eBPF support — Windows-native PowerShell cannot run it.

**Step 1 — Clone and build**

```bash
git clone https://github.com/optiqor/kerno.git
cd kerno
make build
```

**Step 2 — Grant BPF capabilities so you do not need `sudo` every run**

```bash
sudo setcap cap_bpf,cap_sys_admin,cap_net_admin+eip ./kerno
```

**Step 3 — Start kerno in the background**

```bash
./kerno start \
  --pprof-addr   127.0.0.1:6060 \
  --metrics-addr 127.0.0.1:9091 \
  > /tmp/kerno.log 2>&1 &

KERNO_PID=$!
echo "kerno PID = $KERNO_PID"
```

**Step 4 — Wait for the pprof endpoint to be ready**

```bash
echo "Waiting for pprof..."
until curl -sf http://127.0.0.1:6060/debug/pprof/ > /dev/null; do
  sleep 1
done
echo "pprof is up"
```

**Step 5 — Start chaos load (10 minutes for a smoke test)**

```bash
./kerno chaos \
  --induce cascade \
  --duration 600s \
  > /tmp/chaos.log 2>&1 &

CHAOS_PID=$!
echo "chaos PID = $CHAOS_PID"
```

**Step 6 — Run soak-watch (10 minutes, 60-second intervals)**

```bash
mkdir -p /tmp/soak

bash scripts/soak-watch.sh \
  --pid          "$KERNO_PID" \
  --duration     600 \
  --interval     60 \
  --pprof-port   6060 \
  --metrics-port 9091 \
  --outdir       /tmp/soak
```

You will see a log line every 60 seconds while this runs.

**Step 7 — Stop kerno and chaos after the soak completes**

```bash
# Copy logs into the soak directory so assert.py can find them
cp /tmp/kerno.log /tmp/soak/kerno.log

kill "$KERNO_PID" "$CHAOS_PID" 2>/dev/null || true
```

**Step 8 — Assert pass criteria**

```bash
python3 scripts/soak-assert.py /tmp/soak/soak.csv
```

A passing run prints green `PASS` lines. A failing run prints red `FAIL` lines
and exits with code 1.

**Step 9 — Browse the evidence**

```bash
ls /tmp/soak/
# soak.csv         — all metric samples
# pprof/           — heap + goroutine snapshots
# kerno.log        — daemon output
# chaos.log        — chaos output
```

To view the CSV in a human-friendly table:

```bash
column -t -s, /tmp/soak/soak.csv | less -S
```

---

## Interpreting a failed run

Download the artifact from the failed GitHub Actions run. It contains:

```
soak-report-<run_id>/
  soak.csv
  kerno.log
  chaos.log
  panics_found.txt      # only present if a panic was detected
  kerno_died.txt        # only present if kerno crashed
  pprof/
    t00360s_heap.pb.gz      # hour-1 snapshot
    t03600s_heap.pb.gz      # hour-6
    ...
    final_heap.pb.gz
    final_goroutines.txt
```

### Criterion 1 or 2 — kerno died / panic

```bash
cat kerno.log | grep -iE "^(panic:|fatal )" | head -30
cat panics_found.txt
```

Look for the goroutine stack that triggered the panic. The `final_goroutines.txt`
file shows all goroutines at the time of the final snapshot — useful to see
which goroutine was blocked.

### Criterion 3 — RSS growth (memory leak)

Compare the first and last heap profiles:

```bash
go tool pprof -http=:8080 \
  pprof/t00360s_heap.pb.gz \
  pprof/final_heap.pb.gz
```

In the web UI, use **Diff** → **inuse_space** to see which allocation site grew.
Look for allocations in ring buffer readers, BPF map iteration code, or
histogram label maps.

### Criterion 4 — Goroutine leak

```bash
diff pprof/t00360s_goroutines.txt pprof/final_goroutines.txt | head -80
```

Each goroutine block starts with `goroutine N [state]:`. New goroutine stacks
in the diff are the leak candidates. Common causes:

- A `go func()` in the hot path that blocks on a channel nobody drains
- A ticker whose `Stop()` is never called

### Criterion 5 — FD leak

```bash
awk -F, 'NR>1{print $3, $6}' /tmp/soak/soak.csv | \
  awk '{print NR, $2}' | gnuplot -p -e "
    set xlabel 'Sample'; set ylabel 'Open FDs';
    plot '-' u 1:2 w lp title 'FDs'
  "
```

(Or just inspect the `open_fds` column in the CSV.) A steady upward slope
points to a file or socket that is opened but never closed. Use `lsof -p <pid>`
on a live run to see which path is accumulating.

### Criterion 6 — Throughput instability

Plot `events_total` deltas across time to spot the drop windows:

```bash
python3 - <<'EOF'
import csv, sys
rows = list(csv.DictReader(open("/tmp/soak/soak.csv")))
for i in range(1, len(rows)):
    dt = float(rows[i]['events_total']) - float(rows[i-1]['events_total'])
    el = rows[i]['elapsed_s']
    print(f"{el}s  {dt:.0f} ev/interval")
EOF
```

Sustained drops may indicate the chaos `cascade` scenario is overwhelming
the ring buffer and events are being dropped. Consider raising
`--ringbuf-size` or adding backpressure handling in the collector.

---

## CI workflow details

File: `.github/workflows/soak.yml`

| Property | Value |
|---|---|
| Trigger | Nightly at 02:00 UTC + `workflow_dispatch` |
| Runner | `ubuntu-22.04` (full kernel, BPF support) |
| Wall-clock time | 24 h + ~30 min build/assert overhead |
| GitHub Actions minutes consumed | ~1 470 min/run |
| Free-tier budget | 2 000 min/month → one daily run fits |
| Artifact retention | 30 days |
| Failure action | Exits non-zero → branch protection blocks merge |

The workflow accepts two `workflow_dispatch` inputs so engineers can trigger
a shorter run without editing the file:

```
duration_seconds  (default 86400)
interval_seconds  (default 300)
```

---

## Badge

Add to `README.md`:

```markdown
[![Soak](https://github.com/optiqor/kerno/actions/workflows/soak.yml/badge.svg)](https://github.com/optiqor/kerno/actions/workflows/soak.yml)
```

---

## FAQ

**Q: The soak uses ~1 470 Actions minutes per run. Does this exceed the free tier?**

GitHub's free tier provides 2 000 minutes per month for public repositories
(unlimited) and for private repos on the Free plan. One 24-hour run on
`ubuntu-22.04` costs 1 × 1 440 min ≈ 1 440 min (Linux runners are billed at 1×).
That leaves 560 min buffer for re-runs and other workflows.

**Q: Can I run it on macOS or Windows?**

No. `kerno` requires a Linux kernel with eBPF support. On macOS or Windows,
use WSL2 (Ubuntu 22.04) and follow the local guide above.

**Q: How do I shorten the soak for a fast sanity check?**

```bash
bash scripts/soak-watch.sh \
  --pid $(pgrep kerno) \
  --duration 600 \
  --interval 60
```

This runs for 10 minutes at 60-second intervals — enough to verify the
pipeline works and catch obvious crashes, but not long enough to catch slow
leaks.

**Q: Should throughput use a rolling average or a hard floor?**

We use a rolling-rate approach: compute events per second for each interval,
take the run median, and fail if more than 10% of intervals deviate by more
than ±20% from that median. This tolerates transient spikes from the
`cascade` chaos mode while still catching sustained throughput drops. A hard
floor would be too brittle because event throughput varies with the chaos
scenario intensity.

**Q: How do I re-run just the assertion step on a downloaded artifact?**

```bash
# Unzip the artifact into /tmp/soak-report/
python3 scripts/soak-assert.py /tmp/soak-report/soak.csv
```

Set `KERNO_SOAK_LOGDIR=/tmp/soak-report` if the CSV lives in a different
directory than the log files.
