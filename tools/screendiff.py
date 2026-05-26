#!/usr/bin/env python3
"""screendiff.py — visual diff for Speccy Flappy Bird.

Two modes:

  ATTR DIFF (default) — diff EXPECTED attrs (computed by refrender's
  build_expected_attrs from state) vs ACTUAL attrs (read directly from
  $5800 in the snapshot). This is the diagnostic mode for "are pipes
  positioned correctly?" — no PNG paper-sampling errors.

      screendiff.py build/snapshot.szx [--diff-png /tmp/diff.png]

  PIXEL DIFF — full 256x192 pixel comparison between two PNGs (e.g.
  actual screen vs refrender --mode coarse). Mismatched pixels go red.

      screendiff.py --pixel /tmp/actual.png /tmp/expected.png /tmp/diff.png

Attr diff output: 32×24 scaled 8x = 256×192 PNG. Cells that match are
dimmed grey (using the actual paper colour); cells that differ are
solid red, with a tiny centre square showing the EXPECTED paper colour.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snadump import load_sna, addr_range
from refrender import (
    read_state, build_expected_attrs, attr_to_paper_rgb,
    ATTR_SKY, ATTR_PIPE, ATTR_BUFFER, ATTR_BIRD, ATTR_GROUND,
)


ATTR_NAMES = {
    ATTR_SKY:    "SKY",
    ATTR_PIPE:   "PIPE/GND",
    ATTR_BUFFER: "BUFFER",
    ATTR_BIRD:   "BIRD",
}


def attr_label(a: int) -> str:
    if a in ATTR_NAMES:
        return ATTR_NAMES[a]
    return f"${a:02X}"


def cmd_attr_diff(sna_path: Path, diff_png: Path | None) -> int:
    data = load_sna(sna_path)
    state = read_state(data)
    expected = build_expected_attrs(state)
    actual = list(addr_range(data, 0x5800, 768))

    diffs = []
    for row in range(24):
        for col in range(32):
            idx = row * 32 + col
            if actual[idx] != expected[idx]:
                diffs.append((col, row, actual[idx], expected[idx]))

    print(f"attr diffs: {len(diffs)} / 768")
    if diffs:
        print()
        print(f"{'cell':>7}  {'actual':>14}  {'expected':>14}")
        for col, row, a, e in diffs[:80]:
            print(f"  ({col:2d},{row:2d})  ${a:02X} {attr_label(a):>8}  "
                  f"${e:02X} {attr_label(e):>8}")
        if len(diffs) > 80:
            print(f"  ... and {len(diffs) - 80} more (see diff PNG)")

    if diff_png is not None:
        from PIL import Image, ImageDraw
        out = Image.new("RGB", (32 * 8, 24 * 8))
        draw = ImageDraw.Draw(out)
        diffset = {(c, r) for c, r, _, _ in diffs}
        for row in range(24):
            for col in range(32):
                x0, y0 = col * 8, row * 8
                idx = row * 32 + col
                if (col, row) in diffset:
                    draw.rectangle((x0, y0, x0 + 7, y0 + 7), fill=(255, 0, 0))
                    ec = attr_to_paper_rgb(expected[idx])
                    draw.rectangle((x0 + 3, y0 + 3, x0 + 4, y0 + 4), fill=ec)
                else:
                    ac = attr_to_paper_rgb(actual[idx])
                    g = (ac[0] + ac[1] + ac[2]) // 6
                    draw.rectangle((x0, y0, x0 + 7, y0 + 7), fill=(g, g, g))
        out.save(diff_png)
        print(f"wrote diff PNG to {diff_png}")

    return 0 if not diffs else 1


def cmd_pixel_diff(actual_png: Path, expected_png: Path, diff_png: Path) -> int:
    from PIL import Image
    actual = Image.open(actual_png).convert("RGB")
    expected = Image.open(expected_png).convert("RGB")
    if actual.size != (256, 192) or expected.size != (256, 192):
        sys.exit("--pixel requires both inputs to be 256x192")
    a_px = actual.load()
    e_px = expected.load()
    out = Image.new("RGB", (256, 192))
    op = out.load()
    diffs = 0
    for y in range(192):
        for x in range(256):
            if a_px[x, y] == e_px[x, y]:
                g = (a_px[x, y][0] + a_px[x, y][1] + a_px[x, y][2]) // 6
                op[x, y] = (g, g, g)
            else:
                op[x, y] = (255, 0, 0)
                diffs += 1
    out.save(diff_png)
    print(f"pixel diffs: {diffs} / {256*192}")
    return 0 if diffs == 0 else 1


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="screendiff.py", description=__doc__)
    p.add_argument("--pixel", action="store_true",
                   help="full-pixel diff (positional args become "
                        "actual.png expected.png diff.png)")
    p.add_argument("args", nargs="+")
    p.add_argument("--diff-png", type=Path,
                   help="(attr mode) write diff visualisation here")
    args = p.parse_args(argv)

    if args.pixel:
        if len(args.args) != 3:
            sys.exit("--pixel needs: actual.png expected.png diff.png")
        return cmd_pixel_diff(Path(args.args[0]), Path(args.args[1]), Path(args.args[2]))

    if len(args.args) != 1:
        sys.exit("attr mode needs: snapshot.[sna|szx]")
    return cmd_attr_diff(Path(args.args[0]), args.diff_png)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
