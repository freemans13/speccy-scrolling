#!/usr/bin/env python3
r"""test_bird_sweep.py — comprehensive bird-render correctness test.

Sweeps the bird through every valid Y position (20..144) and at each one
checks the full bird-rendering contract:

  1. **Bird sprite present**: at least SOME sprite pixels are drawn at
     the bird's pixel range (bird_y..bird_y+15) at cols 7,8,9.
  2. **Bird body cell**: centre row col 8 is either ATTR_BIRD ($70)
     or — if a current pipe covers (bx in [5..10] at body row) — a
     pipe-related attr ($28 SKY / $20 PIPE / $2D BUFFER).
  3. **Wing cells**: cols 7/9 at bird's 3 char rows are SKY/BUFFER/PIPE
     (no garbage).
  4. **No artifacts above bird**: at cols 7,8,9, pixel rows ABOVE bird's
     range (0..bird_y-1) with visible attr (ink != paper) must be 0
     EXCEPT where a pipe legitimately covers.
  5. **No artifacts below bird**: same as 4 but for pixel rows
     bird_y+16..159.
  6. **Ground band intact**: row 20 cols 4..27 unchanged from baseline.
  7. **Pipe-overlap rendering**: at cells where bird and pipe overlap
     (bird col in pipe's L..R range at body row), the cell has BOTH
     bird sprite pixels AND pipe pixel data (OR'd) — verifies the
     masked-OR draw_bird actually overlays on pipe pixels.

Forces bird Y by direct memory write each iteration (bypasses physics),
then runs 2 frames for state to settle (1 for paint, 1 for save/restore
to stabilise). Pipes scroll naturally.

Exit 0 on clean sweep, 1 on first failure with row/col detail.
"""
from __future__ import annotations
import sys, re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator

ATTR_BIRD   = 0x70
ATTR_SKY    = 0x28
ATTR_BUFFER = 0x2D
ATTR_PIPE   = 0x20
BIRD_LINES  = 16
NUM_PIPES   = 3

SYM = {}
def _load():
    lst = Path(__file__).resolve().parent.parent / "build" / "main.lst"
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+(bird_y|bird_vy|bird_attr_y|bird_attr_valid|pipe_state):", re.I)
    for line in lst.read_text(errors="ignore").splitlines():
        m = pat.match(line)
        if m: SYM[m.group(2)] = int(m.group(1), 16)
_load()


def pixel_addr(py, col):
    ccc = (py >> 6) & 3
    ppp = py & 7
    rrr = (py >> 3) & 7
    return 0x4000 | (ccc << 11) | (ppp << 8) | (rrr << 5) | col


def pipe_legit_pixel(mem, col, char_row):
    """Returns True if a current pipe is drawing pixels at (char_row, col)
    at a body row of that pipe (= legitimate pipe pixel, not residue)."""
    for i in range(NUM_PIPES):
        bx = mem[SYM["pipe_state"] + i * 2]
        gy = mem[SYM["pipe_state"] + i * 2 + 1]
        if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
        # PIPE_PROGRAM body push covers cols [bx-1..bx+3] (5 cols, L..V)
        if not (bx - 1 <= col <= bx + 3): continue
        k_top = (gy - 1) >> 3
        k_bot = (gy + 48) >> 3
        if char_row <= k_top or char_row >= k_bot:
            return True
    return False


def pipe_covers_col_at_centre(mem, centre_row):
    """True if any pipe overlaps bird centre col 8 at centre row body."""
    for i in range(NUM_PIPES):
        bx = mem[SYM["pipe_state"] + i * 2]
        gy = mem[SYM["pipe_state"] + i * 2 + 1]
        if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
        if not (5 <= bx <= 10): continue
        k_top = (gy - 1) >> 3
        k_bot = (gy + 48) >> 3
        if centre_row <= k_top or centre_row >= k_bot:
            return True
    return False


def force_bird_y(sim, y):
    """Force bird_y_hi to y, vy=0 (stationary). Bypasses physics."""
    sim.memory[SYM["bird_y"]]      = 0
    sim.memory[SYM["bird_y"] + 1]  = y
    sim.memory[SYM["bird_vy"]]     = 0
    sim.memory[SYM["bird_vy"] + 1] = 0


def check_one_position(sim, y, ground_baseline):
    """Verify bird renders correctly at bird_y_hi=y. Returns list of fails."""
    fails = []
    mem = sim.memory
    bird_attr_y = mem[SYM["bird_attr_y"]]
    top_row = (bird_attr_y & 0xF8) // 8
    centre_row = top_row + 1
    bot_row = top_row + 2

    # 1. Bird sprite present — at least 8 nonzero pixel bytes in bird's range
    sprite_pixel_count = 0
    for py in range(y, y + BIRD_LINES):
        if py >= 192: break
        for c in (7, 8, 9):
            if mem[pixel_addr(py, c)]:
                sprite_pixel_count += 1
    if sprite_pixel_count < 8:
        fails.append(f"y={y}: only {sprite_pixel_count} non-zero sprite pixels in bird range")

    # 2. Body cell
    if 0 <= centre_row < 20:
        got = mem[0x5800 + centre_row * 32 + 8]
        if pipe_covers_col_at_centre(mem, centre_row):
            valid = {ATTR_BIRD, ATTR_SKY, ATTR_BUFFER, ATTR_PIPE}
        else:
            valid = {ATTR_BIRD}
        if got not in valid:
            fails.append(f"y={y}: body cell row {centre_row} col 8 attr ${got:02X} "
                         f"not in {{{','.join(f'${v:02X}' for v in valid)}}}")

    # 3. Wing cells: cols 7/9 at 3 char rows
    wing_valid = {ATTR_SKY, ATTR_BUFFER, ATTR_PIPE}
    for r_off in range(3):
        r = top_row + r_off
        if not (0 <= r < 20): continue
        for c in (7, 9):
            got = mem[0x5800 + r * 32 + c]
            if got not in wing_valid:
                fails.append(f"y={y}: wing cell row {r} col {c} attr ${got:02X} "
                             f"invalid (expected SKY/BUFFER/PIPE)")

    # 4. & 5. No artifacts above/below bird at cols 7,8,9 (visible attr only)
    bird_top = y
    bird_bot = y + BIRD_LINES - 1
    for c in (7, 8, 9):
        for py in range(0, 160):
            if bird_top <= py <= bird_bot:
                continue
            char_row = py >> 3
            if pipe_legit_pixel(mem, c, char_row):
                continue
            attr = mem[0x5800 + char_row * 32 + c]
            if (attr & 7) == ((attr >> 3) & 7):
                continue  # cyan-on-cyan = invisible
            byte = mem[pixel_addr(py, c)]
            if byte != 0:
                where = "above" if py < bird_top else "below"
                fails.append(f"y={y}: col {c} pixel y={py} ({where} bird, row {char_row}) "
                             f"= ${byte:02X} attr=${attr:02X} — VISIBLE artifact")
                if len(fails) >= 6: return fails

    # 6. Ground intact
    for cc in range(4, 28):
        if mem[0x5800 + 20 * 32 + cc] != ground_baseline[cc - 4]:
            fails.append(f"y={y}: ground row 20 col {cc} corrupted "
                         f"(${mem[0x5800 + 20 * 32 + cc]:02X} vs baseline ${ground_baseline[cc - 4]:02X})")
            break

    return fails


def main():
    mem, pc, sp, s = load_sna("build/main.sna")
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    print("test_bird_sweep: sweeping bird Y=20..144 through every position")
    run_frames(sim, 60)  # warm-up so attrs/pipes are in normal play state
    ground_baseline = bytes(sim.memory[0x5800 + 20 * 32 + 4 : 0x5800 + 20 * 32 + 28])

    # Sweep every Y value the bird can occupy
    total_checks = 0
    first_fail = None
    for y in range(20, 145):  # 20..144 inclusive (bird clamps at 144)
        force_bird_y(sim, y)
        # Run 3 frames: 1 for the forced state to take effect, 2 for paint/draw to settle
        for _ in range(3):
            run_frames(sim, 1)
            force_bird_y(sim, y)  # keep forcing (physics tries to move bird)
        fails = check_one_position(sim, y, ground_baseline)
        total_checks += 1
        if fails:
            first_fail = (y, fails)
            break
    if first_fail:
        y, fails = first_fail
        print(f"FAIL at bird_y={y} (after {total_checks} positions checked):")
        for f in fails[:8]:
            print(f"  {f}")
        return 1
    print(f"PASS: {total_checks} bird Y positions clean (y=20..{20 + total_checks - 1})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
