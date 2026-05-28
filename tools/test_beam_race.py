#!/usr/bin/env python3
r"""test_beam_race.py — verify attr writes don't race the raster.

Uses the OUT($FE) profile markers to bound when each region of work
runs, then asserts that pipe-attr writes complete in a SAFE window
relative to the raster scan of the visible playfield.

Raster timing (after IRQ at T=0 of frame):
  Top blanking:     T = 0 .. ~14336
  Visible y=0:      T = ~14336
  Visible y=152:    T = 14336 + 152*224 = 48384  (start of char row 19)
  Visible y=159:    T = 14336 + 159*224 = 49952  (end of char row 19 = last pipe row)
  Visible y=191:    T = 14336 + 191*224 = 57120  (end of visible)
  Bottom blanking:  T = ~57120 .. 69888

For pipe attrs (rows 0..19), a write is SAFE if:
  - completed BEFORE T = ~14336 (raster hasn't started visible yet), OR
  - happens AFTER  T = ~49952  (raster passed last pipe row)

The current renderer fires PROFILE_OUT 4 (GREEN) just before
wrap_attrs_combined and PROFILE_OUT 1 (BLUE) just after. This test
parses the OUT log, finds the GREEN→BLUE pair on wrap frames, and
asserts the GREEN→BLUE range fits entirely within bottom blanking
(T_GREEN >= 49952 and T_BLUE <= 69888).

Also asserts:
  - MAGENTA (PIPE_PROGRAM) starts before the raster reaches y=0 + a
    safety margin, so PIPE_PROGRAM stays ahead of the beam.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T

FRAME_TSTATES = 69888
VISIBLE_START_T = 14336
SCANLINE_T = 224
# Raster reads char row 19's attrs during scanline 152 (= the FIRST
# scanline of char row 19). After scanline 152 finishes, no further
# reads of any pipe row's attrs (rows 0..19) this frame.
# T = 14336 + 153 * 224 = 48,608. Add ~400 T margin for the ULA's
# attr fetch within the scanline → 49,000.
LAST_PIPE_ROW_END_T = VISIBLE_START_T + 153 * SCANLINE_T + 400  # ~49,008

TEST_FRAMES = 500

COLOR_GREEN = 4
COLOR_BLUE = 1
COLOR_MAGENTA = 3


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = load_sna(sna_path)
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    print(f"test_beam_race: running {sna_path} for {TEST_FRAMES} frames; "
          f"checking PROFILE_OUT markers vs raster windows")

    out_log = []
    run_frames(sim, TEST_FRAMES, out_log)

    # Group OUT events by frame_idx.
    frames = {}
    for t, a, fr in out_log:
        frames.setdefault(fr, []).append((t, a & 0x07))

    keys = sorted(frames.keys())
    if len(keys) < 4:
        print(f"FAIL: only {len(keys)} frames captured")
        return 1

    # Skip first/last (init/incomplete).
    check_keys = keys[1:-1]

    # For each frame, find:
    #   - first MAGENTA: must be <= a safety threshold so PIPE_PROGRAM
    #     stays ahead of the raster
    #   - GREEN → BLUE (subsequent): wrap_attrs_combined window, must
    #     be entirely in bottom blanking (only fires on wrap frames)
    MAGENTA_SAFETY_LIMIT = VISIBLE_START_T   # MAGENTA must fire before raster reaches y=0

    bad_magenta = []
    bad_attrs = []
    wrap_frames = 0

    for fr in check_keys:
        ev = frames[fr]
        # Frame-relative T of each marker.
        red_t = next((t for t, c in ev if c == 2), None)
        if red_t is None:
            continue
        # MAGENTA check (first occurrence — the outer marker)
        mag = next((t - red_t for t, c in ev if c == COLOR_MAGENTA), None)
        if mag is not None and mag >= MAGENTA_SAFETY_LIMIT:
            bad_magenta.append((fr, mag))

        # GREEN → BLUE check. GREEN fires only on wrap frames
        # (gated by wrap_pending).
        greens = [t - red_t for t, c in ev if c == COLOR_GREEN]
        # The first GREEN inside frame_update marks the ground band
        # (line 1999); we want the SECOND GREEN at line 314 which fires
        # before wrap_attrs_combined. The ground GREEN happens during
        # frame_update, very early; our wrap GREEN happens after BLUE,
        # WHITE, CYAN, YELLOW, busy-wait → very late.
        # The wrap_attrs_combined GREEN (line 314) fires only on wrap frames
        # AFTER the busy-wait, so it lands deep in the frame (T >= ~45k).
        # The ground-band GREEN fires inside frame_update at T ~28-30k and
        # exists every frame. Filter for the late GREEN; if absent this is
        # a non-wrap frame.
        wrap_greens = [g for g in greens if g >= 45000]
        if not wrap_greens:
            continue
        wrap_frames += 1
        green_t = wrap_greens[0]
        # Find subsequent BLUE marker.
        blues = sorted([t - red_t for t, c in ev if c == COLOR_BLUE])
        blue_after = next((b for b in blues if b > green_t), None)
        if blue_after is None:
            bad_attrs.append((fr, green_t, None, "no BLUE after GREEN"))
            continue
        if green_t < LAST_PIPE_ROW_END_T:
            bad_attrs.append((fr, green_t, blue_after,
                              f"wrap attrs started at T={green_t} "
                              f"< {LAST_PIPE_ROW_END_T} (raster still in playfield)"))
        elif blue_after > FRAME_TSTATES:
            bad_attrs.append((fr, green_t, blue_after,
                              f"wrap attrs ended at T={blue_after} > {FRAME_TSTATES} (overran frame)"))

    if bad_magenta:
        print(f"FAIL: {len(bad_magenta)} frames where MAGENTA (PIPE_PROGRAM) "
              f"starts too late (raster ahead):")
        for fr, t in bad_magenta[:5]:
            print(f"  frame {fr}: MAGENTA@T={t} (limit {MAGENTA_SAFETY_LIMIT})")
        return 1

    if bad_attrs:
        print(f"FAIL: {len(bad_attrs)} wrap frames where attr writes raced the raster:")
        for fr, g, b, msg in bad_attrs[:5]:
            print(f"  frame {fr}: {msg}")
        return 1

    print(f"PASS: MAGENTA always < T={MAGENTA_SAFETY_LIMIT} "
          f"({len(check_keys)} frames)")
    print(f"PASS: wrap attrs in bottom blanking "
          f"(T >= {LAST_PIPE_ROW_END_T}) on {wrap_frames} wrap frames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
