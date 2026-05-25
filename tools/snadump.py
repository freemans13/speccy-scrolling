#!/usr/bin/env python3
"""snadump.py — diagnostic tooling for Speccy Flappy Bird .sna snapshots.

Subcommands:
  screen <sna> <out.png>   Decode the screen file ($4000..$5AFF) to a PNG.
  border <sna>             Per-frame border-profiler timeline (overrun flagged).
  mem    <sna> <addr> <n>  Hex-dump n bytes starting at Spectrum address <addr>.
  grid   <sna>             Per-band first-bytes view of PIPE_PROGRAM ($DB00..$F400).

SNA format (48K, 49179 bytes):
  Bytes 0..26    Z80 registers: I, HL', DE', BC', AF', HL, DE, BC, IY, IX,
                 IFF2, R, AF, SP, IM, border.
  Bytes 27..    48 KB of RAM starting at $4000.

Addresses are reported in Spectrum address space ($4000..$FFFF). To read a
byte at address A use sna[27 + (A - 0x4000)].

Symbols are hard-coded for v1; update them here if the relevant labels move.
You can verify current values from `build/main.lst`:
    grep -E 'diag_frame_counter|diag_border_log_ptr|DIAG_BORDER_LOG' build/main.lst
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# ─── Symbol addresses — loaded from build/main.lst at startup ─────────────
SYM = {
    "DIAG_BORDER_LOG":     0xFE00,     # EQU — fixed
    "DIAG_BORDER_LOG_LEN": 512,        # 128 entries × 4 bytes (color, frame_lo, R, pad)
    "PIPE_PROGRAM":        0xDB00,
    "SLOT_GRID_END":       0xF400,
    "BAND_STRIDE":         80,
    "NUM_BANDS":           80,
}

def _load_lst_symbols():
    """Read build/main.lst and override moving label addresses in SYM."""
    import re
    repo_root = Path(__file__).resolve().parent.parent
    lst_path = repo_root / "build" / "main.lst"
    if not lst_path.exists():
        return
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+(\w+):", re.IGNORECASE)
    wanted = {"diag_frame_counter", "diag_border_log_ptr"}
    try:
        for line in lst_path.read_text(errors="ignore").splitlines():
            m = pat.match(line)
            if m and m.group(2) in wanted:
                SYM[m.group(2)] = int(m.group(1), 16)
    except OSError:
        pass

_load_lst_symbols()

# Color → name (Spectrum border port lower 3 bits)
COLOR_NAMES = {
    0: "BLACK",
    1: "BLUE",
    2: "RED",
    3: "MAGENTA",
    4: "GREEN",
    5: "CYAN",
    6: "YELLOW",
    7: "WHITE",
}

# Marker-bandwidth labels we use in main_loop / frame_update.
COLOR_TAGS = {
    2: "top-blank",
    3: "PIPE_PROGRAM",
    1: "blue/sfx",          # also written by sfx speaker (with border=1)
    4: "ground",
    7: "white-state",
    5: "cyan-cap-imm",
    6: "yellow-rebuild",
    0: "idle",
}

SNA_HEADER = 27
SNA_RAM_BASE = 0x4000
SNA_SIZE = 49179


# ─── helpers ─────────────────────────────────────────────────────────────

def load_sna(path: Path) -> bytes:
    """Load .sna or .szx and return a 49179-byte SNA-style buffer (27-byte
    header + 48K RAM). For .szx we synthesise a zero header — only RAM is
    used downstream."""
    raw = path.read_bytes()
    # .sna 48K is exactly 49179 bytes — direct.
    if len(raw) == SNA_SIZE and path.suffix.lower() == ".sna":
        return raw
    # Otherwise try skoolkit (handles .sna, .szx, .z80 transparently).
    try:
        from skoolkit.snapshot import Snapshot
    except ImportError:
        sys.exit(f"error: {path} is not a 48K .sna and skoolkit not installed. "
                 "Run: /tmp/emuvenv/bin/pip install skoolkit")
    s = Snapshot.get(str(path))
    ram = bytes(s.ram())
    if len(ram) != 49152:
        sys.exit(f"error: {path}: snapshot RAM is {len(ram)} bytes (expected 49152, 48K only)")
    return bytes(27) + ram


def addr(data: bytes, a: int) -> int:
    """Read a single byte at Spectrum address `a`."""
    if a < SNA_RAM_BASE or a > 0xFFFF:
        sys.exit(f"error: address ${a:04X} outside RAM range $4000..$FFFF")
    return data[SNA_HEADER + (a - SNA_RAM_BASE)]


def addr_word(data: bytes, a: int) -> int:
    return addr(data, a) | (addr(data, a + 1) << 8)


def addr_range(data: bytes, a: int, n: int) -> bytes:
    off = SNA_HEADER + (a - SNA_RAM_BASE)
    return data[off:off + n]


# ─── screen ──────────────────────────────────────────────────────────────

def cmd_screen(sna_path: Path, out_path: Path) -> None:
    try:
        from PIL import Image
    except ImportError:
        sys.exit("error: Pillow not installed. Run: pip3 install Pillow")
    data = load_sna(sna_path)
    pixels = addr_range(data, 0x4000, 0x1800)          # 6144 bytes
    attrs  = addr_range(data, 0x5800, 0x300)           # 768 bytes

    # Spectrum palette (non-bright). Bright is +brightness scaled.
    base = [
        (0, 0, 0), (0, 0, 192), (192, 0, 0), (192, 0, 192),
        (0, 192, 0), (0, 192, 192), (192, 192, 0), (192, 192, 192),
    ]
    bright_pal = [
        (0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
        (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255),
    ]

    img = Image.new("RGB", (256, 192))
    px = img.load()
    for y in range(192):
        # ZX screen address scramble: y = ccrrrppp
        ccc = (y >> 6) & 0x3
        ppp = y & 0x7
        rrr = (y >> 3) & 0x7
        row_addr = (ccc << 11) | (ppp << 8) | (rrr << 5)
        attr_row = y >> 3
        for col in range(32):
            byte = pixels[row_addr + col]
            attr = attrs[attr_row * 32 + col]
            ink_idx = attr & 0x7
            paper_idx = (attr >> 3) & 0x7
            bright = (attr & 0x40) != 0
            pal = bright_pal if bright else base
            ink_rgb = pal[ink_idx]
            paper_rgb = pal[paper_idx]
            for bit in range(8):
                set_bit = (byte >> (7 - bit)) & 1
                px[col * 8 + bit, y] = ink_rgb if set_bit else paper_rgb

    img.save(out_path)
    print(f"wrote {out_path} (256x192)")


# ─── border ──────────────────────────────────────────────────────────────

def cmd_border(sna_path: Path) -> None:
    data = load_sna(sna_path)
    head_ptr = addr_word(data, SYM["diag_border_log_ptr"])
    cur_frame = addr(data, SYM["diag_frame_counter"])
    ring = addr_range(data, SYM["DIAG_BORDER_LOG"], SYM["DIAG_BORDER_LOG_LEN"])

    log_base = SYM["DIAG_BORDER_LOG"]
    log_end  = log_base + SYM["DIAG_BORDER_LOG_LEN"]

    print(f"frame_counter (lo8): {cur_frame}")
    head_off = (head_ptr - log_base) if (log_base <= head_ptr < log_end) else None
    print(f"head_ptr:            ${head_ptr:04X}"
          + (f"  (offset {head_off})" if head_off is not None else "  (BAD — outside ring)"))
    print()

    if head_off is None:
        print("(head pointer is outside the ring — snapshot may be corrupt "
              "or the symbol address is stale)")
        return

    # Detect "never run" case: head still at base AND frame counter 0
    # AND buffer is all zeros.
    if cur_frame == 0 and head_ptr == log_base and all(b == 0 for b in ring):
        print("(ring buffer empty — game has not completed a halt yet)")
        return

    # Each entry is 4 bytes: color, frame_lo, R, pad. Ring = 128 entries.
    ENTRY = 4
    n_entries = SYM["DIAG_BORDER_LOG_LEN"] // ENTRY
    raw = []
    for i in range(n_entries):
        idx = (head_off + i * ENTRY) % SYM["DIAG_BORDER_LOG_LEN"]
        color = ring[idx]
        frame_lo = ring[idx + 1]
        r_reg = ring[idx + 2]
        raw.append((color, frame_lo, r_reg))

    # Drop the leading unwritten run (color=0 AND frame_lo=0 AND R=0).
    trim = 0
    for color, fr, r in raw:
        if color == 0 and fr == 0 and r == 0:
            trim += 1
        else:
            break
    entries = raw[trim:]

    if not entries:
        print("(ring buffer empty — game has not completed a halt yet)")
        return

    # Group entries by frame.
    frames: list[tuple[int, list[tuple[int, int, int]]]] = []
    cur_frame_idx = None
    cur_list: list[tuple[int, int, int]] = []
    for color, fr, r in entries:
        if cur_frame_idx is None or fr != cur_frame_idx:
            if cur_frame_idx is not None:
                frames.append((cur_frame_idx, cur_list))
            cur_frame_idx = fr
            cur_list = []
        cur_list.append((color, fr, r))
    if cur_frame_idx is not None:
        frames.append((cur_frame_idx, cur_list))

    def r_delta(prev: int, cur: int) -> int:
        """Bits 0-6 of R are the auto-incrementing fetch counter (bit 7 is
        user-controllable). Compute the shortest forward distance in the
        128-step cycle."""
        d = (cur - prev) & 0x7F
        return d

    # Per-region cumulative R-delta from frame's RED (first OUT).
    overrun_count = 0
    print(f"{'frame':>5}  {'sequence and R-delta from RED (each tick ≈ ~14 T)':<60}")
    for fr_id, ev in frames:
        names = []
        base_r = ev[0][2] if ev else 0
        # Cumulative delta from RED across (possibly) multiple wraps.
        cum = 0
        last_r = base_r
        for i, (c, _, r) in enumerate(ev):
            d = r_delta(last_r, r)
            cum += d
            last_r = r
            label = COLOR_NAMES.get(c, f"?{c}")
            names.append(f"{label}@{cum}")
        ends_in_black = ev and ev[-1][0] == 0
        tag = ""
        if not ends_in_black and fr_id != frames[0][0] and fr_id != frames[-1][0]:
            tag = "  [OVERRUN — no BLACK]"
            overrun_count += 1
        elif not ends_in_black:
            tag = "  [partial (edge)]"
        print(f"{fr_id:5d}  {' '.join(names)}{tag}")

    # Per-region variance summary across frames (skipping partial edges).
    print()
    print("Per-region R-delta from RED (min..max across frames):")
    regions: dict[int, list[int]] = {}     # color → list of cumulative deltas across frames
    for fr_id, ev in frames:
        if not (ev and ev[-1][0] == 0):
            continue                        # skip partial/overrun frames for variance
        base_r = ev[0][2]
        cum = 0
        last_r = base_r
        for c, _, r in ev:
            d = r_delta(last_r, r)
            cum += d
            last_r = r
            regions.setdefault(c, []).append(cum)
    for color, vals in regions.items():
        name = COLOR_NAMES.get(color, f"?{color}")
        if not vals:
            continue
        lo, hi = min(vals), max(vals)
        print(f"  {name:<8}  min={lo:4d}  max={hi:4d}  spread={hi - lo:4d}   "
              f"({len(vals)} samples)")

    print()
    print(f"total frames logged: {len(frames)}")
    print(f"overruns:            {overrun_count}")


# ─── mem ────────────────────────────────────────────────────────────────

def cmd_mem(sna_path: Path, address: int, count: int) -> None:
    data = load_sna(sna_path)
    region = addr_range(data, address, count)
    for off in range(0, len(region), 16):
        chunk = region[off:off + 16]
        hex_str = " ".join(f"{b:02X}" for b in chunk)
        ascii_str = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"${address + off:04X}  {hex_str:<48}  {ascii_str}")


# ─── grid ───────────────────────────────────────────────────────────────

def classify_band(first6: bytes) -> str:
    """Return a short label describing the first slot's opcode shape."""
    if not first6:
        return "(empty)"
    op = first6[0]
    if op == 0xDD and len(first6) >= 4 and first6[1] == 0x21:
        target = first6[2] | (first6[3] << 8)
        return f"BODY ix-walk  ld ix,${target:04X}"
    if op == 0x31 and len(first6) >= 3:
        target = first6[1] | (first6[2] << 8)
        return f"CAP/SKIP slot ld sp,${target:04X}"
    if op == 0xC3 and len(first6) >= 3:
        target = first6[1] | (first6[2] << 8)
        return f"CAP_HANDLER  jp ${target:04X}"
    if op == 0x18:
        return f"JR-SKIP +{first6[1] if len(first6) >= 2 else 0}"
    if op == 0x00:
        return "NOP (uninit?)"
    return f"unknown opcode ${op:02X}"


def cmd_grid(sna_path: Path) -> None:
    data = load_sna(sna_path)
    base = SYM["PIPE_PROGRAM"]
    stride = SYM["BAND_STRIDE"]
    n = SYM["NUM_BANDS"]
    print(f"PIPE_PROGRAM grid at ${base:04X}..${base + n*stride:04X}, "
          f"{n} bands × {stride} B")
    print()
    for k in range(n):
        band_addr = base + k * stride
        first = addr_range(data, band_addr, 8)
        pipe = k % 4
        cell = k // 4
        hex6 = " ".join(f"{b:02X}" for b in first[:6])
        print(f"  band {k:2d} cell {cell:2d} pipe {pipe}  ${band_addr:04X}: "
              f"{hex6}   {classify_band(first)}")


# ─── main ───────────────────────────────────────────────────────────────

def parse_addr(s: str) -> int:
    s = s.strip()
    if s.startswith("$"):
        return int(s[1:], 16)
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    if any(c in "abcdefABCDEF" for c in s):
        return int(s, 16)
    return int(s)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="snadump.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s_screen = sub.add_parser("screen", help="decode screen to PNG")
    s_screen.add_argument("sna", type=Path)
    s_screen.add_argument("out", type=Path)

    s_border = sub.add_parser("border", help="per-frame border timeline")
    s_border.add_argument("sna", type=Path)

    s_mem = sub.add_parser("mem", help="hex-dump RAM")
    s_mem.add_argument("sna", type=Path)
    s_mem.add_argument("address", type=parse_addr)
    s_mem.add_argument("count", type=parse_addr)

    s_grid = sub.add_parser("grid", help="dump PIPE_PROGRAM band shapes")
    s_grid.add_argument("sna", type=Path)

    s_tflog = sub.add_parser("tflog", help="analyze runsim OUT($FE) T-state log")
    s_tflog.add_argument("log", type=Path)

    args = p.parse_args(argv)
    if args.cmd == "screen":
        cmd_screen(args.sna, args.out)
    elif args.cmd == "border":
        cmd_border(args.sna)
    elif args.cmd == "mem":
        cmd_mem(args.sna, args.address, args.count)
    elif args.cmd == "grid":
        cmd_grid(args.sna)
    elif args.cmd == "tflog":
        cmd_tflog(args.log)
    else:
        p.print_help()
        return 2
    return 0


def cmd_tflog(log_path: Path) -> None:
    """Parse runsim OUT($FE) log → per-frame T-state offsets of each colour OUT.

    Log lines: `<frame_idx> <T_state> <hex_byte>`.

    Reports:
     - per-frame sequence of (colour, T_offset_from_first_OUT_in_frame)
     - per-region (colour) min/max/spread across frames
    """
    FRAME_T = 69888
    events = []
    for line in log_path.read_text().splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        fr, t, hexb = int(parts[0]), int(parts[1]), int(parts[2], 16)
        events.append((fr, t, hexb))
    if not events:
        print("no events")
        return
    # Group by frame.
    frames = {}
    for fr, t, b in events:
        frames.setdefault(fr, []).append((t, b))
    # Show last 20 complete frames.
    keys = sorted(frames.keys())
    show = keys[-20:]
    print(f"{'frame':>5}  T-offsets from frame-start (T-states; 1 line ≈ 224 T)")
    region_offs: dict[int, list[int]] = {}
    for fr in show:
        ev = frames[fr]
        base = ev[0][0]
        parts = []
        for t, b in ev:
            color = b & 0x07
            off = t - base
            name = COLOR_NAMES.get(color, f"?{color}")
            parts.append(f"{name}@{off}")
            if fr != show[0] and fr != show[-1]:
                region_offs.setdefault(color, []).append(off)
        print(f"{fr:5d}  {' '.join(parts)}")
    print()
    print("Per-region T-offset (min..max across frames):")
    for color, vals in region_offs.items():
        if not vals: continue
        lo, hi = min(vals), max(vals)
        name = COLOR_NAMES.get(color, f"?{color}")
        print(f"  {name:<8}  min={lo:>6}  max={hi:>6}  spread={hi-lo:>6}  ({len(vals)} samples)")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
