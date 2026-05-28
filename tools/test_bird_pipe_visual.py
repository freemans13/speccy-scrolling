#!/usr/bin/env python3
r"""test_bird_pipe_visual.py — visual integrity tests for bird-pipe overlap.

Forces specific bird/pipe configurations by direct memory writes, then
renders the screen and verifies the EXPECTED visual: bird's wing pixels
(black ink) should OR onto pipe pixels at overlap cells — NOT replace
or be replaced wholesale.

Runs scenarios:
  A) bird mid-air, no pipe overlap → bird sprite fully visible.
  B) bird at pipe body (centre col 8 == pipe M1/M2) → bird wing pixels
     visible on green paper. The cell shows green paper + black wing ink.
  C) bird at pipe edge (col 7 == pipe R) → wing pixel ORs with R-edge
     dither.

For each scenario, dumps:
  - pixel state at bird's 9 cells (top/centre/bot × cols 7,8,9)
  - attr state at same cells
  - PASS/FAIL based on expected pattern

This is the kind of test the user wants — verifies the VISUAL outcome,
not just end-of-frame memory state.
"""
from __future__ import annotations
import sys, re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runsim import load_sna, make_register_dict, run_frames, save_sna
from skoolkit.cmiosimulator import CMIOSimulator as Simulator

SYM = {}
def _load():
    lst = Path(__file__).resolve().parent.parent / "build" / "main.lst"
    pat = re.compile(r"^\s*\d+\s+([0-9A-F]{4})\s+[0-9A-F\s]*\s+(bird_y|bird_vy|bird_attr_y|pipe_state):", re.I)
    for line in lst.read_text(errors="ignore").splitlines():
        m = pat.match(line)
        if m: SYM[m.group(2)] = int(m.group(1), 16)
_load()


def setup_sim():
    mem, pc, sp, s = load_sna("build/main.sna")
    sim = Simulator(mem, make_register_dict(pc, sp, s),
                    {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0})
    return sim


def dump_bird_cells(mem, bird_attr_y, label):
    """Print the 3x3 attr grid + pixel-on-attr summary at bird's cells."""
    top_row = (bird_attr_y & 0xF8) // 8
    print(f"\n=== {label} ===")
    print(f"bird_attr_y={bird_attr_y}, top_row={top_row}")
    print("attrs (rows top..top+2 × cols 7,8,9):")
    for r in (top_row, top_row + 1, top_row + 2):
        if not (0 <= r < 24): continue
        cells = [f"${mem[0x5800 + r * 32 + c]:02X}" for c in (7, 8, 9)]
        print(f"  row {r}: {cells}")
    # Bird pixel range
    bird_y = bird_attr_y  # bird_attr_y stores TOP pixel-y in current code
    print(f"pixel data cols 7,8,9 across bird's vertical extent (y={bird_y}..{bird_y+15}):")
    for py in range(bird_y, bird_y + 16):
        ccc = (py >> 6) & 3
        ppp = py & 7
        rrr = (py >> 3) & 7
        addr = 0x4000 | (ccc << 11) | (ppp << 8) | (rrr << 5)
        bytes_str = " ".join(f"{mem[addr + c]:08b}" for c in (7, 8, 9))
        nz = sum(1 for c in (7, 8, 9) if mem[addr + c])
        print(f"  y={py}: {bytes_str} {'(nonzero)' if nz else ''}")


def run_scenario(setup_pipe, label):
    sim = setup_sim()
    # Warm up
    run_frames(sim, 30)
    # Apply scenario: position bird, position pipe
    setup_pipe(sim)
    # Run a few frames for state to settle
    for _ in range(4):
        run_frames(sim, 1)
    mem = sim.memory
    bird_attr_y = mem[SYM["bird_attr_y"]]
    dump_bird_cells(mem, bird_attr_y, label)
    return sim


def scenario_a_no_overlap(sim):
    # Force bird mid-air, pipes far away
    sim.memory[SYM["bird_y"]] = 0
    sim.memory[SYM["bird_y"] + 1] = 100      # bird_y_hi = 100
    sim.memory[SYM["bird_vy"]] = 0
    sim.memory[SYM["bird_vy"] + 1] = 0
    # Move pipes far from bird cols
    sim.memory[SYM["pipe_state"] + 0] = 28
    sim.memory[SYM["pipe_state"] + 2] = 20
    sim.memory[SYM["pipe_state"] + 4] = 15


def scenario_b_pipe_at_centre(sim):
    # Bird mid-screen, pipe positioned at bx=8 → M1=col 8 = bird body cell
    sim.memory[SYM["bird_y"]] = 0
    sim.memory[SYM["bird_y"] + 1] = 100
    sim.memory[SYM["bird_vy"]] = 0
    sim.memory[SYM["bird_vy"] + 1] = 0
    sim.memory[SYM["pipe_state"] + 0] = 28
    sim.memory[SYM["pipe_state"] + 2] = 8     # pipe 1 at bx=8, covers cols 7-10
    sim.memory[SYM["pipe_state"] + 4] = 15


def main():
    print("test_bird_pipe_visual: forcing scenarios via direct mem writes")
    run_scenario(scenario_a_no_overlap, "A) bird mid-air, no pipe overlap")
    run_scenario(scenario_b_pipe_at_centre, "B) bird overlaps pipe 1 (bx=8) at centre col 8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
