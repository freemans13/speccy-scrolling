# PIPE_PROGRAM JP-Skip Optimisation — Design Spec

**Date**: 2026-05-19
**Status**: design approved, awaiting implementation
**Author**: pair-programming with Claude

## Goal

Reduce per-frame PIPE_PROGRAM cost by ~4.5 k T-states by replacing NOP-trailers and NOP-skip slots with JP/JR instructions. Pure code-emission change; no architectural shifts; no visual change.

Measured before: PIPE_PROGRAM ≈ 28 k T/frame. Target after: ≈ 23.5 k T/frame.

## Background

Each row of `PIPE_PROGRAM` (160 rows × 32-byte stride at `$DB00`) is structured:

```
+0     : EXX           (1 byte, 4 T)
+1..6  : slot 0        (6 bytes — body/cap/skip)
+7..12 : slot 1        (6 bytes)
+13..18: slot 2        (6 bytes)
+19..24: slot 3        (6 bytes)
+25..31: pad           (7 NOP bytes, 28 T)
```

Two structural inefficiencies that the Z80 walks through every frame:

1. **7-NOP pad trailer** at offset +25..+31 of every row. The CPU executes 7 NOPs (28 T) before reaching the next row's EXX. Across 154 non-cap rows (the 6 cap rows JP out before reaching the pad) that is **154 × 28 = 4 312 T/frame** of pure idle.

2. **6-NOP cap-skip slots** in the cap-band of every active pipe. `CAP_BLOCK` (the LDI-source for `configure_pipe_slots`) defines its 48 interior rows as `db $00 × 6` per row. At run time each NOP-skip executes 6 × 4 = 24 T. Across 3 active pipes × 48 cap-skip rows = **144 × 24 = 3 456 T/frame** of pure idle.

Both regions are "dead time" — the Z80 advances PC through bytes that do no useful work, just consume cycles until the next live instruction.

## Insight

Both regions can be replaced with a single jump instruction that skips them in one go:

| Region | Current | Replacement | Saving |
|---|---|---|---|
| Pad trailer (per row) | 7 NOPs = 28 T | `JP next_row_EXX` = 10 T | 18 T/row |
| Cap-skip slot (per pipe per cap-skip row) | 6 NOPs = 24 T | `JR +4` = 12 T | 12 T/slot |

Both replacements stay within the existing byte footprint, so no other code that computes `slot+6` or `row+32` needs to change.

## Architecture

### Change A — Pad trailer becomes absolute `JP`

At `init_pipe_program` time, after each row's slots are written, also write the 3-byte JP at byte offset +25:

```
byte 25 = $C3                  ; opcode: JP nn
byte 26 = low(next_row_base)
byte 27 = high(next_row_base)
bytes 28..31 = $00 (dead — JP never returns)
```

For rows 0..158: `next_row_base = SLOT_GRID_BASE + (row+1) * SLOT_ROW_STRIDE` (= the next row's EXX byte).
For row 159: `next_row_base = SLOT_GRID_END` (= the existing `ld sp,(saved_sp) ; ret` epilogue at `$EF00`).

The cap-row case is unaffected — pipe-3 cap handler still `jp`s to the next row's EXX directly (bypasses the pad), and pipes 0..2 cap-handlers land back inside the slot grid mid-row; their flow still terminates at the same pad trailer, which is now a JP instead of 7 NOPs.

Cost: per-frame saving = 18 T × 154 non-cap rows = **2 772 T**.

(Cap rows already bypass the pad, so they neither gain nor lose. Slight gain on pipe-3 cap row since handler-`jp` target stays the same EXX address either way.)

### Change B — Cap-skip slot becomes relative `JR`

Modify `build_slot_templates` (which fills `CAP_BLOCK` once at boot) to write the JR-skip pattern instead of zeros in the 48 interior rows:

```
For each cap-skip row in CAP_BLOCK:
    byte 0 = $18              ; opcode: JR e
    byte 1 = $04              ; signed displacement (PC += 2 + 4 = +6)
    bytes 2..5 = $00          ; dead — JR never returns
```

At LDI-copy time, `configure_pipe_slots` copies these 6 bytes verbatim into the slot grid. At PIPE_PROGRAM execution time, when the CPU reaches the JR opcode in a cap-skip slot, it advances PC by 6 (= to the next slot or pad).

JR is position-independent (relative offset), so the pre-baked pattern works regardless of which absolute address `CAP_BLOCK` is LDI'd to.

**Why JR instead of JP**: JP would be 2 T cheaper per execution, but its 3-byte absolute target depends on the destination slot address, which varies per recycle. Patching JP targets after every `configure_pipe_slots` would cost ~1 440 T/recycle (48 slots × ~30 T per patch) — far more than the ~288 T/frame penalty of preferring JR.

Cost: per-frame saving = (24 − 12) × 144 cap-skip slots = **1 728 T**.

### Combined effect

**PIPE_PROGRAM ≈ 28 k T → 23.5 k T per frame** (≈ −4.5 k T/frame).

Translates to roughly +6 % headroom on every frame, applied uniformly (no special-case for swap/wrap frames).

## Components

### `init_pipe_program` — add row-trailer JP write

After the existing `.ipp_pipe_lp` loop completes (4 slots written), add:

```asm
        ; ── Write row-trailer JP at slot[row][0] + 24 ────────────
        ; IY was advanced past slot[row][3]; it now points at byte +25.
        ; Write JP next_row_EXX, or JP SLOT_GRID_END for row 159.
        ld      a, b              ; B = row
        cp      GROUND_TOP - 1    ; row 159?
        jr      z, .ipp_last_row_trailer
        ; Normal trailer: JP base + (row+1)*32
        ; … compute target …
        ld      (iy+0), $C3
        ld      (iy+1), target_lo
        ld      (iy+2), target_hi
        jr      .ipp_trailer_done
.ipp_last_row_trailer:
        ld      (iy+0), $C3
        ld      (iy+1), low SLOT_GRID_END
        ld      (iy+2), high SLOT_GRID_END
.ipp_trailer_done:
```

Run-once cost: ~50 T/row × 160 = 8 k T at boot. Irrelevant at run-time.

### `build_slot_templates` — patch CAP_BLOCK skip rows

Replace the existing `.bst_cap_skip_lp` (288 zero bytes) with a loop that writes the JR-skip pattern × 48 rows:

```asm
        ; 48 skip rows × 6 bytes each: JR +4, $04, $00 × 4
        ld      b, 48
.bst_cap_skip_lp:
        ld      (hl), $18         ; opcode: JR e
        inc     hl
        ld      (hl), $04         ; signed displacement → +6 from slot start
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_skip_lp
```

Run-once cost: ~70 T/row × 48 = 3.4 k T at boot. Same byte count emitted (6 per row). HL advances exactly 288 bytes as before, so the cap_bot stub that follows lands at the right place.

## Data flow

```
boot:
    build_slot_templates → fills CAP_BLOCK with cap_top stub + 48 JR-skip rows + cap_bot stub
                           (Change B: skip rows now contain $18 $04 $00 $00 $00 $00)
    init_pipe_program    → fills PIPE_PROGRAM with EXX + 4 body slots + JP trailer per row
                           (Change A: trailer now contains $C3 lo hi $00 $00 $00 $00)

frame:
    redraw_pipes_v2 → call PIPE_PROGRAM
        per row:
            EXX (4 T)
            slot 0 (43 / 103 / 12 T — body / cap / JR-skip)
            slot 1 (same)
            slot 2 (same)
            slot 3 (same)
            JP next_row_EXX (10 T)              ← was 7 NOPs (28 T)
        row 159:
            JP SLOT_GRID_END
        epilogue: ld sp,(saved_sp) ; ret
```

## Invariants preserved

- **Byte footprint**: every slot still occupies 6 bytes; every row still 32 bytes. All address arithmetic (`SLOT_ROW_STRIDE`, `SLOT_STRIDE`, `slot+6`, `slot+1`, `row*32`, etc.) unchanged.
- **Slot patch sites** (`configure_pipe_slots`, `do_swap`, `ps_phase*`, `update_cap_imm_v2`): all write at offsets `+0` (cap opcode) or `+1`/`+2` (target imms) within a slot. JR-skip's `$18 $04` lives at the same `+0`/`+1` positions. When a patch overwrites a slot with body or cap content, it overwrites the JR opcode too — flow goes through the new instruction, not the JR.
- **`do_swap.full_swap` cap-row clear**: writes `$00 × 3` at bytes 0..2 of the old cap row. After clear, the slot reads as 6 NOPs (24 T). This is the same as before this spec for those 2 rows × per-swap-frame — net effect zero. (We could optimise these to JR-skip too; deferred.)
- **`do_swap.full_swap` body-row buffer patches** (band 1 + band 2): write at slot bytes +1..+2 (target imms). The slot's byte 0 stays `$31` (= `ld sp,nn`). Unaffected by either change.

## Error handling

The JP/JR targets are computed at boot from constants (`SLOT_GRID_BASE`, `SLOT_ROW_STRIDE`, `SLOT_GRID_END`). No runtime input → no error path needed.

**Edge cases checked**:
- Row 159's trailer jumps to `SLOT_GRID_END` (= the epilogue), which is where the previous "fall-through past the last pad" landed. Identical behaviour, faster path.
- Pipe-3 cap handler's `jp _next` (set by `ps_phase4`/`configure_pipe_slots`) targets `slot[row+1][0] - 1` (= next row's EXX). Unchanged. The new row-trailer JP is never reached on a pipe-3 cap row because the handler bypasses it.
- Pipes 0..2 cap handler's `jp _next` targets `slot[row][cap_pipe+1]` (= same-row, next-slot). The remaining slots in that row execute, then the new row-trailer JP fires. Identical to before but trailer is now JP not NOPs.

## Testing

Acceptance criteria:

1. **Build clean** (`make`, 0 errors, 0 warnings).
2. **Game runs indefinitely** (≥ 30 s, ≥ 10 swaps) with no resets and no infinite loops.
3. **Visual output identical** to pre-change: pipes scroll smoothly, caps render, sky/ground unchanged.
4. **Border profile shows shrunk magenta band**: the magenta region (= PIPE_PROGRAM) should be visibly narrower by roughly 6 % of the visible area on every frame. If unchanged, the JPs were never written or never executed.
5. **No new artifacts on first frame after a recycle**: cap-skip rows still draw nothing (= sky). If JR offset is wrong, you'd see cap_bot stamped a row early or late.

Manual test plan:
1. Build: `make`. Expect `Errors: 0, warnings: 0`.
2. Run: `make run`. Watch for ≥ 10 seconds.
3. Compare border-band profile against the pre-change recording. Magenta should be visibly shorter.

## Scope

In scope:
- `init_pipe_program`: write row-trailer JP at byte +25..+27 of each row.
- `build_slot_templates`: write JR-skip pattern in 48 interior rows of `CAP_BLOCK`.

Out of scope (deferred):
- Replacing `do_swap.full_swap` cap-row clear (2 NOP-clear slots/frame × every-28-frame) with JR-skip pattern. Trivial gain.
- Prep-column NOP slots — these don't actually exist after the surgical do_swap fix (slots stay as body slots writing to buffer col).
- Pipe-3 cap-row pad bypass — already optimal.
- Any patch_pipe_targets, draw_bird, or draw_ground changes — Specs 2/3.

## Self-review

- **Placeholders**: none.
- **Internal consistency**: `SLOT_ROW_STRIDE = 32`, slot at +1, pad at +25 (= 1 + 4 × 6), JP fits in 3 bytes ≤ 7-byte pad. ✓
- **Scope**: focused on 2 sites (`init_pipe_program`, `build_slot_templates`). Single implementation plan. ✓
- **Ambiguity**: JR displacement is `$04` (not `$06`) because the JR encoding adds `e` to `PC+2`. Verified: PC at JR opcode → PC+2 after fetch → +4 = PC+6 = slot+6. ✓
- **Savings counted from code, not guessed**: 154 × 18 + 144 × 12 = 2 772 + 1 728 = 4 500 T/frame. ✓
