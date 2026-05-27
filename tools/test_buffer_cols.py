#!/usr/bin/env python3
r"""test_buffer_cols.py — verify buffer cols always have ATTR_BUFFER ($2D).

The left buffer band (cols 0..3) and right buffer band (cols 28..31)
must ALWAYS be paper=cyan AND ink=cyan ($2D) so any pipe pixels
scrolling through these cols are invisible. If any routine accidentally
overwrites these cols with a different attr, pipe-leaving-screen pixels
become visible — the user sees "pipes peeking out" at the screen edges.

This test runs the headless sim through 4 fixed checkpoints + a
continuous frame-by-frame sweep, and at every frame asserts that all
buffer-col cells (rows 0..19, cols 0..3 and 28..31) hold $2D.

Exit 0 on success, non-zero on first failure. Reports the first
offending (col, row, frame) tuple.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna as runsim_load_sna, make_register_dict
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T, IFF

ATTR_BUFFER = 0x2D
BUFFER_COLS = list(range(0, 4)) + list(range(28, 32))
NUM_PLAYFIELD_ROWS = 20

CHECKPOINTS = [50, 200, 500, 1000]
CONTINUOUS_RANGE = (1000, 4000)


def run_to_frame(sim, n):
    opcodes = sim.opcodes
    memory = sim.memory
    regs = sim.registers
    frame_dur = sim.frame_duration
    int_active = sim.int_active
    accepted = 0
    max_t = regs[T] + (n + 30) * frame_dur
    while accepted < n and regs[T] < max_t:
        pc_before = regs[REGISTERS['PC']]
        opcodes[memory[pc_before]]()
        if regs[IFF] and regs[T] % frame_dur < int_active:
            sim.accept_interrupt(regs, memory, pc_before)
            accepted += 1
    return accepted


def check_frame(memory):
    """Return list of (col, row, actual) for any buffer cell not $2D."""
    fails = []
    for row in range(NUM_PLAYFIELD_ROWS):
        for col in BUFFER_COLS:
            actual = memory[0x5800 + row * 32 + col]
            if actual != ATTR_BUFFER:
                fails.append((col, row, actual))
    return fails


def main():
    sna_path = "build/main.sna"
    mem, pc, sp, s = runsim_load_sna(sna_path)
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    print(f"test_buffer_cols: checking BUFFER cells "
          f"(cols 0..3 + 28..31, rows 0..{NUM_PLAYFIELD_ROWS-1}) "
          f"stay at $2D")

    last = 0
    total_fails = 0

    for target in CHECKPOINTS:
        run_to_frame(sim, target - last)
        last = target
        memory = bytes(sim.memory[:0x10000])
        fails = check_frame(memory)
        if not fails:
            print(f"  PASS checkpoint frame {target}")
        else:
            print(f"  FAIL checkpoint frame {target}: {len(fails)} buffer cells corrupted")
            for col, row, actual in fails[:10]:
                print(f"    ({col:2d},{row:2d}) actual=${actual:02X} expected=$2D")
            total_fails += len(fails)

    lo, hi = CONTINUOUS_RANGE
    if last < lo:
        run_to_frame(sim, lo - last)
        last = lo
    print(f"  continuous sweep: frames {last}..{hi}")
    bad_frames = []
    first_detail = None
    while last < hi:
        run_to_frame(sim, 1)
        last += 1
        memory = bytes(sim.memory[:0x10000])
        fails = check_frame(memory)
        if fails:
            bad_frames.append(last)
            if first_detail is None:
                first_detail = (last, fails[:10])
    if bad_frames:
        print(f"  FAIL continuous: {len(bad_frames)} bad frames")
        first_fr, sample = first_detail
        print(f"  first failing frame {first_fr}:")
        for col, row, actual in sample:
            print(f"    ({col:2d},{row:2d}) actual=${actual:02X} expected=$2D")
        total_fails += sum(len(check_frame(bytes(sim.memory[:0x10000]))) for _ in [None])

    if total_fails:
        return 1
    print("PASS: all buffer cells stayed at $2D")
    return 0


if __name__ == "__main__":
    sys.exit(main())
