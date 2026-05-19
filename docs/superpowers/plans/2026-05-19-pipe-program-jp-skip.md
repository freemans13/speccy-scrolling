# PIPE_PROGRAM JP-Skip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut ~4.5 k T-states/frame from PIPE_PROGRAM by replacing 7-NOP row-trailers with `JP next_row_EXX` and 6-NOP cap-skip slots with `JR +4`.

**Architecture:** Two independent emission-time changes. Change B (CAP_BLOCK skip rows) is a tiny patch in `build_slot_templates`. Change A (per-row trailer JP) extends `init_pipe_program` to write 3 extra bytes per row. No callers of slot/row addressing arithmetic change.

**Tech Stack:** Z80 assembly (sjasmplus); `src/main.asm` only; manual run-check via `make run` (assistant cannot run the emulator — human must run and report).

---

## Task 1: CAP_BLOCK skip rows become JR-skip (Change B)

**Files:**
- Modify: `src/main.asm` — `build_slot_templates`, `.bst_cap_skip_lp` (around line 1350)

**Reference**: design spec `docs/superpowers/specs/2026-05-19-pipe-program-jp-skip-design.md` § "Change B — Cap-skip slot becomes relative `JR`".

- [ ] **Step 1: Read the current `.bst_cap_skip_lp` block**

Open `src/main.asm` and locate `.bst_cap_skip_lp`. Confirm it currently writes 288 zero bytes via a `dec bc / ld a,b / or c / jr nz` loop, between the `cap_top` stub fill and the `cap_bot` stub fill.

Confirm the expected pre-state of HL on entry: HL points at `CAP_BLOCK + 6` (= start of first skip row).

- [ ] **Step 2: Replace the byte-wise zero-fill with a 6-byte JR pattern × 48 rows**

Locate the existing block:

```asm
        ; 48 skip rows × 6 bytes = 288 zero bytes
        ld      bc, 288
.bst_cap_skip_lp:
        ld      (hl), 0
        inc     hl
        dec     bc
        ld      a, b
        or      c
        jr      nz, .bst_cap_skip_lp
```

Replace it with:

```asm
        ; 48 skip rows × 6 bytes — JR +4 pattern so PIPE_PROGRAM
        ; jumps the slot in 12 T instead of executing 6 NOPs in 24 T.
        ; JR e: PC += 2 + e; e = $04 → +6 from slot start = next slot.
        ld      b, 48
.bst_cap_skip_lp:
        ld      (hl), $18                       ; opcode: JR e
        inc     hl
        ld      (hl), $04                       ; displacement: skip 6 bytes
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

HL advances exactly 48 × 6 = 288 bytes — same total as before. The cap_bot stub that follows lands at the same address.

- [ ] **Step 3: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 4: Verify slot grid contents** (optional sanity, do if doubting)

After build, inspect the assembled listing or the generated `.sna` via `xxd build/main.sna | grep` to confirm `CAP_BLOCK` first 12 bytes match `c3 00 00 00 00 00 18 04 00 00 00 00` (cap_top stub + first JR-skip row).

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "perf: CAP_BLOCK skip rows become JR-skip (-1.7k T/frame)"
```

- [ ] **Step 6: Manual run-check (human runs)**

Tell the human: `make run` and play for ≥ 10 seconds. Expect:
- Game runs as before (no crashes, no resets).
- Pipes scroll smoothly. Caps render where they did before.
- Magenta border band should be visibly narrower (by ~3 % of the visible area).

If the human reports any visual change in pipe rendering (cap position, ghost cells, etc.), the JR offset is wrong — revert and investigate.

---

## Task 2: PIPE_PROGRAM row-trailer becomes JP next-row (Change A)

**Files:**
- Modify: `src/main.asm` — `init_pipe_program`, end of `.ipp_row_lp` (around line 540)

**Reference**: design spec § "Change A — Pad trailer becomes absolute `JP`".

- [ ] **Step 1: Read the current `.ipp_row_lp` exit**

Open `src/main.asm` and locate `.ipp_row_done:`. Confirm that immediately before it, the `.ipp_pipe_lp` finishes with IY advanced past slot[row][3] (= byte +25 of the row, the first byte of the 7-NOP pad area). At this point, B still holds the row number (0..159).

- [ ] **Step 2: Insert row-trailer JP write before `.ipp_row_done`**

Locate the existing tail of `.ipp_pipe_lp`:

```asm
        inc     c
        ld      a, c
        cp      NUM_PIPES
        jr      nz, .ipp_pipe_lp

.ipp_row_done:
        pop     bc                      ; restore B=row
```

Insert the trailer write between `jr nz, .ipp_pipe_lp` and `.ipp_row_done:`. IY currently points at byte +25 of the row (first pad byte). B holds the row number.

```asm
        inc     c
        ld      a, c
        cp      NUM_PIPES
        jr      nz, .ipp_pipe_lp

        ; ── Write row-trailer JP at byte +25 of this row ────────
        ; IY = slot[row][0] + 24 (= slot[row][3]+6 = first pad byte).
        ; Normal rows: JP base + (row+1)*32 = next row's EXX byte.
        ; Row 159   : JP SLOT_GRID_END (epilogue: ld sp,(saved_sp); ret).
        ld      (iy+0), $C3                     ; opcode: jp nn
        ld      a, b
        cp      GROUND_TOP - 1                  ; row 159?
        jr      z, .ipp_trailer_last

        ; HL = SLOT_GRID_BASE + (row+1) * 32
        ; (row+1) * 32: load row, inc, shift left 5
        ld      a, b
        inc     a                               ; row+1
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; *2
        add     hl, hl                          ; *4
        add     hl, hl                          ; *8
        add     hl, hl                          ; *16
        add     hl, hl                          ; *32
        ld      de, SLOT_GRID_BASE
        add     hl, de                          ; HL = base + (row+1)*32
        jr      .ipp_trailer_write

.ipp_trailer_last:
        ld      hl, SLOT_GRID_END

.ipp_trailer_write:
        ld      (iy+1), l
        ld      (iy+2), h

.ipp_row_done:
        pop     bc                      ; restore B=row
```

Note: this clobbers HL and DE inside the row loop. Both are already clobbered earlier in the iteration (`.ipp_pipe_lp` rewrites them every pipe), and B is preserved by being saved on the stack at the top of `.ipp_row_lp`. AF is clobbered only by `inc a` and `cp` — no caller in `init_pipe_program` relies on AF carrying across `.ipp_row_done`.

- [ ] **Step 3: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 4: Verify slot grid contents** (optional sanity)

After build, inspect `build/main.sna` at offset corresponding to `$DB19` (= row 0 byte 25): expect `c3 20 db` (= `JP $DB20` = row 1 EXX). At row-159 trailer offset (`$DB00 + 159*32 + 25 = $EEF9`): expect `c3 00 ef` (= `JP $EF00` = SLOT_GRID_END).

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "perf: PIPE_PROGRAM row trailer becomes JP next-row (-2.8k T/frame)"
```

- [ ] **Step 6: Manual run-check (human runs)**

Tell the human: `make run` and play for ≥ 30 seconds (≥ 10 swaps). Expect:
- Game runs indefinitely with no resets.
- Pipes scroll smoothly. No tearing introduced.
- Magenta border band visibly narrower vs Task-1 baseline (by another ~4 % of visible area).
- Total magenta-band shrink from pre-Spec-1 baseline ≈ 6 %.

If the human reports a reset / infinite hang / sinclair-research screen, the JP target arithmetic is likely wrong (off-by-one row, or wrong SLOT_GRID_END). Snapshot the affected row and verify the 3 bytes at offset +25..+27.

---

## Done — when

- Both tasks committed.
- Game still runs at 50 Hz on swap and wrap frames.
- Magenta band visibly smaller in border profile.

Carry the improvement forward to inform Spec 2 (patch_pipe_targets) and Spec 3 (top-sky skip).
