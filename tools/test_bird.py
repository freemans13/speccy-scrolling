#!/usr/bin/env python3
r"""test_bird.py — bird-render correctness test.

Catches three classes of bird bug, every frame for the run:

  1. **Yellow trail.** Exactly ONE attr cell on the whole screen must
     equal ATTR_BIRD ($70). >1 means the bird has left a yellow streak
     as it moved (paint/restore pairing broken, e.g. two paints per
     frame that both update bird_attr_y). 0 means the bird isn't being
     painted at all.

  2. **Wrong yellow cell.** The unique $70 cell must be at
     (bird_attr_y_row, col 8) — the position computed from the live
     bird_y state. A mismatch means paint and the bird's actual screen
     position diverged.

  3. **Wing band mis-coloured.** The adjacent cells (row, col 7) and
     (row, col 9) must be ATTR_SKY ($28). Anything else and the wing
     pixels would render in the wrong colour.

The bird falls from y=80 to clamp y=144, crossing ~8 char rows, so
multiple paint/restore boundary transitions are exercised. Every frame
during the run is checked (no sampling), so transient single-frame
trails trip the test.

Exit 0 on success, non-zero on first failure. Prints summary on success.
"""
from __future__ import annotations
import sys
import re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator

ATTR_BIRD = 0x70
ATTR_SKY  = 0x28
BIRD_COL  = 8

SYM = {
    "bird_y":          0x829F,
    "bird_attr_y":     0x82B5,
    "bird_attr_valid": 0x82B6,
    "pipe_state":      0x82C0,  # 3 × (byte_x, gap_y)
}
NUM_PIPES = 3

def _load_syms():
    lst = Path(__file__).resolve().parent.parent / "build" / "main.lst"
    if not lst.exists():
        return
    names = "|".join(SYM)
    pat = re.compile(rf"^\s*\d+\s+([0-9A-F]{{4}})\s+[0-9A-F\s]*\s+({names}):", re.I)
    for line in lst.read_text(errors="ignore").splitlines():
        m = pat.match(line)
        if m:
            SYM[m.group(2)] = int(m.group(1), 16)
_load_syms()


def snapshot_check(mem, frame_num):
    """bird_attr_y stores the bird's TOP pixel-y. paint_bird_attrs writes 9
    attr cells across 3 char rows (top, centre=top+1, bottom=top+2) at
    cols 7,8,9. Centre row col 8 is the only ATTR_BIRD cell on screen.
    All other 8 cells must be ATTR_SKY."""
    fails = []
    if not mem[SYM["bird_attr_valid"]]:
        return [f"frame {frame_num}: bird_attr_valid==0 (paint_bird_attrs never ran)"]
    bird_attr_y = mem[SYM["bird_attr_y"]]
    top_row = (bird_attr_y & 0xF8) // 8
    centre_row = top_row + 1
    attrs = mem[0x5800:0x5B00]
    yellow = [i for i, a in enumerate(attrs) if a == ATTR_BIRD]
    if len(yellow) != 1:
        coords = [(idx // 32, idx % 32) for idx in yellow[:8]]
        fails.append(
            f"frame {frame_num}: expected 1 ATTR_BIRD cell, found {len(yellow)} "
            f"at (row,col)={coords} — yellow trail bug (paint/restore broken)")
        return fails
    idx = yellow[0]
    actual_row, actual_col = idx // 32, idx % 32
    if (actual_row, actual_col) != (centre_row, BIRD_COL):
        fails.append(
            f"frame {frame_num}: ATTR_BIRD at (row {actual_row}, col {actual_col}) "
            f"but bird_attr_y={bird_attr_y} implies centre (row {centre_row}, col {BIRD_COL})")
    # Wing/silhouette cells: cols 7 and 9 across all 3 rows MUST be SKY;
    # col 8 at top and bottom rows MUST be SKY (head/tail silhouette).
    expected = []
    for r_off in range(3):
        r = top_row + r_off
        for c in (7, 8, 9):
            if r_off == 1 and c == 8:
                expected.append((r, c, ATTR_BIRD, "body"))
            else:
                expected.append((r, c, ATTR_SKY, "wing/silhouette"))
    for r, c, want, role in expected:
        if not (0 <= r < 24): continue
        got = attrs[r * 32 + c]
        if got != want:
            fails.append(
                f"frame {frame_num}: row {r} col {c} ({role}) attr ${got:02X} "
                f"(expected ${want:02X}) — sprite pixel renders in wrong colour")
    return fails


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = load_sna(sna_path)
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    # Warm-up: let init/menu/etc. settle so paint_bird_attrs has run.
    WARMUP = 30
    run_frames(sim, WARMUP)
    N = 500
    print(f"test_bird: checking attrs after every frame for {N} frames (after {WARMUP}-frame warm-up)")
    first_fail = None
    for i in range(N):
        run_frames(sim, 1)
        fr = WARMUP + i + 1
        fails = snapshot_check(sim.memory, fr)
        if fails and first_fail is None:
            first_fail = (fr, fails)
            break
    if first_fail:
        fr, fails = first_fail
        print(f"FAIL at frame {fr}:")
        for f in fails:
            print(f"  {f}")
        return 1
    bird_y_hi = sim.memory[SYM["bird_y"] + 1]
    bird_attr_y = sim.memory[SYM["bird_attr_y"]]
    print(f"PASS: {N} frames clean (final bird_y={bird_y_hi}, "
          f"bird_attr_y={bird_attr_y}, row={bird_attr_y // 8})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
