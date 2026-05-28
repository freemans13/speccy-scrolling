#!/usr/bin/env python3
r"""test_yellow_band.py — verify the YELLOW profile band (do_swap_part_b)
stays under budget. With the patch-only renderer:
  - Non-swap frames: ~256 T (just the marker overhead).
  - Swap+1 frames: do_swap_part_b runs (~15 k T).

Pre-patch-only the worst frame could reach ~21 k T (full cps_emit_body_bands
rebuild). Phase 6 target: keep worst-case YELLOW under WORST_LIMIT_T so the
budget reduction sticks across future changes.
"""
from __future__ import annotations
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator

TEST_FRAMES = 1500
COLOR_YELLOW = 6
COLOR_RED    = 2
WORST_LIMIT_T = 16500   # do_swap_part_b ~15k T + headroom


def main():
    mem, pc, sp, s = load_sna("build/main.sna")
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    out_log = []
    print(f"test_yellow_band: running {TEST_FRAMES} frames, measuring YELLOW→next markers")
    run_frames(sim, TEST_FRAMES, out_log)

    frames = {}
    for t, a, fr in out_log:
        frames.setdefault(fr, []).append((t, a & 7))

    durations = []
    for fr, events in frames.items():
        ys = [t for t, c in events if c == COLOR_YELLOW]
        if not ys: continue
        yt = ys[0]
        nxt = next((t for t, c in events if t > yt and c != COLOR_YELLOW), None)
        if nxt is None: continue
        durations.append((fr, nxt - yt))

    if not durations:
        print("FAIL: no YELLOW markers captured")
        return 1
    worst_fr, worst_t = max(durations, key=lambda x: x[1])
    med_t = sorted(d for _, d in durations)[len(durations) // 2]
    print(f"  worst frame {worst_fr}: {worst_t} T")
    print(f"  median: {med_t} T (non-swap frames)")
    n_swap = sum(1 for _, d in durations if d > 5000)
    print(f"  swap frames (>5k T): {n_swap} / {len(durations)}")

    if worst_t > WORST_LIMIT_T:
        print(f"FAIL: worst YELLOW {worst_t} T > {WORST_LIMIT_T} T limit")
        return 1
    print(f"PASS: worst YELLOW {worst_t} T within {WORST_LIMIT_T} T limit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
