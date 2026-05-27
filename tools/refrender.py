#!/usr/bin/env python3
"""refrender.py — reference renderer for Speccy Flappy Bird.

Reads pipe_state + bird state from a .sna/.szx snapshot and renders the
EXPECTED screen mathematically from the game rules — independent of the
SMC pipe renderer in main.asm. Used together with screendiff.py to detect
rendering bugs (e.g. "pipe appears as 3-cell strip instead of 4-cell").

Two layers are produced:

  attrs  — 32×24 cells, 1 pixel per cell, RGB. Shows the EXPECTED ZX
           attribute byte at each cell, mapped to the same palette as
           snadump.py's screen decoder. This is the diagnostic layer for
           "where pipes appear".

  px     — 256×192, full pixel render using canonical bitmap patterns.
           Pipe body uses phase-0 bytes; cap rows use cap_rounded_bitmap
           phase 0; bird sprite uses frame 0; ground uses phase 0. Not
           pixel-perfect vs the game (scroll phase differs) — use the
           attrs layer for diff'ing.

Game rules used here:

  - pipe_state at $81A1: 4 × (byte_x, gap_y).
  - prep_pipe_idx at $81F8: the pipe currently parked off-screen (not rendered).
  - For each non-prep pipe:
      L  cell = byte_x - 1   (paper cyan, ink black; edge dither pixels)
      M1 cell = byte_x       (paper GREEN, body bytes)
      M2 cell = byte_x + 1   (paper GREEN, body bytes)
      R  cell = byte_x + 2   (paper cyan, ink black; edge dither pixels)
  - Cap rows:
      K_top = (gap_y - 1) >> 3   (top cap row)
      K_bot = (gap_y + 48) >> 3  (bot cap row)
    Gap rows are K_top+1 .. K_bot-1 (sky).
    Body rows are 0..K_top-1 and K_bot+1..19.
  - Buffer cols: 0..3 and 28..31 have ATTR_BUFFER ($2D) where no pipe is.
  - Bird: cols 7, 8, 9 at row (bird_y_hi + 4) >> 3 — col 8 is yellow paper
    (ATTR_BIRD $70), cols 7 and 9 are sky.
  - Ground band: rows 20 (= scan 160..167) ATTR_GROUND $20.
  - Scoreboard band: rows 21..23 (= scan 168..191) sky $28.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Reuse snadump's loader + palette helpers
sys.path.insert(0, str(Path(__file__).resolve().parent))
from snadump import load_sna, addr, addr_word, addr_range

# ── Game constants ────────────────────────────────────────────────────
NUM_PIPES = 4

PIPE_STATE      = 0x81A1   # 4 × (byte_x, gap_y)
BIRD_Y          = 0x825D
PREP_PIPE_IDX   = 0x81F8

ATTR_SKY        = 0x28     # paper cyan, ink black
ATTR_GROUND     = 0x20     # paper green, ink black
ATTR_PIPE       = 0x20     # paper green, ink black (body M1+M2)
ATTR_BIRD       = 0x70     # bright yellow paper, black ink
ATTR_BUFFER     = 0x2D     # paper cyan = ink cyan (invisible)
ATTR_SCOREBOARD = 0x07     # paper black, ink white (rows 21..23)

GROUND_TOP_ROW  = 20       # char row of ground (scan 160..167)
SCORE_TOP_ROW   = 21       # char row of scoreboard (scan 168..175)
NUM_SCORE_ROWS  = 3        # rows 21,22,23

BUFFER_COLS_L   = range(0, 4)
BUFFER_COLS_R   = range(28, 32)

# Spectrum palette (non-bright + bright), matching snadump.py
PAL_BASE = [
    (0, 0, 0), (0, 0, 192), (192, 0, 0), (192, 0, 192),
    (0, 192, 0), (0, 192, 192), (192, 192, 0), (192, 192, 192),
]
PAL_BRIGHT = [
    (0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
    (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255),
]


def attr_to_paper_rgb(a: int) -> tuple[int, int, int]:
    paper_idx = (a >> 3) & 0x7
    bright = (a & 0x40) != 0
    return (PAL_BRIGHT if bright else PAL_BASE)[paper_idx]


def attr_to_ink_rgb(a: int) -> tuple[int, int, int]:
    ink_idx = a & 0x7
    bright = (a & 0x40) != 0
    return (PAL_BRIGHT if bright else PAL_BASE)[ink_idx]


# ── State extraction ──────────────────────────────────────────────────

def read_state(data: bytes) -> dict:
    pipes = []
    for i in range(NUM_PIPES):
        bx = addr(data, PIPE_STATE + i * 2)
        gy = addr(data, PIPE_STATE + i * 2 + 1)
        pipes.append({"byte_x": bx, "gap_y": gy})
    return {
        "pipes": pipes,
        "prep_idx": addr(data, PREP_PIPE_IDX),
        "bird_y_hi": addr(data, BIRD_Y + 1),
    }


# ── Expected attribute map ────────────────────────────────────────────

def build_expected_attrs(state: dict) -> list[int]:
    """Return 768 attribute bytes (32 cols × 24 rows) reflecting the
    expected state from pipe_state + bird state."""
    attrs = [ATTR_SKY] * (32 * 24)

    # 1. Buffer cols (left & right) — invisible cyan-on-cyan.
    for row in range(GROUND_TOP_ROW):
        for col in list(BUFFER_COLS_L) + list(BUFFER_COLS_R):
            attrs[row * 32 + col] = ATTR_BUFFER

    # 2. Each non-prep pipe overlays its body+cap cells (overrides buffer
    #    attrs for pipes parked in the right buffer band).
    prep = state["prep_idx"]
    for idx, p in enumerate(state["pipes"]):
        if idx == prep:
            continue
        bx, gy = p["byte_x"], p["gap_y"]
        # Skip if byte_x is sentinel/zero or out of any sane range.
        if bx < 1 or bx > 30:
            continue
        if gy < 8 or gy > 96:
            continue

        k_top = (gy - 1) >> 3            # last cap (top piece) row
        k_bot = (gy + 48) >> 3           # first cap (bottom piece) row

        # Body+cap rows: everything from 0..k_top and k_bot..19 EXCEPT the
        # gap (k_top+1 .. k_bot-1).
        for row in range(GROUND_TOP_ROW):
            if k_top < row < k_bot:
                continue                  # gap — sky
            # Cells L = bx-1, M1 = bx, M2 = bx+1, R = bx+2.
            # L and R stay sky (with edge dither pixels in ink).
            # M1 and M2 carry pipe-green attr — but buffer cols stay BUFFER
            # (the buffer band paints invisible cyan-on-cyan over any pipe
            # that scrolls through it).
            for col in (bx, bx + 1):
                if 0 <= col < 32 and col not in BUFFER_COLS_L and col not in BUFFER_COLS_R:
                    attrs[row * 32 + col] = ATTR_PIPE

    # 3. Ground band (row 20) — green inside, buffer at edges.
    for col in range(32):
        if col in BUFFER_COLS_L or col in BUFFER_COLS_R:
            attrs[GROUND_TOP_ROW * 32 + col] = ATTR_BUFFER
        else:
            attrs[GROUND_TOP_ROW * 32 + col] = ATTR_GROUND
    # 4. Scoreboard band (rows 21..23) — paper black, ink white. Buffer at edges.
    for r in range(SCORE_TOP_ROW, SCORE_TOP_ROW + NUM_SCORE_ROWS):
        for col in range(32):
            if col in BUFFER_COLS_L or col in BUFFER_COLS_R:
                attrs[r * 32 + col] = ATTR_BUFFER
            else:
                attrs[r * 32 + col] = ATTR_SCOREBOARD

    # 5. Bird cell — col 8, row centred on bird_y_hi+4.
    by_hi = state["bird_y_hi"]
    bird_row = (by_hi + 4) >> 3
    if 0 <= bird_row < GROUND_TOP_ROW:
        attrs[bird_row * 32 + 8] = ATTR_BIRD

    return attrs


# ── Renderers ─────────────────────────────────────────────────────────

def render_attrs(attrs: list[int]) -> "Image.Image":
    """32×24 RGB: paper colour of each attr cell."""
    from PIL import Image
    img = Image.new("RGB", (32, 24))
    px = img.load()
    for row in range(24):
        for col in range(32):
            a = attrs[row * 32 + col]
            px[col, row] = attr_to_paper_rgb(a)
    return img


def render_attrs_scaled(attrs: list[int], scale: int = 8) -> "Image.Image":
    img = render_attrs(attrs)
    return img.resize((32 * scale, 24 * scale))


# ── Coarse pixel render (for visual sanity, not pixel-diff) ──────────

def render_coarse_pixels(state: dict) -> "Image.Image":
    """256×192 pixel render. Body cells fully green, cap cells fully
    black, sky cells cyan, ground green. Bird cell drawn as a yellow
    box. Useful for eyeballing pipe positions, NOT for pixel diff."""
    from PIL import Image
    attrs = build_expected_attrs(state)
    img = Image.new("RGB", (256, 192))
    px = img.load()
    for row in range(24):
        for col in range(32):
            a = attrs[row * 32 + col]
            color = attr_to_paper_rgb(a)
            for y in range(8):
                for x in range(8):
                    px[col * 8 + x, row * 8 + y] = color
    return img


# ── Main ──────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="refrender.py", description=__doc__)
    p.add_argument("sna", type=Path, help="snapshot to read state from")
    p.add_argument("out", type=Path, help="output PNG")
    p.add_argument("--mode", choices=("attrs", "attrs8", "coarse"),
                   default="attrs8",
                   help="attrs: 32x24 1px/cell. attrs8: 256x192 8x scaled. "
                        "coarse: 256x192 paper colour per cell (default attrs8).")
    p.add_argument("--dump", action="store_true",
                   help="also print pipe_state + bird state to stdout")
    args = p.parse_args(argv)

    data = load_sna(args.sna)
    state = read_state(data)

    if args.dump:
        print(f"prep_pipe_idx: {state['prep_idx']}")
        for i, pp in enumerate(state["pipes"]):
            marker = " (prep)" if i == state["prep_idx"] else ""
            gy = pp["gap_y"]
            kt = (gy - 1) >> 3 if gy else "?"
            kb = (gy + 48) >> 3 if gy else "?"
            print(f"  pipe {i}: byte_x={pp['byte_x']:>2}  gap_y={gy:>3}"
                  f"  K_top={kt} K_bot={kb}{marker}")
        print(f"bird_y_hi: {state['bird_y_hi']}  (row {(state['bird_y_hi']+4)>>3})")

    if args.mode == "attrs":
        img = render_attrs(build_expected_attrs(state))
    elif args.mode == "attrs8":
        img = render_attrs_scaled(build_expected_attrs(state), 8)
    else:
        img = render_coarse_pixels(state)

    img.save(args.out)
    print(f"wrote {args.out} ({img.size[0]}x{img.size[1]}, mode={args.mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
