#!/usr/bin/env python3
r"""test_render.py — render-correctness test for the pipe pipeline.

Runs the headless simulator for a series of checkpoints (initial settle,
first wrap, post-swap, mid-game) and asserts that EVERY visible pipe is
rendered correctly at each checkpoint. The test only flags VISIBLE bugs:

  - L (byte_x-1) and R (byte_x+2) cells at body rows MUST be ATTR_SKY
    ($28: paper cyan, ink black). $2D BUFFER here is the 3-cell strip
    bug — pipe edge-dither pixels render as cyan-on-cyan = invisible.

  - M1 (byte_x) and M2 (byte_x+1) cells at body+cap rows MUST be
    ATTR_PIPE ($20: paper green). $2D BUFFER here would make the pipe
    body cyan = invisible. SKY ($28) would make the green disappear.

  - M1/M2 cells in gap rows MUST have paper cyan ($28 OR $2D — visually
    identical). Different ink is harmless because no pipe pixels render
    in the gap.

  - pipe_state in valid ranges: byte_x 1..30, gap_y 8..96.

Cells where the bird sits (cols 7,8,9 at the bird's char row) are
skipped — the bird overrides pipe attrs there each frame intentionally.

Prep pipe is skipped (its body lives in the buffer band, invisible).

Exit 0 on success, non-zero on first failure. Prints one line per
checkpoint when passing; full per-cell detail on failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snadump import addr, addr_range
from refrender import (
    PIPE_STATE, PREP_PIPE_IDX, BIRD_Y, NUM_PIPES,
    BUFFER_COLS_L, BUFFER_COLS_R,
    ATTR_SKY, ATTR_PIPE, ATTR_BUFFER, GROUND_TOP_ROW,
)

# bird_attr_y address — auto-loaded from build/main.lst
BIRD_ATTR_Y = 0x8276

# PIPE_PROGRAM layout: 80 bands × 80 bytes, interleaved per pipe.
# Band index = cell * NUM_PIPES + pipe (3-pipe interleave: pipe N's
# bands are at indices N, N+3, ..., N+57 — one per cell, 20 cells).
PIPE_PROGRAM = 0xDB00
BAND_STRIDE  = 80
NUM_CELLS    = 20


def _load_bird_attr_y():
    import re
    lst_path = Path(__file__).resolve().parent.parent / "build" / "main.lst"
    if not lst_path.exists():
        return
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+bird_attr_y:", re.IGNORECASE)
    for line in lst_path.read_text(errors="ignore").splitlines():
        m = pat.match(line)
        if m:
            globals()["BIRD_ATTR_Y"] = int(m.group(1), 16)
            return


_load_bird_attr_y()
from runsim import load_sna as runsim_load_sna, make_register_dict
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T, IFF


# Paper of an attr (bits 3..5).
def paper(a):  return (a >> 3) & 0x7

CYAN_PAPER = 5  # both ATTR_SKY ($28) and ATTR_BUFFER ($2D) have paper=cyan


def k_top(gy):  return (gy - 1) >> 3
def k_bot(gy):  return (gy + 48) >> 3


def is_buffer_col(c):
    return c in BUFFER_COLS_L or c in BUFFER_COLS_R or not (0 <= c < 32)


def run_to_frame(sim, target_frame_count):
    opcodes = sim.opcodes
    memory = sim.memory
    regs = sim.registers
    frame_dur = sim.frame_duration
    int_active = sim.int_active
    accepted = 0
    max_t = regs[T] + (target_frame_count + 30) * frame_dur
    while accepted < target_frame_count and regs[T] < max_t:
        pc_before = regs[REGISTERS['PC']]
        opcodes[memory[pc_before]]()
        if regs[IFF] and regs[T] % frame_dur < int_active:
            sim.accept_interrupt(regs, memory, pc_before)
            accepted += 1
    return accepted


def check_ix_targets_match_byte_x(memory, pipes, prep):
    """Each body band of an active pipe must have its SMC `ld ix,addr`
    operand pointing at the pipe's current byte_x column. If patch_pipe_targets
    fails to decrement these (e.g. ACTIVE_PIPE_<n> is empty), the pipe's
    pixels are pushed to a stale column — typically off-screen in the right
    buffer, leaving the visible cells displaying stale ghost pixels.

    Decode: col = (ix_target_lo & 0x1F) — the SP-hijack push writes 4 bytes
    at IX-4..IX-1 (cols byte_x-1..byte_x+2), so IX target col == byte_x + 3.
    """
    fails = []
    for pipe_idx, (bx, gy) in enumerate(pipes):
        if pipe_idx == prep: continue
        if not (1 <= bx <= 30): continue
        expected_col = (bx + 3) & 0x1F
        for cell in range(NUM_CELLS):
            band_idx = cell * NUM_PIPES + pipe_idx
            band_addr = PIPE_PROGRAM + band_idx * BAND_STRIDE
            b0, b1 = memory[band_addr], memory[band_addr + 1]
            # JR-SKIP bands ($18 $42) carry no live IX — skip check.
            if (b0, b1) == (0x18, 0x42):
                continue
            # Body / cap-stamped bands start with $DD $21 (ld ix, nn).
            if (b0, b1) != (0xDD, 0x21):
                fails.append(("-", "-", b0, "$DD",
                              f"pipe {pipe_idx} cell {cell}: band at "
                              f"${band_addr:04X} unexpected opcode "
                              f"${b0:02X} ${b1:02X}"))
                continue
            ix_lo = memory[band_addr + 2]
            col = ix_lo & 0x1F
            if col != expected_col:
                fails.append(("-", "-", col, expected_col,
                              f"pipe {pipe_idx} (byte_x={bx}) cell {cell} "
                              f"band ${band_addr:04X}: IX target col {col} "
                              f"(lo=${ix_lo:02X}) but expected col "
                              f"{expected_col} — pipe pixels writing to "
                              f"wrong column → ghost stripes"))
    return fails


def find_ghost_pixels(memory, pipes, prep, bird_rows):
    """Return list of (col, row, attr, pixel_byte) for cells that:
      - are NOT inside any current pipe's body (L..R) at body+cap rows
      - are NOT in the bird's 3-col band
      - have an attr where ink != paper (so any pixel byte is visible)
      - have a non-zero pixel byte
    These are stale pixels left by prior pipe positions, now visible
    because the attr was restored to SKY ($28) by restore_leading or
    restore_trailing without clearing the underlying pixel data."""
    attrs = memory[0x5800:0x5B00]
    pixels = memory[0x4000:0x5800]
    # Cells covered by any current pipe (L M1 M2 R) at body+cap rows.
    pipe_cells = set()
    for i, (bx, gy) in enumerate(pipes):
        if i == prep: continue
        if not (1 <= bx <= 30 and 8 <= gy <= 96): continue
        kt, kb = k_top(gy), k_bot(gy)
        for row in range(GROUND_TOP_ROW):
            if kt < row < kb: continue
            for c in (bx-1, bx, bx+1, bx+2):
                if 0 <= c < 32:
                    pipe_cells.add((c, row))
    ghosts = []
    for cr in range(GROUND_TOP_ROW):
        for c in range(4, 28):  # skip buffer cols
            if (c, cr) in pipe_cells: continue
            if (c in (7, 8, 9)) and (cr in bird_rows): continue
            attr = attrs[cr * 32 + c]
            if (attr & 7) == ((attr >> 3) & 7):
                continue  # ink==paper, invisible regardless
            for sub in range(8):
                y = cr * 8 + sub
                ccc = (y >> 6) & 0x3
                ppp = y & 0x7
                rrr = (y >> 3) & 0x7
                row_addr = (ccc << 11) | (ppp << 8) | (rrr << 5)
                byte = pixels[row_addr + c]
                if byte != 0:
                    ghosts.append((c, cr, attr, byte))
                    break
    return ghosts


def check_pipe(attrs, pipe_idx, bx, gy, bird_rows):
    """Return list of (col, row, actual, expected, why) failures.
    bird_rows is a set of char rows that the bird's 3-col attr band
    currently occupies (typically 2 consecutive rows since the sprite
    is 16 px tall)."""
    fails = []
    if not (1 <= bx <= 30):
        return [("-", "-", bx, "1..30",
                 f"pipe {pipe_idx} byte_x out of range")]
    if not (8 <= gy <= 96):
        return [("-", "-", gy, "8..96",
                 f"pipe {pipe_idx} gap_y out of range")]

    kt, kb = k_top(gy), k_bot(gy)
    L, M1, M2, R = bx - 1, bx, bx + 1, bx + 2
    bird_cols = {7, 8, 9}

    for row in range(GROUND_TOP_ROW):
        in_gap = kt < row < kb
        in_bird_row = (row in bird_rows)

        # M1/M2 cell expectations
        for col in (M1, M2):
            if is_buffer_col(col): continue
            if in_bird_row and col in bird_cols: continue
            actual = attrs[row * 32 + col]
            if in_gap:
                if paper(actual) != CYAN_PAPER:
                    fails.append((col, row, actual, "paper=cyan",
                                  f"pipe {pipe_idx} M-cell in gap — green/black showing into gap"))
            else:
                if actual != ATTR_PIPE:
                    fails.append((col, row, actual, ATTR_PIPE,
                                  f"pipe {pipe_idx} M-cell body — pipe body wouldn't render green"))

        # L/R cell expectations (only on body rows — gap L/R has no
        # dither pixels so $28 vs $2D is invisible there)
        if in_gap:
            continue
        for col in (L, R):
            if is_buffer_col(col): continue
            if in_bird_row and col in bird_cols: continue
            actual = attrs[row * 32 + col]
            # L/R use ATTR_SKY (cyan paper, black ink) so the pipe edge
            # pixel renders as classic black-on-cyan attribute clash.
            # $2D BUFFER hides the edge entirely (cyan-on-cyan).
            if actual != ATTR_SKY:
                tag = "L" if col == L else "R"
                if actual == ATTR_BUFFER:
                    why = (f"pipe {pipe_idx} {tag}-cell body = $2D BUFFER "
                           f"→ edge-dither pixels invisible")
                else:
                    why = f"pipe {pipe_idx} {tag}-cell body has unexpected attr (expected SKY)"
                fails.append((col, row, actual, ATTR_SKY, why))
    return fails


def check_snapshot(memory):
    prep = memory[PREP_PIPE_IDX]
    attrs = memory[0x5800:0x5B00]
    # bird_attr_y stores the bird's vertical pixel Y; the attr cell is
    # at char row (bird_attr_y // 8). Sprite is 16 px tall so the
    # adjacent char row may also be restored to SKY at cols 7/9 by
    # restore_bird_bg. Skip both rows to avoid false flags.
    bird_attr_y_px = memory[BIRD_ATTR_Y]
    bird_attr_row = bird_attr_y_px // 8
    bird_rows = {bird_attr_row, bird_attr_row - 1, bird_attr_row + 1}

    pipes = []
    for i in range(NUM_PIPES):
        bx = memory[PIPE_STATE + i * 2]
        gy = memory[PIPE_STATE + i * 2 + 1]
        pipes.append((bx, gy))

    summary = []
    for i, (bx, gy) in enumerate(pipes):
        tag = " (prep)" if i == prep else ""
        summary.append(f"p{i}:bx={bx},gy={gy}{tag}")

    fails = []
    for i, (bx, gy) in enumerate(pipes):
        if i == prep: continue
        fails.extend(check_pipe(attrs, i, bx, gy, bird_rows))

    # PIPE_PROGRAM IX-target sync check: each body band of an active
    # pipe must point at the pipe's current byte_x. A stale IX makes
    # the pipe push pixels to the wrong column (often off-screen in
    # the right buffer) leaving stale ghost pixels in the visible cells.
    fails.extend(check_ix_targets_match_byte_x(memory, pipes, prep))

    # Pixel-level ghost check: stale pixels in visible cells outside
    # any current pipe or the bird. These cause "phantom stripes" —
    # see https://… (the bug where restore_leading exposed old pixels).
    ghosts = find_ghost_pixels(memory, pipes, prep, bird_rows)
    for c, cr, attr, byte in ghosts:
        fails.append((c, cr, byte, "00",
                      f"ghost pixel: visible cell (attr=${attr:02X}) has "
                      f"stale pixel byte ${byte:02X} — should be sky"))

    return fails, summary, bird_attr_row


# Continuous frame range — run every frame in [LO, HI] through
# check_snapshot. Catches transient bugs that only appear for a single
# frame around wrap/swap events (the 4-checkpoint sampler at fixed
# frames misses these).
CONTINUOUS_RANGE = (50, 5000)


CHECKPOINTS = [
    ("settle (50f)",             50),
    ("post-first-wrap (200f)",   200),
    ("post-many-wraps (500f)",   500),
    ("longer-run (1000f)",      1000),
]


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = runsim_load_sna(sna_path)
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    print(f"test_render: {len(CHECKPOINTS)} checkpoints on {sna_path}")
    last = 0
    total_fails = 0
    for label, target in CHECKPOINTS:
        run_to_frame(sim, target - last)
        last = target
        memory = bytes(sim.memory[:0x10000])
        fails, summary, bird_attr_y_dbg = check_snapshot(memory)
        if not fails:
            print(f"  PASS [{label:<26}] {' '.join(summary)} (bird@row{bird_attr_y_dbg})")
        else:
            print(f"  FAIL [{label:<26}] {' '.join(summary)} (bird@row{bird_attr_y_dbg})")
            for col, row, actual, expected, why in fails[:20]:
                if col == "-":
                    print(f"      {why}: got {actual}, expected {expected}")
                else:
                    exp = f"${expected:02X}" if isinstance(expected, int) else expected
                    print(f"      ({col:2},{row:2})  actual=${actual:02X}  "
                          f"expected={exp}  — {why}")
            if len(fails) > 20:
                print(f"      ... and {len(fails) - 20} more")
            total_fails += len(fails)

    # Continuous-frame sweep: run frame-by-frame, check each. This
    # catches transient bugs (e.g. single-frame ghosts during the
    # swap+wrap transition) that the 4-checkpoint sampler misses.
    lo, hi = CONTINUOUS_RANGE
    if last < lo:
        run_to_frame(sim, lo - last)
        last = lo
    print(f"  continuous sweep: frames {last}..{hi}")
    transient_fails = 0
    transient_frames = []
    sample_fail_detail = None
    while last < hi:
        run_to_frame(sim, 1)
        last += 1
        memory = bytes(sim.memory[:0x10000])
        fails, summary, _ = check_snapshot(memory)
        if fails:
            transient_fails += len(fails)
            transient_frames.append(last)
            if sample_fail_detail is None:
                sample_fail_detail = (last, summary, fails[:10])

    if transient_frames:
        first_fr, summary, sample_fails = sample_fail_detail
        print(f"  FAIL continuous sweep: {len(transient_frames)} frames "
              f"with fails (total {transient_fails} cells)")
        print(f"    frames: {transient_frames[:20]}"
              + (f" ... +{len(transient_frames)-20}" if len(transient_frames) > 20 else ""))
        print(f"    first failing frame {first_fr}: {' '.join(summary)}")
        for col, row, actual, expected, why in sample_fails:
            if col == "-":
                print(f"      {why}: got {actual}, expected {expected}")
            else:
                exp = f"${expected:02X}" if isinstance(expected, int) else expected
                print(f"      ({col:2},{row:2})  actual=${actual:02X}  "
                      f"expected={exp}  — {why}")
        total_fails += transient_fails

    if total_fails:
        print(f"FAIL: {total_fails} cell mismatches total")
        return 1
    print("PASS: all checkpoints + continuous sweep clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
