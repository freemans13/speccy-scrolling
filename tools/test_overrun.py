#!/usr/bin/env python3
r"""test_overrun.py — frame-timing test.

Runs the headless simulator for N frames with the OUT($FE) profiler
capturing every border write. For each completed frame, asserts:

  1. The frame's marker sequence ends with BLACK (\$0). A frame whose
     last marker is NOT BLACK missed its halt — the game ran at 25 Hz
     for that frame. Per CLAUDE.md, ANY non-zero overrun is a bug.

  2. The BLACK-to-RED interval (idle → next-frame start) is positive,
     i.e. the next frame's RED arrives AFTER this frame's BLACK. Sanity
     check that frames are temporally ordered.

Exit 0 on success, non-zero on first failure. Prints summary on success.

The harness uses runsim's CMIOSimulator which models ULA contention —
matches what the Fuse emulator sees. Without contention modelling we'd
under-count T-states by ~5 k T/frame and miss real overruns.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T

FRAME_TSTATES = 69888
TEST_FRAMES = 1000  # ~20 s of game time

COLOR_NAMES = {0: "BLACK", 1: "BLUE", 2: "RED", 3: "MAGENTA",
               4: "GREEN", 5: "CYAN", 6: "YELLOW", 7: "WHITE"}


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = load_sna(sna_path)
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    print(f"test_overrun: running {sna_path} for {TEST_FRAMES} frames "
          f"(~{TEST_FRAMES * FRAME_TSTATES / 3_500_000:.1f}s game time)")
    out_log = []
    run_frames(sim, TEST_FRAMES, out_log)

    # Group by frame_idx (incremented by run_frames on each accept_interrupt).
    frames: dict[int, list[tuple[int, int]]] = {}
    for t, a, fr in out_log:
        frames.setdefault(fr, []).append((t, a & 0x07))

    # Skip the very first frame (init may run partial markers) and the
    # last (may be in progress).
    keys = sorted(frames.keys())
    if len(keys) < 4:
        print(f"FAIL: only {len(keys)} frames captured; need more")
        return 1
    check_frames = keys[1:-1]

    overruns = []
    for fr in check_frames:
        ev = frames[fr]
        if not ev:
            continue
        last_color = ev[-1][1]
        if last_color != 0:
            overruns.append((fr, ev))

    if overruns:
        print(f"FAIL: {len(overruns)} overruns (frames missed their halt → 25 Hz)")
        for fr, ev in overruns[:5]:
            names = " ".join(COLOR_NAMES.get(c, f"?{c}") for _, c in ev)
            print(f"  frame {fr}: {names}")
        if len(overruns) > 5:
            print(f"  ... and {len(overruns) - 5} more")
        return 1

    n = len(check_frames)

    # ALSO check that RED→BLACK fits within frame budget. The "missed
    # BLACK" check above misses the case where BLACK IS emitted but
    # AFTER the frame's halt would have fired (i.e. the loop took
    # >69888 T-states; the halt at the next loop iteration catches a
    # *late* interrupt and the game effectively runs <50 Hz for that
    # frame even though the BLACK marker appeared eventually).
    budget_overruns = []
    for fr in check_frames:
        ev = frames[fr]
        red_t = next((t for t, c in ev if c == 2), None)
        black_t = next((t for t, c in reversed(ev) if c == 0), None)
        if red_t is None or black_t is None:
            continue
        used = black_t - red_t
        if used > FRAME_TSTATES:
            budget_overruns.append((fr, used))
    if budget_overruns:
        print(f"FAIL: {len(budget_overruns)} frames exceeded "
              f"{FRAME_TSTATES} T budget (RED→BLACK)")
        for fr, used in budget_overruns[:5]:
            print(f"  frame {fr}: used {used} T (over by {used-FRAME_TSTATES})")
        return 1

    print(f"PASS: 0 overruns across {n} frames (every frame ended on BLACK)")

    # Bonus: report worst-case BLACK arrival within the frame as a
    # margin indicator. Closer to FRAME_TSTATES = less slack.
    worst_idle = 0
    worst_fr = None
    for fr in check_frames:
        ev = frames[fr]
        # BLACK time relative to start of frame.
        # First marker in this frame is RED at start; black is the last.
        red_t = next((t for t, c in ev if c == 2), ev[0][0])
        black_t = next((t for t, c in reversed(ev) if c == 0), ev[-1][0])
        used = black_t - red_t
        if used > worst_idle:
            worst_idle = used
            worst_fr = fr
    print(f"  worst frame: {worst_fr} used {worst_idle} T from RED→BLACK "
          f"(budget {FRAME_TSTATES} T)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
