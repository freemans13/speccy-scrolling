#!/usr/bin/env python3
"""runsim.py — headless Z80 emulator: load SNA, run for N frames, save SNA.

Uses skoolkit's Simulator (pip install skoolkit). Run from a venv with
skoolkit available, e.g.:

    /tmp/emuvenv/bin/python tools/runsim.py build/main.sna 60

Args: SNA_FILE FRAMES
"""
import sys

from skoolkit.snapshot import SNA
from skoolkit.simulator import Simulator
from skoolkit.simutils import REGISTERS, T, IFF, IM

FRAME_TSTATES = 69888   # 48K Spectrum: T-states per 50Hz frame


ROM_PATHS = [
    '/Applications/Fuse.app/Contents/Resources/48.rom',
    '/usr/local/share/fuse/48.rom',
]


def load_rom():
    for p in ROM_PATHS:
        try:
            with open(p, 'rb') as f:
                rom = list(f.read())
            if len(rom) == 16384:
                return rom
        except FileNotFoundError:
            continue
    raise SystemExit('Could not find 48k ROM. Set ROM_PATHS in runsim.py.')


def load_sna(path):
    """Return (memory, pc, sp, raw_snap)."""
    s = SNA.get(path)
    if len(s.tail) != 49152:
        raise SystemExit(f'{path}: not a 48K SNA snapshot')
    mem = load_rom() + list(s.tail)
    pc = mem[s.sp] | (mem[s.sp + 1] << 8)
    # Pop PC off stack
    mem[s.sp] = 0
    mem[s.sp + 1] = 0
    sp = (s.sp + 2) & 0xFFFF
    return mem, pc, sp, s


def make_register_dict(pc, sp, s):
    return {
        'A': s.a, 'F': s.f,
        'B': s.bc >> 8, 'C': s.bc & 0xFF,
        'D': s.de >> 8, 'E': s.de & 0xFF,
        'H': s.hl >> 8, 'L': s.hl & 0xFF,
        'IX': s.ix, 'IY': s.iy,
        'SP': sp,
        'I': s.i, 'R': s.r,
        '^A': s.a2, '^F': s.f2,
        '^B': s.bc2 >> 8, '^C': s.bc2 & 0xFF,
        '^D': s.de2 >> 8, '^E': s.de2 & 0xFF,
        '^H': s.hl2 >> 8, '^L': s.hl2 & 0xFF,
        'PC': pc,
    }


def run_frames(sim, n_frames):
    opcodes = sim.opcodes
    memory = sim.memory
    regs = sim.registers
    frame_dur = sim.frame_duration
    int_active = sim.int_active
    target = regs[T] + n_frames * frame_dur
    while regs[T] < target:
        pc_before = regs[REGISTERS['PC']]
        opcodes[memory[pc_before]]()
        if regs[IFF] and regs[T] % frame_dur < int_active:
            sim.accept_interrupt(regs, memory, pc_before)


def save_sna(path, mem, regs):
    pc = regs[REGISTERS['PC']]
    sp = regs[REGISTERS['SP']]
    sp = (sp - 2) & 0xFFFF
    mem[sp] = pc & 0xFF
    mem[sp + 1] = (pc >> 8) & 0xFF

    iff = regs[IFF] & 1
    a, f = regs[REGISTERS['A']], regs[REGISTERS['F']]
    bc = (regs[REGISTERS['B']] << 8) | regs[REGISTERS['C']]
    de = (regs[REGISTERS['D']] << 8) | regs[REGISTERS['E']]
    hl = (regs[REGISTERS['H']] << 8) | regs[REGISTERS['L']]
    ix = (regs[REGISTERS['IXh']] << 8) | regs[REGISTERS['IXl']]
    iy = (regs[REGISTERS['IYh']] << 8) | regs[REGISTERS['IYl']]
    a2, f2 = regs[REGISTERS['^A']], regs[REGISTERS['^F']]
    bc2 = (regs[REGISTERS['^B']] << 8) | regs[REGISTERS['^C']]
    de2 = (regs[REGISTERS['^D']] << 8) | regs[REGISTERS['^E']]
    hl2 = (regs[REGISTERS['^H']] << 8) | regs[REGISTERS['^L']]

    header = bytearray(27)
    header[0] = regs[REGISTERS['I']]
    header[1] = hl2 & 0xFF; header[2] = hl2 >> 8
    header[3] = de2 & 0xFF; header[4] = de2 >> 8
    header[5] = bc2 & 0xFF; header[6] = bc2 >> 8
    header[7] = f2
    header[8] = a2
    header[9] = hl & 0xFF; header[10] = hl >> 8
    header[11] = de & 0xFF; header[12] = de >> 8
    header[13] = bc & 0xFF; header[14] = bc >> 8
    header[15] = iy & 0xFF; header[16] = iy >> 8
    header[17] = ix & 0xFF; header[18] = ix >> 8
    header[19] = 0x04 if iff else 0x00
    header[20] = regs[REGISTERS['R']]
    header[21] = f
    header[22] = a
    header[23] = sp & 0xFF; header[24] = sp >> 8
    header[25] = regs[IM]
    header[26] = 0

    with open(path, 'wb') as f:
        f.write(bytes(header))
        f.write(bytes(mem[16384:65536]))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    n_frames = int(sys.argv[2])

    mem, pc, sp, s = load_sna(path)
    reg_dict = make_register_dict(pc, sp, s)
    state = {'iff': 1 if s.iff1 else 0, 'im': s.im, 'tstates': 0}
    sim = Simulator(mem, reg_dict, state)

    print(f'Loaded {path}: PC=${pc:04X}, SP=${sp:04X}, IFF={s.iff1}, IM={s.im}')
    print(f'Running {n_frames} frames ({n_frames * FRAME_TSTATES} T-states)...')
    run_frames(sim, n_frames)
    final_pc = sim.registers[REGISTERS['PC']]
    print(f'Done. PC=${final_pc:04X}, T-states elapsed={sim.registers[T]}')

    save_sna(path, mem, sim.registers)
    print(f'Saved back to {path}')


if __name__ == '__main__':
    main()
