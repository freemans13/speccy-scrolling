#!/usr/bin/env python3
r"""test_bird.py — bird-render correctness test.

Catches four classes of bird bug, every frame for the run, with the bird
actively flapping (forced via direct bird_vy writes, every N frames):

  1. **Yellow trail.** Exactly ONE attr cell on the whole screen must
     equal ATTR_BIRD ($70). >1 means the bird has left a yellow streak
     as it moved (paint/restore pairing broken). 0 means the bird isn't
     being painted at all.

  2. **Bird centre wrong.** The unique $70 cell must be at
     (bird_attr_y_top_row + 1, col 8).

  3. **Wing/silhouette attrs.** All 9 cells of the 3-row bird band
     (cols 7,8,9 × rows top, centre, bot) must be ATTR_SKY ($28) except
     the body (centre, col 8) which is ATTR_BIRD ($70). Wing pixels
     rendered on $2D BUFFER would be invisible (cyan-on-cyan).

  4. **Stale pixel residue at cols 7,8,9 outside the bird's pixel rows.**
     The bird sprite is 16 px tall starting at bird_y. Pixel rows outside
     [bird_y, bird_y+15] at cols 7/8/9 must be 0, EXCEPT where a pipe is
     legitimately drawing pixels (pipes can scroll through these cols).
     A non-zero pixel byte at an unprotected row = stale bird pixels not
     cleaned up by restore_bird_bg, which the user sees as vertical
     stripes above/below the bird.

  5. **Raster-time attr check.** At the T-state when the raster reads
     each bird char row's attrs, the attrs MUST already be correct. The
     end-of-frame snapshot is not enough — wrap_attrs_combined runs at
     T~49k, potentially after the raster has already read row 18-19. If
     paint_bird_attrs runs only at top of frame and wrap_attrs overwrites
     bird cells mid-scan, the raster sees garbage even if the end-of-
     frame state looks correct.

The test forces a flap every 8 frames so the bird bounces around mid-air
instead of just falling to the floor — exercising paint/restore at every
char-row boundary in both directions.

Exit 0 on success, non-zero on first failure.
"""
from __future__ import annotations
import sys
import re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T, IFF

ATTR_BIRD = 0x70
ATTR_SKY  = 0x28
BIRD_LINES = 16
FLAP_VY = 0xFD80  # 16-bit signed flap velocity (-640)
FRAME_TSTATES = 69888
TOP_BLANK_END = 14336
SCANLINE_T = 224

SYM = {
    "bird_y":          0x82A2,
    "bird_vy":         0x82A4,
    "bird_attr_y":     0x82B8,
    "bird_attr_valid": 0x82B9,
    "pipe_state":      0x81E5,
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


def pipe_covers_cell(mem, col, row):
    """True if any pipe's L..R columns include `col` AND `row` is a body
    row (not in the pipe's gap)."""
    for i in range(NUM_PIPES):
        bx = mem[SYM["pipe_state"] + i * 2]
        gy = mem[SYM["pipe_state"] + i * 2 + 1]
        if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
        if not (bx - 1 <= col <= bx + 2): continue
        # row in pipe body: row <= (gy-1)>>3 or row >= (gy+48)>>3
        k_top = (gy - 1) >> 3
        k_bot = (gy + 48) >> 3
        if row <= k_top or row >= k_bot:
            return True
    return False


def check_attrs(mem, frame_num):
    fails = []
    if not mem[SYM["bird_attr_valid"]]:
        return [f"frame {frame_num}: bird_attr_valid==0 (paint never ran)"]
    bird_attr_y = mem[SYM["bird_attr_y"]]
    top_row = (bird_attr_y & 0xF8) // 8
    centre_row = top_row + 1
    attrs = mem[0x5800:0x5B00]
    yellow = [i for i, a in enumerate(attrs) if a == ATTR_BIRD]
    if len(yellow) != 1:
        coords = [(idx // 32, idx % 32) for idx in yellow[:8]]
        fails.append(
            f"frame {frame_num}: expected 1 ATTR_BIRD cell, found {len(yellow)} "
            f"at (row,col)={coords} — yellow trail bug")
        return fails
    idx = yellow[0]
    actual_row, actual_col = idx // 32, idx % 32
    if (actual_row, actual_col) != (centre_row, 8):
        fails.append(
            f"frame {frame_num}: ATTR_BIRD at (row {actual_row}, col {actual_col}) "
            f"but expected centre (row {centre_row}, col 8)")
    for r_off in range(3):
        r = top_row + r_off
        for c in (7, 8, 9):
            if not (0 <= r < 24): continue
            want = ATTR_BIRD if (r_off == 1 and c == 8) else ATTR_SKY
            got = attrs[r * 32 + c]
            if got != want:
                role = "body" if want == ATTR_BIRD else "wing/silhouette"
                fails.append(
                    f"frame {frame_num}: row {r} col {c} ({role}) attr ${got:02X} "
                    f"(expected ${want:02X})")
    return fails


def check_stale_pipe_attrs(mem, frame_num):
    """Cols 7,8,9 cells where attr = $20 ATTR_PIPE but no current pipe's
    M1/M2 covers that (row, col) at a body row. Renders as visible green
    block (paper green, ink black, no pixel = solid green cell) above/
    below the bird as it flies past — the "max-velocity green spots"
    user-reported bug."""
    fails = []
    for r in range(20):
        for c in (7, 8, 9):
            attr = mem[0x5800 + r * 32 + c]
            if attr != 0x20: continue
            covered = False
            for i in range(NUM_PIPES):
                bx = mem[SYM["pipe_state"] + i * 2]
                gy = mem[SYM["pipe_state"] + i * 2 + 1]
                if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
                if not (bx <= c <= bx + 1): continue
                k_top = (gy - 1) >> 3
                k_bot = (gy + 48) >> 3
                if r <= k_top or r >= k_bot:
                    covered = True; break
            if not covered:
                fails.append(
                    f"frame {frame_num}: row {r} col {c} attr=$20 PIPE "
                    f"(stale — no current pipe covers) — visible green block")
                if len(fails) >= 5: return fails
    return fails


def check_pixel_residue(mem, frame_num):
    """At cols 7,8,9 (the bird's columns), pixel rows outside [bird_y,
    bird_y+15] should be 0 UNLESS:
      - a pipe legitimately covers that cell (pipe pixels expected), OR
      - the attr at that cell makes residue invisible (paper == ink, i.e.
        $2D BUFFER cyan-on-cyan).
    A non-zero pixel under a $28 SKY (or any ink != paper) attr is the
    visible bug — black stripes through the bird's column path."""
    fails = []
    bird_y = mem[SYM["bird_y"] + 1]
    bird_top_y = bird_y
    bird_bot_y = bird_y + BIRD_LINES - 1
    for c in (7, 8, 9):
        for py in range(0, 160):
            if bird_top_y <= py <= bird_bot_y:
                continue
            char_row = py >> 3
            if pipe_covers_cell(mem, c, char_row):
                continue
            attr = mem[0x5800 + char_row * 32 + c]
            ink = attr & 7
            paper = (attr >> 3) & 7
            if ink == paper:
                continue  # residue invisible (e.g., $2D BUFFER cyan-on-cyan)
            ccc = (py >> 6) & 0x3
            ppp = py & 0x7
            rrr = (py >> 3) & 0x7
            addr = 0x4000 | (ccc << 11) | (ppp << 8) | (rrr << 5)
            byte = mem[addr + c]
            if byte != 0:
                fails.append(
                    f"frame {frame_num}: col {c} pixel y={py} (row {char_row}) "
                    f"= ${byte:02X} attr=${attr:02X} (bird is at y "
                    f"{bird_top_y}..{bird_bot_y}) — VISIBLE stale residue, "
                    f"vertical stripe")
                if len(fails) >= 5: return fails
    return fails


def run_one_frame_with_mid_capture(sim, capture_t):
    """Run instructions until next interrupt accepted (= end of one frame).
    At the first instruction whose T-state has crossed `capture_t`, snapshot
    a copy of mem[0x5800..0x5B00] and return it alongside the frame end."""
    opcodes = sim.opcodes
    memory = sim.memory
    regs = sim.registers
    frame_dur = sim.frame_duration
    int_active = sim.int_active
    PC_idx = REGISTERS['PC']
    captured = None
    while True:
        pc_before = regs[PC_idx]
        t_before = regs[T] % frame_dur
        opcodes[memory[pc_before]]()
        if captured is None and (regs[T] % frame_dur) >= capture_t and t_before < capture_t:
            captured = bytes(memory[0x5800:0x5B00])
        if regs[IFF] and regs[T] % frame_dur < int_active:
            sim.accept_interrupt(regs, memory, pc_before)
            return captured


def check_raster_time_attrs(mem_attrs, mem_at_eof, frame_num):
    """The captured mid-scan attrs MUST match the end-of-frame attrs at
    the bird's 3 char rows, cols 7,8,9. If they differ, paint vs wrap
    are racing the raster."""
    fails = []
    bird_attr_y = mem_at_eof[SYM["bird_attr_y"]]
    top_row = (bird_attr_y & 0xF8) // 8
    for r_off in range(3):
        r = top_row + r_off
        if not (0 <= r < 24): continue
        for c in (7, 8, 9):
            mid = mem_attrs[r * 32 + c]
            end = mem_at_eof[0x5800 + r * 32 + c]
            if mid != end:
                fails.append(
                    f"frame {frame_num}: row {r} col {c} attr at raster-time "
                    f"= ${mid:02X} but end-of-frame = ${end:02X} — raster "
                    f"sees stale/racing value")
    return fails


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = load_sna(sna_path)
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    WARMUP = 30
    run_frames(sim, WARMUP)
    # Velocity scenarios exercise bird through varied dynamics. flap_period=0
    # → free fall (max downward velocity, ~8 px/frame). flap_period=1 →
    # continuous flap (sustained upward, max ~2.5 px/frame). Scenarios run
    # sequentially so the bird state carries over.
    scenarios = [
        ("settling (flap every 8f)",       80,  8),
        ("free fall to max down velocity", 80,  0),
        ("continuous flap up",             80,  1),
        ("alternating fast",               80,  2),
        ("normal play (every 6f)",        100,  6),
        ("rare flap (every 12f)",         100, 12),
    ]
    total_frames = sum(n for _, n, _ in scenarios)
    print(f"test_bird: {total_frames} frames across {len(scenarios)} velocity scenarios "
          f"(attrs + stale-PIPE-attrs + pixel-residue + raster-time)")
    first_fail = None
    fr = WARMUP
    for desc, n_fr, flap_per in scenarios:
        for i in range(n_fr):
            if flap_per > 0 and i % flap_per == 0:
                sim.memory[SYM["bird_vy"]]     = FLAP_VY & 0xFF
                sim.memory[SYM["bird_vy"] + 1] = (FLAP_VY >> 8) & 0xFF
            fr += 1
            bird_y_now = sim.memory[SYM["bird_y"] + 1]
            capture_t = bird_y_now * SCANLINE_T + TOP_BLANK_END
            mid_attrs = run_one_frame_with_mid_capture(sim, capture_t)
            fails = []
            fails.extend(check_attrs(sim.memory, fr))
            if not fails:
                fails.extend(check_stale_pipe_attrs(sim.memory, fr))
            if not fails:
                fails.extend(check_pixel_residue(sim.memory, fr))
            if not fails and mid_attrs is not None:
                fails.extend(check_raster_time_attrs(mid_attrs, sim.memory, fr))
            if fails:
                first_fail = (fr, desc, fails)
                break
        if first_fail:
            break
    if first_fail:
        fr, desc, fails = first_fail
        print(f"FAIL at frame {fr} (scenario: {desc}):")
        for f in fails:
            print(f"  {f}")
        return 1
    bird_y_hi = sim.memory[SYM["bird_y"] + 1]
    print(f"PASS: {total_frames} frames across all velocity scenarios clean "
          f"(final bird_y={bird_y_hi})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
