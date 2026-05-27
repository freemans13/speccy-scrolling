#!/usr/bin/env python3
"""runsim_until.py — run the headless emulator until a predicate fires,
then save the snapshot at that exact moment.

Predicates (combine freely; ALL must be true to stop):
  --frames N            stop after N completed frames (mandatory ceiling)
  --score N             stop when score word at $81B5 reaches N
  --score-ge N          stop when score word at $81B5 >= N
  --pipe N:byte_x=X     stop when pipe N's byte_x equals X
  --pipe N:gap_y=Y      stop when pipe N's gap_y equals Y
  --first-swap          stop the frame do_swap_just_fired becomes 1
  --first-wrap          stop on the first frame wrap_pending becomes 1
  --prep-idx N          stop when prep_pipe_idx == N

Each frame the script polls the predicate. When it fires, it saves
the SNA to the output path. If --frames is reached without firing,
it still saves and reports "predicate not met".

Usage:
  runsim_until.py IN_SNA OUT_SNA --frames 1000 --score 3
  runsim_until.py IN_SNA OUT_SNA --frames 500 --first-swap
  runsim_until.py IN_SNA OUT_SNA --frames 2000 --pipe 0:byte_x=11
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Reuse runsim's loader/saver
sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import (
    FRAME_TSTATES, load_sna, make_register_dict, save_sna,
)
from skoolkit.cmiosimulator import CMIOSimulator as Simulator
from skoolkit.simutils import REGISTERS, T, IFF

# Memory addresses — auto-loaded from build/main.lst (defaults are last-
# known-good and will be overridden if the .lst is present). Always
# regenerate the .lst after any build change:
#   tools/sjasmplus/sjasmplus --fullpath --lst=build/main.lst src/main.asm
PIPE_STATE         = 0x81A4
SCORE              = 0x81B8
PREP_PIPE_IDX      = 0x81FB
ACTIVATE_PIPE_IDX  = 0x81FC
DO_SWAP_JUST_FIRED = 0x81FD


def _load_lst_symbols():
    import re
    repo_root = Path(__file__).resolve().parent.parent
    lst_path = repo_root / "build" / "main.lst"
    if not lst_path.exists():
        return
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+(\w+):", re.IGNORECASE)
    name_to_glob = {
        "pipe_state": "PIPE_STATE",
        "score": "SCORE",
        "prep_pipe_idx": "PREP_PIPE_IDX",
        "activate_pipe_idx": "ACTIVATE_PIPE_IDX",
        "do_swap_just_fired": "DO_SWAP_JUST_FIRED",
    }
    globs = globals()
    try:
        for line in lst_path.read_text(errors="ignore").splitlines():
            m = pat.match(line)
            if m and m.group(2) in name_to_glob:
                globs[name_to_glob[m.group(2)]] = int(m.group(1), 16)
    except OSError:
        pass


_load_lst_symbols()


def read_byte(mem, a): return mem[a]
def read_word(mem, a): return mem[a] | (mem[a + 1] << 8)


def parse_pipe(spec: str):
    """e.g. '0:byte_x=11' -> (0, 'byte_x', 11)"""
    pipe_part, kv = spec.split(":")
    field, val = kv.split("=")
    if field not in ("byte_x", "gap_y"):
        sys.exit(f"--pipe: bad field {field!r}, must be byte_x or gap_y")
    return int(pipe_part), field, int(val)


def make_predicate(args):
    preds = []
    if args.score is not None:
        preds.append(("score == %d" % args.score,
                      lambda mem: read_word(mem, SCORE) == args.score))
    if args.score_ge is not None:
        preds.append(("score >= %d" % args.score_ge,
                      lambda mem: read_word(mem, SCORE) >= args.score_ge))
    for spec in args.pipe or []:
        idx, field, val = parse_pipe(spec)
        off = 0 if field == "byte_x" else 1
        preds.append((f"pipe[{idx}].{field} == {val}",
                      lambda mem, i=idx, o=off, v=val: read_byte(mem, PIPE_STATE + i * 2 + o) == v))
    if args.prep_idx is not None:
        preds.append((f"prep_pipe_idx == {args.prep_idx}",
                      lambda mem: read_byte(mem, PREP_PIPE_IDX) == args.prep_idx))
    if args.first_swap:
        preds.append(("do_swap_just_fired == 1",
                      lambda mem: read_byte(mem, DO_SWAP_JUST_FIRED) == 1))
    if not preds:
        return None, "no predicate — running --frames frames then saving"
    desc = " AND ".join(d for d, _ in preds)
    fns = [f for _, f in preds]
    return (lambda mem: all(fn(mem) for fn in fns)), desc


def run_until(sim, max_frames: int, predicate, poll_per_frame: bool = True):
    """Run up to max_frames frames. Poll predicate after each accepted
    interrupt (= frame boundary). Returns (fired_frame, total_frames).
    Predicate may be None — in which case runs max_frames and returns."""
    opcodes = sim.opcodes
    memory = sim.memory
    regs = sim.registers
    frame_dur = sim.frame_duration
    int_active = sim.int_active
    target = regs[T] + max_frames * frame_dur

    completed = 0
    fired = None
    while regs[T] < target:
        pc_before = regs[REGISTERS['PC']]
        opcodes[memory[pc_before]]()
        if regs[IFF] and regs[T] % frame_dur < int_active:
            sim.accept_interrupt(regs, memory, pc_before)
            completed += 1
            if predicate is not None and predicate(memory):
                fired = completed
                break
    return fired, completed


def main():
    p = argparse.ArgumentParser(prog="runsim_until.py", description=__doc__)
    p.add_argument("in_sna", type=Path)
    p.add_argument("out_sna", type=Path)
    p.add_argument("--frames", type=int, required=True,
                   help="max frames to run (mandatory ceiling)")
    p.add_argument("--score", type=int)
    p.add_argument("--score-ge", type=int)
    p.add_argument("--pipe", action="append",
                   help="e.g. 0:byte_x=11 (repeatable; ALL must match)")
    p.add_argument("--prep-idx", type=int)
    p.add_argument("--first-swap", action="store_true")
    args = p.parse_args()

    mem, pc, sp, s = load_sna(str(args.in_sna))
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    predicate, desc = make_predicate(args)
    print(f"loaded {args.in_sna}: PC=${pc:04X}, SP=${sp:04X}")
    print(f"predicate: {desc}")
    print(f"running up to {args.frames} frames "
          f"({args.frames * FRAME_TSTATES} T-states)...")

    fired, completed = run_until(sim, args.frames, predicate)
    print(f"completed {completed} frames", end="")
    if fired is not None:
        print(f"  ← predicate fired at frame {fired}")
    else:
        print("  ← predicate NOT met within frame budget")

    save_sna(str(args.out_sna), mem, sim.registers)
    print(f"saved snapshot to {args.out_sna}")
    return 0 if fired is not None or predicate is None else 2


if __name__ == "__main__":
    sys.exit(main())
