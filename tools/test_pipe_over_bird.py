#!/usr/bin/env python3
r"""test_pipe_over_bird.py — verify pipe renders correctly when its body
cols pass over the bird.

Forces bird Y position to clamp (y=144) and runs many frames. At every
frame where a pipe's M1 or M2 col coincides with bird col 8 at a body
row, checks:

  1. **Cell attr = ATTR_PIPE ($20)** — pipe attr is in place (not stale
     BIRD/SKY left by paint_bird_attrs, and not ATTR_BUFFER $2D from a
     paint_bird_attrs save/restore cycle that would make the cell render
     cyan-on-cyan and the pipe invisible).

Note on pixel data: the pipe body bitmap is INTENTIONALLY empty in some
phases (e.g. M2 byte = $00 at phases 0,1 — see pipe_bitmap in
src/main.asm). With ATTR_PIPE ($20 = paper green / ink black), a $00
pixel byte renders as SOLID GREEN paper, which is the correct visual.
So pixel != 0 is NOT a valid invariant. The genuine "pipe blank over
bird" bug is the attr being ATTR_BUFFER ($2D = cyan/cyan), which
makes ANY pixel pattern render invisible against the sky.

For each failure, dumps the exact frame, pipe state, and what was found
vs expected.

Exit 0 on clean play, non-zero on any frame where pipe-on-bird looks
wrong.
"""
from __future__ import annotations
import sys, re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames, run_until_idle
from skoolkit.cmiosimulator import CMIOSimulator as Simulator

ATTR_PIPE = 0x20

SYM = {}
def _load():
    lst = Path(__file__).resolve().parent.parent / "build" / "main.lst"
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+(bird_y|bird_vy|pipe_state):", re.I)
    for line in lst.read_text(errors="ignore").splitlines():
        m = pat.match(line)
        if m: SYM[m.group(2)] = int(m.group(1), 16)
_load()


def pixel_addr(py, col):
    ccc = (py >> 6) & 3
    ppp = py & 7
    rrr = (py >> 3) & 7
    return 0x4000 | (ccc << 11) | (ppp << 8) | (rrr << 5) | col


def main():
    mem, pc, sp, s = load_sna("build/main.sna")
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    run_frames(sim, 30)  # warm-up

    print("test_pipe_over_bird: force bird at clamp, scan 1000 frames")
    overlaps_found = 0
    failures = []
    for fr in range(1000):
        # Force bird at clamp
        sim.memory[SYM["bird_y"]]     = 0
        sim.memory[SYM["bird_y"] + 1] = 144
        sim.memory[SYM["bird_vy"]]    = 0
        sim.memory[SYM["bird_vy"] + 1]= 0
        # Stop at end-of-frame BLACK marker so PIPE_PROGRAM and wrap_attrs
        # have run BUT the next frame's restore_bird_bg has NOT yet
        # zeroed the bird pixel cells.
        run_until_idle(sim)
        m = sim.memory
        bird_y = m[SYM["bird_y"] + 1]
        if bird_y != 144: continue

        # Bird at clamp: top_row=18, centre=19, bot=20. Body cell = row 19 col 8.
        # Check if any pipe's M1 or M2 covers col 8 at row 19 body.
        for i in range(3):
            bx = m[SYM["pipe_state"] + i * 2]
            gy = m[SYM["pipe_state"] + i * 2 + 1]
            if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
            if not (bx <= 8 <= bx + 1): continue  # col 8 is M1 (bx==8) or M2 (bx==7)
            k_top = (gy - 1) >> 3
            k_bot = (gy + 48) >> 3
            if not (19 <= k_top or 19 >= k_bot): continue  # row 19 not body
            overlaps_found += 1
            # Check attr at (row 19, col 8) = ATTR_PIPE
            attr = m[0x5800 + 19 * 32 + 8]
            if attr != ATTR_PIPE:
                failures.append(
                    f"frame {30+fr+1}: pipe {i} bx={bx} covers (19,8) but "
                    f"attr=${attr:02X} (expected PIPE $20)")
            # NOTE: pixel data check removed — pipe bitmap intentionally has
            # empty bytes in some phases (e.g. phase 0,1 M2 = $00). With
            # ATTR_PIPE in place, $00 pixels render as solid green paper.
            # The visual "blank pipe" bug is solely an attr issue.
            if failures and len(failures) >= 8:
                break
        if failures and len(failures) >= 8: break

    print(f"  overlaps found: {overlaps_found}")
    if failures:
        print(f"FAIL: {len(failures)} bad pipe-over-bird frames:")
        for f in failures[:5]:
            print(f"  {f}")
        return 1
    print(f"PASS: pipe renders correctly at {overlaps_found} pipe-over-bird overlap frames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
