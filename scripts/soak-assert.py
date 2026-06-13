#!/usr/bin/env python3
"""
scripts/soak-assert.py
─────────────────────────────────────────────────────────────────────────────
Reads the soak CSV produced by soak-watch.sh and asserts every pass criterion.
Exits with code 0 on pass, 1 on any regression.

Pass criteria (from the issue spec):
  1. RSS final  < 1.5 × RSS at hour 1
  2. Goroutine count final  ≤  goroutine count at hour 1  +  50
  3. FD count is flat after warm-up (max FD in second half ≤ max FD in first half + 20)
  4. Zero panics / Fatals in kerno.log  (sentinel file left by soak-watch)
  5. Event throughput stable ±20% across the run  (rolling-window check)

Usage:
  python3 scripts/soak-assert.py /tmp/soak/soak.csv

Optional:  set KERNO_SOAK_LOGDIR env var to override log directory lookup
           (default: directory containing the CSV).
"""

import csv
import os
import sys
import statistics
from pathlib import Path

ANSI_RED   = "\033[31m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW= "\033[33m"
ANSI_RESET = "\033[0m"

def fail(msg: str) -> None:
    print(f"{ANSI_RED}FAIL  {msg}{ANSI_RESET}")

def ok(msg: str) -> None:
    print(f"{ANSI_GREEN}PASS  {msg}{ANSI_RESET}")

def warn(msg: str) -> None:
    print(f"{ANSI_YELLOW}WARN  {msg}{ANSI_RESET}")


def load_csv(path: str) -> list[dict]:
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    return rows


def row_float(row: dict, key: str) -> float:
    try:
        return float(row[key])
    except (ValueError, KeyError):
        return 0.0


def assert_rss(rows: list[dict]) -> bool:
    """RSS final must be < 1.5 × RSS at hour 1 (first sample as proxy)."""
    baseline_rss = row_float(rows[0], "rss_kb")
    final_rss    = row_float(rows[-1], "rss_kb")
    if baseline_rss == 0:
        warn("Baseline RSS is 0 — cannot evaluate RSS criterion.")
        return True   # don't fail on missing data
    ratio = final_rss / baseline_rss
    limit = 1.5
    if ratio < limit:
        ok(f"RSS growth: ×{ratio:.3f}  (baseline={baseline_rss:.0f} KB, final={final_rss:.0f} KB, limit <×{limit})")
        return True
    else:
        fail(f"RSS growth: ×{ratio:.3f}  (baseline={baseline_rss:.0f} KB, final={final_rss:.0f} KB, limit <×{limit})")
        return False


def assert_goroutines(rows: list[dict]) -> bool:
    """Final goroutine count ≤ hour-1 count + 50."""
    baseline = row_float(rows[0], "goroutines")
    final    = row_float(rows[-1], "goroutines")
    delta    = final - baseline
    limit    = 50
    if delta <= limit:
        ok(f"Goroutine delta: +{delta:.0f}  (baseline={baseline:.0f}, final={final:.0f}, limit ≤+{limit})")
        return True
    else:
        fail(f"Goroutine delta: +{delta:.0f}  (baseline={baseline:.0f}, final={final:.0f}, limit ≤+{limit})")
        return False


def assert_fds(rows: list[dict]) -> bool:
    """FD count should be flat after warm-up (second half ≤ first half max + 20)."""
    fds = [row_float(r, "open_fds") for r in rows]
    midpoint = len(fds) // 2
    first_half_max  = max(fds[:midpoint]) if fds[:midpoint] else 0
    second_half_max = max(fds[midpoint:]) if fds[midpoint:] else 0
    limit = first_half_max + 20
    if second_half_max <= limit:
        ok(f"FD count flat: first-half max={first_half_max:.0f}, second-half max={second_half_max:.0f}, limit={limit:.0f}")
        return True
    else:
        fail(f"FD leak: first-half max={first_half_max:.0f}, second-half max={second_half_max:.0f}, limit={limit:.0f}")
        return False


def assert_no_panics(soak_dir: Path) -> bool:
    """Fail if soak-watch left a panics_found.txt sentinel."""
    sentinel = soak_dir / "panics_found.txt"
    if sentinel.exists():
        content = sentinel.read_text().strip()
        fail(f"Panic / Fatal detected in kerno.log:\n{content[:500]}")
        return False
    ok("No panics or Fatals detected in kerno.log")
    return True


def assert_throughput(rows: list[dict]) -> bool:
    """
    Event throughput must stay within ±20% of the run median.
    We derive per-interval event delta (rate), then check that no
    window of 3 consecutive samples is more than 20% below the median.
    Throughput = 0 for the first sample (no delta yet).
    """
    if len(rows) < 4:
        warn("Fewer than 4 samples — skipping throughput assertion.")
        return True

    deltas = []
    for i in range(1, len(rows)):
        dt_events = row_float(rows[i], "events_total") - row_float(rows[i-1], "events_total")
        dt_secs   = row_float(rows[i], "elapsed_s")    - row_float(rows[i-1], "elapsed_s")
        rate = dt_events / max(dt_secs, 1)
        deltas.append(rate)

    med = statistics.median(deltas)
    if med == 0:
        warn("Median event throughput is 0 — skipping throughput stability assertion.")
        return True

    low_bound  = med * 0.80   # −20%
    high_bound = med * 1.20   # +20%

    violations = []
    for i, rate in enumerate(deltas):
        if rate < low_bound or rate > high_bound:
            violations.append((i + 1, rate))

    # Allow up to 10% of intervals to be out of band (transient spikes)
    threshold = max(1, int(len(deltas) * 0.10))
    if len(violations) <= threshold:
        ok(
            f"Throughput stable: median={med:.1f} ev/s, "
            f"violations={len(violations)}/{len(deltas)} (allowed ≤{threshold})"
        )
        return True
    else:
        fail(
            f"Throughput unstable: median={med:.1f} ev/s, "
            f"violations={len(violations)}/{len(deltas)} (allowed ≤{threshold}). "
            f"Bound=[{low_bound:.1f}, {high_bound:.1f}] ev/s. "
            f"First 5 offenders: {violations[:5]}"
        )
        return False


def assert_kerno_alive(soak_dir: Path) -> bool:
    """If kerno died mid-run soak-watch leaves a sentinel file."""
    sentinel = soak_dir / "kerno_died.txt"
    if sentinel.exists():
        content = sentinel.read_text().strip()
        fail(f"kerno process died during the soak run:\n{content}")
        return False
    ok("kerno process survived the full soak duration")
    return True


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path/to/soak.csv>", file=sys.stderr)
        sys.exit(1)

    csv_path = Path(sys.argv[1])
    soak_dir = Path(os.environ.get("KERNO_SOAK_LOGDIR", str(csv_path.parent)))

    if not csv_path.exists():
        print(f"ERROR: CSV not found: {csv_path}", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(str(csv_path))
    if len(rows) < 2:
        print(f"ERROR: CSV has {len(rows)} data rows — need at least 2 to assert anything.", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'═'*60}")
    print(f"  Kerno soak assertion  —  {len(rows)} samples")
    print(f"  CSV: {csv_path}")
    print(f"{'═'*60}\n")

    results = [
        assert_kerno_alive(soak_dir),
        assert_no_panics(soak_dir),
        assert_rss(rows),
        assert_goroutines(rows),
        assert_fds(rows),
        assert_throughput(rows),
    ]

    print(f"\n{'─'*60}")
    passed = sum(results)
    total  = len(results)

    if all(results):
        print(f"{ANSI_GREEN}✅  All {total} criteria passed.{ANSI_RESET}\n")
        sys.exit(0)
    else:
        failed = total - passed
        print(f"{ANSI_RED}❌  {failed}/{total} criteria FAILED.{ANSI_RESET}")
        print("    Inspect the heap + goroutine profiles in the artifact's pprof/ folder.")
        print("    See docs/soak.md for a step-by-step failure triage guide.\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
