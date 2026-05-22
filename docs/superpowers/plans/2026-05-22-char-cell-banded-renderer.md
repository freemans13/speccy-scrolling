# Char-Cell-Banded Pipe Renderer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended for this project) to implement this plan stage-by-stage. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the abandoned double-buffered renderer with a single-grid, char-cell-banded renderer that scrolls the pipes by patching ~60 band-base immediates instead of ~330 per-row targets — collapsing the wrap-frame spike and freeing per-frame headroom.

**Architecture:** One `PIPE_PROGRAM` grid, emitted **band-interleaved** (8-row char-cell bands, P0.b0,P1.b0,P2.b0,P3.b0,P0.b1,…). Each pipe-band is rendered with `IX` as a running screen pointer (`ld sp,ix` / `push` / `inc ixh`), so the band carries ONE base immediate. Scrolling decrements those bases. The A/B dither uses `push de`/`push hl` (no `EXX`). No second grid.

**Tech Stack:** Z80 assembly, sjasmplus, single file `src/main.asm`. No unit-test harness — verification is `make` (clean build + `ASSERT` guard) plus a human border-profiler checkpoint in Fuse.

**Spec:** `docs/superpowers/specs/2026-05-22-char-cell-banded-renderer-design.md`

---

## Nature of this plan

A **staged** plan for a core-renderer rewrite. Each stage is a self-contained
milestone that leaves the game **building clean and runnable**. Heavy stages
name the exact existing routines to study and adapt — pre-writing the Z80 blind
would be fabrication.

**Per-stage verification:**
1. `make` from the project root → `Errors: 0, warnings: 0`, `ASSERT` passes.
2. CHECKPOINT: the human runs `make run` in Fuse and confirms the stated
   visual + border-profiler criteria. The assistant cannot run the emulator.
   **Measure with the profiler — do not trust T-state estimates.**

Stages run in order; later stages depend on earlier ones.

---

## Stage 1: Revert to the pre-redesign single-grid renderer

**Goal:** Restore the last known-good renderer — single grid, row-interleaved, the working smooth 50 Hz game — discarding the abandoned double-buffer machinery (old plan Stages 1–8). The beeper-sfx sound code (committed *before* the renderer redesign) is preserved.

**Study first:** `git log --oneline` on branch `beeper-sfx` — identify the last commit *before* the renderer redesign began (the redesign's first commit added `GRID_B` / the Approach-1 grid work). The pre-redesign `src/main.asm` is the single-grid renderer.

**Files:** `src/main.asm`.

- [ ] **Step 1:** `git log --oneline` — find the pre-redesign commit hash (call it `BASE`). Confirm by checking that commit's `src/main.asm` has no `GRID_B` / `patch_shadow_step` / `rebuild_column`.
- [ ] **Step 2:** Restore the renderer: `git checkout BASE -- src/main.asm`. (This keeps the branch history; it restores the file content only.)
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 4: Commit** — `git commit -m "revert: restore the pre-redesign single-grid renderer (double-buffer approach abandoned)"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: the known-good game — 3 pipes scroll smooth at 50 Hz, recycle correctly, no freeze. Border profiler: calm frames have a healthy idle band; the wrap frame is the tight one (~0 idle). This is the baseline the rest of the plan improves.

---

## Stage 2: Re-emit the grid band-interleaved (slots unchanged)

**Goal:** Change only the grid's **emit order** to band-interleaved (P0.band0, P1.band0, P2.band0, P3.band0, P0.band1, …) — 8-row char-cell bands. Slots stay exactly as they are (`ld sp,imm ; push hl ; push de ; push bc`, per-row, with the per-row `EXX`). This de-risks the race-the-beam question *before* the slot mechanism changes.

**Study first:** the grid builder (`init_pipe_program` or equivalent in the restored renderer); how rows chain (the per-row JP-trailer / fall-through); how `redraw_pipes_v2` enters the grid; the row→screen-address mapping (`line_table`); `SLOT_ROW_STRIDE`.

**Files:** `src/main.asm` — the grid builder; the grid layout EQUs.

- [ ] **Step 1:** Re-order the grid builder so it emits, for band K = 0..19, the 8 rows of pipe 0's char-cell band K, then pipe 1's, pipe 2's, pipe 3's, then band K+1. Each emitted "row" is the existing per-row slot. Adjust the inter-slot chaining (trailer JPs or contiguous fall-through) so execution flows in the new order; the final slot falls through to the epilogue.
- [ ] **Step 2:** Update any routine that addresses a slot by `(row,pipe)` (e.g. `SLOT_ADDR_TABLE`, the scroll patch, the recycle config) to the new band-interleaved offset formula. The scroll patch and recycle must still find the same slots.
- [ ] **Step 3: Build check** — `make` → clean, `ASSERT` passes.
- [ ] **Step 4: Commit** — `git commit -m "refactor: emit the pipe grid band-interleaved (8-row char-cell bands)"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: rendering is **pixel-identical** to Stage 1 (same pipes, same scroll, same dither — only the internal emit order changed). Border profiler: **no tearing** — confirm the band-interleaved execution order still stays ahead of the raster. This is the critical race-the-beam check; if it tears, stop and report.

---

## Stage 3: IX-pointer body bands + per-band scroll

**Goal:** Convert **pure-body bands** from 8 per-row `ld sp,imm` slots to one `ld ix,base` + an 8-row IX-walk (`ld sp,ix ; push hl ; push de ; push bc ; inc ixh`). Keep the per-row `EXX` dither and the `HL=0` trailing-zero push for now (3-push slot). Change the scroll patch to decrement the **band bases**. Cap-edge bands and skip bands stay in per-row form this stage.

**Study first:** the restored slot format and `redraw_pipes_v2`'s register setup; the scroll patch routine (`patch_pipe_targets` or equivalent) and how it walks slots; `inc ixh` (undocumented — confirm sjasmplus emits `$DD $24`); the screen-address `+256` per-row relationship within a char cell.

**Files:** `src/main.asm` — grid builder (body-band emission), `redraw_pipes_v2`, the scroll patch, the slot/grid EQUs.

- [ ] **Step 1:** Grid builder — emit pure-body bands as `ld ix,band_base` followed by 8 rows of `ld sp,ix ; push hl ; push de ; push bc ; inc ixh` (the 8th `inc ixh` may be omitted). `band_base` = the row-0-of-band screen target. Cap-edge bands (the 2 per pipe straddling a cap) and the 6 skip bands stay as before.
- [ ] **Step 2:** Verify `IX` is unused during grid execution (it is — only init / `configure_pipe_slots` / `update_cap_imm` touch it, none concurrent with the grid). No save/restore of IX needed inside the grid.
- [ ] **Step 3:** Rewrite the scroll patch: for each active pipe, decrement its body bands' `ld ix,base` operands (≈18 bands/pipe at this stage; the 2 cap-edge bands still per-row). Build a small list of band-base addresses (or compute them) — model it on the existing active-list walk.
- [ ] **Step 4: Build check** — `make` → clean, `ASSERT` passes.
- [ ] **Step 5: Commit** — `git commit -m "feat: IX-pointer body bands; scroll by per-band base"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes render correctly, scroll smoothly, dither intact. Border profiler: the wrap-frame scroll cost is **visibly smaller** than Stage 1 (most of the patch is now per-band).

---

## Stage 4: EXX-free dither + once-per-wrap trailing clear

**Goal:** Free `HL` by dropping the per-slot trailing-zero push (3-push → 2-push slot) and removing `EXX`. Load `BC` = bitmap bytes 0,1; `DE` = bytes 2,3 of variant A; `HL` = bytes 2,3 of variant B. A-rows `push de ; push bc`, B-rows `push hl ; push bc`. Add a once-per-wrap pass that clears the single column each active pipe vacated.

**Study first:** the pre-shifted bitmap tables (`pipe_bitmap`, `pipe_bitmap_b`) — confirm A and B differ only in bytes 2,3 across all 8 phases; `redraw_pipes_v2`'s current register/`EXX` setup; how the current trailing-zero clears the vacated column; the wrap path (`wrap_byte_x`).

**Files:** `src/main.asm` — `redraw_pipes_v2`, the body-band slot emission, a new wrap-clear routine, `wrap_byte_x`.

- [ ] **Step 1:** `redraw_pipes_v2` — load `BC`/`DE`/`HL` with the three bitmap pairs (shared 0,1 / A 2,3 / B 2,3) for the current phase. Remove the `EXX` / shadow-bank bitmap setup.
- [ ] **Step 2:** Body bands — A-rows emit `ld sp,ix ; push de ; push bc ; inc ixh`; B-rows emit `ld sp,ix ; push hl ; push bc ; inc ixh`. No `EXX`. (Band row 0 = an even screen row = A-row, so a band is `[A][B][A][B][A][B][A][B]`.)
- [ ] **Step 3:** Add `clear_vacated_columns`: on the wrap, for each active pipe, zero the one column it scrolled out of, all 160 rows (stack-blast of zeros, char-cell-banded like the renderer). Call it from the wrap path.
- [ ] **Step 4: Build check** — `make` → clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: EXX-free push-de/push-hl dither; once-per-wrap trailing clear"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: the 1-row checker dither still looks correct; pipes leave **no trail** as they scroll. Border profiler: per-frame render cost is flat and slightly lower than Stage 3.

---

## Stage 5: Cap-edge bands folded into the IX band

**Goal:** The 2 cap-edge bands per pipe (7 body rows + 1 cap row, cap on the band edge) currently render per-row. Fold them into the IX-band walk so they too carry a single base immediate — the cap row shares the band's IX position, only the pushed data differs. This brings the scroll patch to the full ~20 bands/pipe (~60 total).

**Study first:** the cap handler(s) and the cap bitmap update routine; how a cap row's screen target is derived; that `cap_top_row = gap_y−1` is a band's last row and `cap_bot_row = gap_y+48` is a band's first row (since `gap_y` is ×8); the register-pressure problem — the cap row needs the cap bitmap without losing the body A/B pairs for the band's other 7 rows.

**Files:** `src/main.asm` — grid builder (cap-edge band emission), cap handler(s), `redraw_pipes_v2` or the cap update.

- [ ] **Step 1:** Prototype the cap row inside an IX-band: it stamps via `ld sp,ix` at the band's IX position. Decide the cap-data source (small per-cap handler with SMC-imm cap bitmap, entered from the band, vs. a register reload) — pick whichever keeps the band's body rows' registers intact. Record the decision in the commit message.
- [ ] **Step 2:** Emit cap-edge bands as a single `ld ix,band_base` + 8 IX-walk rows where row 0 or row 7 is the cap. Skip bands: a minimal stub (the gap renders nothing).
- [ ] **Step 3:** Extend the scroll patch to include the cap-edge band bases (now every band has exactly one base → ~60 total).
- [ ] **Step 4: Build check** — `make` → clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: fold cap-edge bands into the IX band walk"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipe caps render correctly (rounded ends, correct gap). Border profiler: the wrap-frame scroll patch is now a small chunk (~all bands patched as bases).

---

## Stage 6: Recycle — band-granular rebuild

**Goal:** When a pipe recycles (`byte_x→29`, new `gap_y`), rebuild its 20 bands for the new gap position. Amortise over the parked lead-time (a few bands per frame), into the single grid. Replace the old `prep_step`/`configure_pipe_slots` recycle path.

**Study first:** the restored recycle path (`prep_step` / `configure_pipe_slots` / `do_swap` / the JR-skip prep column); `random_gap_y`; `prep_pipe_idx`; how the parked pipe's lead-time works; which bands change body↔skip↔cap when `gap_y` changes.

**Files:** `src/main.asm` — recycle path; an amortised band-rebuild driver in `main_loop`.

- [ ] **Step 1:** On recycle, set `byte_x=29` + new `gap_y`, mark the pipe's column "needs band rebuild".
- [ ] **Step 2:** Amortised driver: each frame, re-stamp a bounded number of the recycled pipe's bands (body/skip/cap per the new `gap_y`); complete before the pipe scrolls into view. The parked pipe's not-yet-rebuilt bands are JR-skip.
- [ ] **Step 3:** Remove the old `prep_step` / `configure_pipe_slots` recycle calls (routines left defined; deleted in Stage 7).
- [ ] **Step 4: Build check** — `make` → clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: band-granular amortised pipe recycle"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes recycle correctly — re-enter from the right with a new gap, no corruption, no freeze, full session survives. Border profiler: **no recycle spike**.

---

## Stage 7: Cleanup; re-tune sound budget

**Goal:** Delete now-dead machinery; measure the real per-frame headroom and set the beeper budget from it.

**Files:** `src/main.asm` — delete dead routines/data; sound budget constants.

- [ ] **Step 1:** Delete the retired `prep_step`, `configure_pipe_slots`, the old per-row `patch_pipe_targets`, the JR-skip prep-column code, and any orphaned scratch/EQUs. Recompute the memory map (`ASSERT $ <= …`). Build must stay clean.
- [ ] **Step 2:** With the renderer settled, measure the worst-frame idle with the border profiler. Set the beeper `SND_SLICE` budget from the measured worst-frame headroom (leaving margin for future sprites). Re-enable the beeper if it was parked.
- [ ] **Step 3: Build check** — `make` → clean.
- [ ] **Step 4: Commit** — `git commit -m "cleanup: delete retired recycle machinery; set sound budget from measured headroom"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: flat 50 Hz throughout; every frame (wrap and recycle included) shows a clear idle band on the border profiler; sound plays cleanly.

---

## Self-review notes

- **Spec coverage:** char-cell bands + IX pointer (Stage 3 ✓), band-interleaved layout (Stage 2 ✓), EXX-free dither (Stage 4 ✓), per-band scroll (Stages 3,5 ✓), once-per-wrap trailing clear (Stage 4 ✓), caps on band edges (Stage 5 ✓), recycle (Stage 6 ✓), double-buffer deleted (Stage 1 revert ✓), single grid (✓) — all spec sections mapped. `apply/restore_pipe_attrs` is spec-out-of-scope and untouched.
- **Staging discipline:** every stage builds clean and runnable; Stages 2 (race-the-beam) and 3 (IX conversion) are the high-risk ones — each independently committed and checkpoint-gated. Stage 2 deliberately isolates the race-the-beam risk before the slot mechanism changes.
- **No pre-written Z80:** the renderer is rewritten by adapting named existing routines; the heavy steps say what to build and what to study, not fabricated assembly. Same discipline as the prior renderer plan.
- **Measure, don't estimate:** all T-state expectations are checked with the border profiler at each checkpoint; if a stage's measurement contradicts the design, stop and re-plan.
