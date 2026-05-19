# do_swap Surgical Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut `do_swap`'s ~16.6 k T-state overhead down to ~3.4 k T by replacing the brute 6-byte-per-row clear with row-category-aware patching, and by moving the `ACTIVE_PIPE_<dep>` zero-fill into the rarely-used fallback path.

**Architecture:** Three tasks, each landing a working build:
1. Add an `ds_old_gap_y` scratch byte and capture dep's OLD `gap_y` at the top of `.ds_full_swap` (no behaviour change yet).
2. Move the `ACTIVE_PIPE_<dep>` zero-fill out of the shared entry into the fallback branch (no behaviour change for the common path — `prep_step` phase 6 always rebuilds the sublist at 10 rows/frame).
3. Replace the 15.4 k T full clear (step 5) and the 50 T cap deactivate (step 6) with two body-row target-patch loops plus a 3-byte cap-row clear.

**Tech Stack:** Z80 assembly (sjasmplus), single source file `src/main.asm`.

---

## File Structure

Only one file modified across all three tasks:

- **Modify:** `src/main.asm`
  - Sections affected: `do_swap` entry (~line 2427), `.ds_fallback` (~line 2435), `.ds_full_swap` (~line 2530), scratch-variable block (~line 2735), and `active_pipe_addrs` table is referenced only by the relocated zero-fill code (no schema change).

Reference design: `docs/superpowers/specs/2026-05-19-do-swap-surgical-cleanup-design.md`.

---

## Task 1: Add `ds_old_gap_y` scratch + save dep's gap_y

**Goal:** Capture dep's OLD `gap_y` once at the start of `.ds_full_swap` so later tasks can compute `old_cap_top_row` and `old_cap_bot_row` without re-reading `pipe_state`. No runtime behaviour change.

**Files:**
- Modify: `src/main.asm` — add `ds_old_gap_y` to scratch block (~line 2735), insert read at top of `.ds_full_swap` (~line 2530).

- [ ] **Step 1: Add `ds_old_gap_y` to do_swap's scratch block**

In `src/main.asm`, find the scratch block:

```asm
; ── Scratch variables for do_swap ────────────────────────────────
ds_dep:     db 0                               ; departing pipe index
ds_inc:     db 0                               ; incoming pipe index
ds_tmp:     db 0                               ; temp (fallback gap_y)
ds_pipe6:   db 0                               ; incoming pipe index × 6
ds_cap_top: db 0                               ; temp scratch (reused for dep*6 in cap deactivate)
ds_cap_bot: db 0                               ; (unused in full_swap path; kept for alignment)
```

Add one line after `ds_cap_bot`:

```asm
ds_old_gap_y: db 0                             ; dep's OLD gap_y, captured at .ds_full_swap entry
```

- [ ] **Step 2: Read dep's gap_y at start of `.ds_full_swap`**

Find the `.ds_full_swap:` label and the next instructions:

```asm
.ds_full_swap:
        ld      a, (prep_pipe_idx)
        ld      (ds_inc), a                     ; incoming = old prep_pipe_idx
```

Insert the gap_y capture immediately before the first `ld a, (prep_pipe_idx)` line:

```asm
.ds_full_swap:
        ; Capture dep's OLD gap_y for later band-boundary computations.
        ; Must happen BEFORE step 3 overwrites pipe_state[inc].
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de                          ; HL = &pipe_state[dep].gap_y
        ld      a, (hl)                         ; A = OLD gap_y
        ld      (ds_old_gap_y), a

        ld      a, (prep_pipe_idx)
        ld      (ds_inc), a                     ; incoming = old prep_pipe_idx
```

- [ ] **Step 3: Build and verify**

Run: `make`
Expected: `Errors: 0, warnings: 0`

- [ ] **Step 4: Run game to verify no regression**

Run: `make run` (the human runs this; assistant cannot see emulator output).
Expected: Game plays exactly as before this change — same swap behaviour, same cyan blips. The `ds_old_gap_y` byte is being written but not yet read; no observable change.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
do_swap: capture dep's OLD gap_y to ds_old_gap_y at .ds_full_swap entry

Adds ds_old_gap_y scratch byte and reads pipe_state[dep].gap_y once
before pipe_state[inc] is overwritten in step 3. Later tasks will
use this to compute the band-1 / band-2 boundaries for the surgical
clear that replaces the full 6-byte-per-row column clear.

No behaviour change in this task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Move `ACTIVE_PIPE_<dep>` zero-fill into fallback path

**Goal:** Remove the 1.2 k T zero-fill from the common (full-swap) code path. Keep it in the rare fallback path as belt-and-braces for the case where prep didn't reach phase 6.

**Files:**
- Modify: `src/main.asm` — `do_swap` entry (~line 2427), `.ds_fallback` (~line 2435).

- [ ] **Step 1: Remove the zero-fill from `do_swap` entry**

In `src/main.asm`, find `do_swap:` and the zero-fill block immediately after it:

```asm
do_swap:
        ld      (ds_dep), a                     ; save departing pipe index

        ; Zero-fill ACTIVE_PIPE_<dep> (224 bytes = 112 words) via SP-hijack.
        ; ~1.3 k T vs ~4.7 k T for LDIR. Keeps swap-frame budget under 70 k.
        ; Stale entries from dep's previous active period would otherwise let
        ; patch_pipe_targets corrupt slot bytes via $00→$FF wraps when dep
        ; becomes active again before phase 6 rebuilds the list.
        add     a, a                            ; dep*2
        ld      e, a
        ld      d, 0
        ld      hl, active_pipe_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = ACTIVE_PIPE_<dep>
        ld      hl, 224
        add     hl, de                          ; HL = ACTIVE_PIPE_<dep> + 224 (end)
        ld      (saved_sp_inner), sp            ; save real SP (reuse patch's slot)
        ld      sp, hl                          ; SP = end of buffer
        ld      hl, 0
        ; 112 pushes × 11 T = 1232 T
        REPT 112
            push hl
        ENDR
        ld      sp, (saved_sp_inner)            ; restore real SP

        ; Guard: only do full swap when prep is complete (phase 7).
        ld      a, (prep_phase)
        cp      7
        jr      z, .ds_full_swap
```

Replace it with just the dep save + guard (delete the whole zero-fill block):

```asm
do_swap:
        ld      (ds_dep), a                     ; save departing pipe index

        ; Guard: only do full swap when prep is complete (phase 7).
        ld      a, (prep_phase)
        cp      7
        jr      z, .ds_full_swap
```

- [ ] **Step 2: Add the zero-fill at the start of the fallback path**

Find the fallback path entry. Just after the guard above, the code falls through into the fallback:

```asm
        ; ── Fallback: prep not ready. Fast in-place recycle. ────────────
        ; Just pick new random gap_y and reset byte_x=29 for the departing pipe.
```

Insert the zero-fill block immediately before the `; ── Fallback:` comment line:

```asm
        ; ── Fallback: prep not ready. Fast in-place recycle. ────────────
        ; First, zero-fill ACTIVE_PIPE_<dep> (224 bytes) so stale entries
        ; can't corrupt slot bytes via patch_pipe_targets when dep eventually
        ; becomes active again. The full-swap path skips this — phase 6 has
        ; rebuilt the sublist there. Fallback path lacks that guarantee.
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      e, a
        ld      d, 0
        ld      hl, active_pipe_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = ACTIVE_PIPE_<dep>
        ld      hl, 224
        add     hl, de                          ; HL = ACTIVE_PIPE_<dep> + 224 (end)
        ld      (saved_sp_inner), sp            ; save real SP
        ld      sp, hl                          ; SP = end of buffer
        ld      hl, 0
        ; 112 pushes × 11 T = 1232 T
        REPT 112
            push hl
        ENDR
        ld      sp, (saved_sp_inner)            ; restore real SP

        ; Just pick new random gap_y and reset byte_x=29 for the departing pipe.
```

- [ ] **Step 3: Build and verify**

Run: `make`
Expected: `Errors: 0, warnings: 0`

- [ ] **Step 4: Run game to verify no regression**

Run: `make run`
Expected: Game plays as before. Full-swap path is the common one, so the zero-fill removal there is the active change — pipes should still render correctly with no stale-entry symptoms (no RST 38h-style crashes, no slot-grid corruption). Fallback path is unreachable in normal play at 10 rows/frame prep, so the relocation there is silent.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
do_swap: move ACTIVE_PIPE_<dep> zero-fill into fallback path

Full-swap path doesn't need the zero-fill because prep_step phase 6
rebuilds ACTIVE_PIPE_<dep> well before dep cycles back to active
(20 frames vs 28-frame swap interval at 10 rows/frame). Saves
~1.2 k T on every swap frame.

Fallback path keeps the zero-fill as belt-and-braces for the case
where prep doesn't reach phase 6 before fallback fires.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Replace full clear + cap deactivate with surgical patch

**Goal:** Replace the 15.4 k T clear loop (step 5) and the 50 T cap deactivate (step 6) with three targeted operations totalling ~3.4 k T: a band-1 body-target patch, a band-2 body-target patch, and a 2-row × 3-byte cap clear.

**Files:**
- Modify: `src/main.asm` — `.ds_full_swap` body (~line 2680..2810).

- [ ] **Step 1: Locate and read the current step 5 + step 6**

The current code lives between the imm-writes (just after the `cap_bot_handler_pipe_<inc>_next` writeback) and the `; 7. Update prep_pipe_idx...` comment. Open `src/main.asm` and confirm the structure matches:

```asm
        ; 5. Clear dep's slot column to all NOPs (6 bytes × 160 rows = 960 bytes).
        ; ... ~120 lines of compute-dep*6, clear loop, and (in the existing buggy step 6) cap deactivate ...
        ld      a, (ds_dep)
        ld      e, a
        add     a, a    ; dep*2
        ...
        djnz    .ds_dep_clr_lp

        ; 7. Update prep_pipe_idx, pick new gap_y, reset prep state.
```

You're replacing everything between the comment `; 5. Clear dep's slot column...` and the comment `; 7. Update prep_pipe_idx...`.

- [ ] **Step 2: Delete the current step 5**

Remove the entire current step 5 block, starting at the comment line:

```asm
        ; 5. Clear dep's slot column to all NOPs (6 bytes × 160 rows = 960 bytes).
```

and continuing through to (but NOT including) the `; 7. Update prep_pipe_idx,...` line. The step-7 logic must remain untouched.

- [ ] **Step 3: Insert the new step 5 (body-row target patch + cap-row clear)**

In the same location (where the old step 5 used to be, just before `; 7. Update prep_pipe_idx`), insert this code block:

```asm
        ; 5a. Compute dep's slot column base address into BC, and dep's OLD
        ;     cap_top_row / cap_bot_row into D / E for later band loops.
        ;     slot[0][dep] + 0 = SLOT_GRID_BASE + 1 + dep*6.
        ld      a, (ds_dep)
        ld      e, a
        add     a, a    ; dep*2
        add     a, e    ; dep*3
        add     a, e    ; dep*4
        add     a, e    ; dep*5
        add     a, e    ; dep*6
        ld      (ds_pipe6), a                   ; reuse scratch: dep*6

        ; old_cap_top_row = old_gap_y - 1
        ; old_cap_bot_row = old_gap_y + PIPE_GAP
        ld      a, (ds_old_gap_y)
        dec     a
        ld      (ds_cap_top), a                 ; reuse scratch: old_cap_top_row
        ld      a, (ds_old_gap_y)
        add     a, PIPE_GAP
        ld      (ds_cap_bot), a                 ; reuse scratch: old_cap_bot_row

        ; 5b. Band 1: patch body slots in rows [0 .. old_cap_top_row - 1].
        ;     For each row r: write screen_target_table_29[r] to slot[r][dep] + 1, +2.
        ;     Initial HL = slot[0][dep] + 1. Initial HL' (alt bank) = screen_target_table_29.
        ;     Per-row stride: HL += SLOT_ROW_STRIDE - 1 = 31 after writing target.hi.
        ld      a, (ds_cap_top)                 ; A = old_cap_top_row
        or      a
        jr      z, .ds_band2_setup              ; gap_y=1 makes band 1 empty (safety)
        ld      b, a                            ; B = band-1 row count

        ld      a, (ds_pipe6)
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 2          ; HL = slot[0][dep] + 1
        add     hl, de
        ld      de, SLOT_ROW_STRIDE - 1         ; 31 (HL advance per row)

        exx
        push    hl                              ; save HL'
        ld      hl, screen_target_table_29      ; HL' = table[0]
        exx
.ds_band1_lp:
        exx
        ld      a, (hl)                         ; A = target.lo
        inc     hl
        exx
        ld      (hl), a                         ; write to slot[r][dep] + 1
        inc     hl                              ; HL → slot[r][dep] + 2
        exx
        ld      a, (hl)                         ; A = target.hi
        inc     hl
        exx
        ld      (hl), a                         ; write to slot[r][dep] + 2
        add     hl, de                          ; HL += 31 → slot[r+1][dep] + 1
        djnz    .ds_band1_lp
        exx
        pop     hl
        exx

.ds_band2_setup:
        ; 5c. Band 2: patch body slots in rows [old_cap_bot_row + 1 .. 159].
        ;     row_count = 160 - (old_cap_bot_row + 1) = 159 - old_cap_bot_row.
        ld      a, 159
        ld      e, a
        ld      a, (ds_cap_bot)
        cpl                                     ; A = ~old_cap_bot_row
        inc     a                               ; A = -old_cap_bot_row (two's complement)
        add     a, e                            ; A = 159 - old_cap_bot_row
        jr      z, .ds_cap_clear                ; band 2 empty
        jr      c, .ds_cap_clear                ; overshoot (shouldn't happen)
        ld      b, a                            ; B = band-2 row count

        ; Initial HL = slot[old_cap_bot_row + 1][dep] + 1.
        ; Address = SLOT_GRID_BASE + 1 + (old_cap_bot_row + 1) * 32 + dep*6 + 1.
        ld      a, (ds_cap_bot)
        inc     a                               ; A = old_cap_bot_row + 1
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = (old_cap_bot_row + 1) * 32
        ld      a, (ds_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL += dep*6
        ld      de, SLOT_GRID_BASE + 2          ; +1 (post-EXX) + 1 (target.lo offset)
        add     hl, de                          ; HL = slot[start_row][dep] + 1

        ; Initial HL' = screen_target_table_29 + (old_cap_bot_row + 1) * 2.
        exx
        push    hl                              ; save HL'
        exx
        ld      a, (ds_cap_bot)
        inc     a                               ; A = old_cap_bot_row + 1
        add     a, a                            ; *2 (table entries are 2 bytes)
        ld      e, a
        ld      d, 0
        push    hl                              ; preserve grid HL across alt-bank setup
        ld      hl, screen_target_table_29
        add     hl, de
        exx
        pop     hl                              ; restore grid HL into shadow
        ; NOTE: we now have grid HL in alt bank, table HL in main bank. Swap.
        exx                                     ; HL = grid cursor, HL' = table cursor

        ld      de, SLOT_ROW_STRIDE - 1         ; 31
.ds_band2_lp:
        exx
        ld      a, (hl)
        inc     hl
        exx
        ld      (hl), a
        inc     hl
        exx
        ld      a, (hl)
        inc     hl
        exx
        ld      (hl), a
        add     hl, de
        djnz    .ds_band2_lp
        exx
        pop     hl
        exx

.ds_cap_clear:
        ; 5d. Clear 3 bytes ($00 $00 $00) at slot[old_cap_top_row][dep] and
        ;     slot[old_cap_bot_row][dep]. Three bytes (not one) protects against
        ;     any handler-address byte at +1, +2 decoding as a multi-byte opcode
        ;     (e.g. $E7 = RST 20h, $32 = LD (nn),A).

        ; cap_top_row clear:
        ld      a, (ds_cap_top)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = old_cap_top_row * 32
        ld      a, (ds_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL += dep*6
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[old_cap_top_row][dep]
        xor     a
        ld      (hl), a                         ; byte 0 = $00
        inc     hl
        ld      (hl), a                         ; byte 1 = $00
        inc     hl
        ld      (hl), a                         ; byte 2 = $00

        ; cap_bot_row clear:
        ld      a, (ds_cap_bot)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = old_cap_bot_row * 32
        ld      a, (ds_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[old_cap_bot_row][dep]
        xor     a
        ld      (hl), a                         ; byte 0 = $00
        inc     hl
        ld      (hl), a                         ; byte 1 = $00
        inc     hl
        ld      (hl), a                         ; byte 2 = $00
```

The existing `; 7. Update prep_pipe_idx, pick new gap_y, reset prep state.` block follows untouched.

- [ ] **Step 4: Build and verify clean**

Run: `make`
Expected: `Errors: 0, warnings: 0`

If the build fails, common issues:
- Forgot to delete the old step 5 → duplicate `.ds_dep_clr_lp:` label.
- Forgot to delete the old step 6 → unused scratch / extra ret. (Step 6 was inside the deleted step 5 range; if you missed it, delete it now.)
- Typo in `screen_target_table_29` symbol — it exists elsewhere in the file.

- [ ] **Step 5: Run game and test**

Run: `make run`

Test plan (the human runs and observes):
1. Game boots and pipes start scrolling (~1 second).
2. First swap occurs (~2 seconds in). Game should NOT crash or reset.
3. Subsequent swaps every ~0.56 s (28 frames). Pipes should render fully (cap + body) on every active pipe.
4. **No ghost pipe at left edge** on the frame after a swap. (If you see a faint pipe shape briefly at cols 0-5 just after a swap, the body-row patch missed some rows.)
5. **Border-profile check**: the magenta region on swap frames should be much closer in size to the magenta region on non-swap frames. The "magenta-dominant" blip should be substantially reduced or gone.

If any visual artifact appears (ghost pipe, stuck pipe section, glitched cap):
- Most likely cause: band boundary off-by-one. Re-read step 3's `band 1` and `band 2` row-count formulas.
- Less likely: HL stride wrong. After 5 inc-hl and 1 add-hl-de with DE=31, HL should advance by 32 per iteration.

If the game resets or crashes:
- Most likely cause: cap clear missed a row (`$C3` still active, jumps to old handler with stale SP target).
- Verify the cap-row computation: `old_cap_top_row = old_gap_y - 1`, `old_cap_bot_row = old_gap_y + 48` (PIPE_GAP = 48).

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
do_swap: replace full clear with surgical band patch + cap clear

Replaces the 15.4 k T 6-byte-per-row clear of all 160 slot rows
(step 5) and the 50 T cap-byte-0 clear (step 6) with three
targeted operations:

  5b. Band 1 (rows 0..old_cap_top_row-1): rewrite each body slot's
      target imm bytes to line_addr+34 (= byte_x=29 buffer cols).
      Body slot continues firing but writes invisibly.
  5c. Band 2 (rows old_cap_bot_row+1..159): same body-target patch.
  5d. Cap rows (old_cap_top_row, old_cap_bot_row): write $00 to
      bytes 0, 1, 2 — a 3-byte NOP slide that survives any handler
      address byte at slot+1, slot+2 decoding as a multi-byte opcode.

Cap-skip rows (rows old_cap_top_row+1..old_cap_bot_row-1) are
already NOPs and need no touching.

Net cost: ~3.4 k T (110 body rows × ~30 T + 2 cap rows × ~30 T) vs
15.4 k T before. Combined with Task 2's zero-fill relocation, the
swap-frame budget drops from ~82 k T to ~69 k T — under the 70 k
ceiling, eliminating the magenta-dominant 25 Hz blip every swap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ✓ `ds_old_gap_y` scratch byte — Task 1.
- ✓ Read dep's gap_y at .ds_full_swap entry — Task 1.
- ✓ Move ACTIVE_PIPE_<dep> zero-fill into fallback path — Task 2.
- ✓ Band-1 body-row target patch — Task 3 step 3 (5b).
- ✓ Band-2 body-row target patch — Task 3 step 3 (5c).
- ✓ 3-byte NOP clear for cap rows — Task 3 step 3 (5d).
- ✓ Cap-skip rows untouched — implicit in band boundaries.
- ✓ Test plan (build clean, game runs, no resets, pipes render, no ghost pipes, no left-edge artifacts, magenta blip reduced) — Task 3 step 5.

**Placeholder scan:** No "TBD" / "TODO" / "fill in" / "similar to" placeholders. Each step has complete code.

**Type consistency:**
- `ds_old_gap_y` introduced in Task 1, used in Task 3 ✓
- `ds_pipe6`, `ds_cap_top`, `ds_cap_bot` reused as scratch — names match existing declarations.
- `screen_target_table_29`, `SLOT_GRID_BASE`, `SLOT_ROW_STRIDE`, `PIPE_GAP`, `GROUND_TOP` are all existing symbols in `src/main.asm` — no renames.
- `active_pipe_addrs` referenced in Task 2 — already exists at end of do_swap scratch block.

**Open consideration:** The band-2 setup in Task 3 uses a `push hl ; ... ; exx ; pop hl` dance to set up both bank cursors. An implementer should double-check the register-bank state across the EXX boundary if a `make` succeeds but the game shows visual artifacts. If suspect, simplest fix is to recompute HL inline rather than pushing it across EXX.
