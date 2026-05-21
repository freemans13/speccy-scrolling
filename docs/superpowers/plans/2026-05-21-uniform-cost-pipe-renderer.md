# Uniform-Cost Pipe Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the spiky pipe renderer with a double-buffered renderer whose per-frame cost is flat (~46–48k T-states) — no wrap or recycle spikes.

**Architecture (Approach 2):** Two slot grids (live / shadow). Render the live grid. Prepare the shadow for the next byte position by **spreading the cheap target-address re-sync** across the 4-frame byte window; swap the grids on the byte boundary. A *recycling* column needs a full rebuild — amortised over the recycling pipe's lead time. (Approach 1 — fully rebuilding one whole column every frame — was implemented through Stage 4 and then **measured too costly**: ~30k T vs ~28k spare on a normal frame. See the spec's revision note.)

**Tech Stack:** Z80 assembly, sjasmplus, single file `src/main.asm` (~5000 lines). No unit-test harness.

**Spec:** `docs/superpowers/specs/2026-05-21-uniform-cost-pipe-renderer-design.md`

---

## Nature of this plan

This is a **staged** plan for a high-risk restructuring of the core renderer.
Each stage (= one task) is a self-contained milestone that leaves the game
**building clean and runnable**, validated in Fuse via the border profiler.

The heavy stages instruct the implementer to **study the named existing
routines and reproduce/adapt their formats** — pre-writing that Z80 blind
would be fabrication. Each such stage names the exact routines to read first.

**Per-stage verification:**
1. `make` from the project root → `Errors: 0, warnings: 0` (and the
   `ASSERT $ <= GRID_B` guard passes).
2. CHECKPOINT: the human runs `make run` in Fuse and confirms the stated
   visual / border-profiler criteria. The assistant cannot run the emulator.
   **Measure with the profiler — do not trust T-state estimates** (pre-build
   estimates were repeatedly wrong this project).

Stages must be executed in order; later stages depend on earlier ones.

---

## Stage 1: Render through an SMC-patched grid pointer

**Goal:** `redraw_pipes_v2` calls the grid through a patchable target instead of the hard-coded `PIPE_PROGRAM` ($DB00). With the target still set to $DB00, behaviour is identical. This proves the indirection before a second grid exists.

**Files:** Modify `src/main.asm` — `redraw_pipes_v2` (the `call PIPE_PROGRAM` at the line reading `call    PIPE_PROGRAM`, currently ~3145).

**CRITICAL constraint:** `redraw_pipes_v2` sets `HL = 0` in *both* register banks
immediately before entering the grid — body slots `push hl` to write a
trailing-zero pair to the screen. The grid entry must therefore clobber **no
registers**. A register-indirect `jp (hl)` would corrupt the render. Use SMC:
the grid base lives in the operand of a `call`, which uses no registers.

- [ ] **Step 1: Label the grid call so its operand is SMC-addressable**

In `redraw_pipes_v2`, the tail is `ld (saved_sp), sp` / `call PIPE_PROGRAM` /
`ret`. Add a label on the `call` so later stages can patch its 2-byte operand:

```
        ld      (saved_sp), sp
grid_call:
        call    PIPE_PROGRAM            ; operand (grid_call+1) is SMC-patched to swap grids
        ret
```

This is the *only* change — behaviour is byte-identical to before (the
operand still says `PIPE_PROGRAM`). The "live grid pointer" is simply the
2 bytes at `grid_call+1`; no separate variable is needed.

- [ ] **Step 2: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 3: Commit** — `git commit -m "refactor: label the pipe grid call site for later SMC grid-swap"`.
- [ ] **Step 4: CHECKPOINT** — Human `make run`: game looks/runs **exactly as before** — pipes scroll, no glitch or pixel corruption.

> **STATUS: COMPLETE** (commits up to `40dd26d`).

---

## Stage 2: Allocate the second grid

**Goal:** Reserve a second 5120-byte grid `GRID_B` at `$AC00`; `GRID_A` aliases the existing grid; a `shadow_grid` variable tracks `GRID_B`. No behaviour change.

**Files:** Modify `src/main.asm` — EQU block; add `shadow_grid`; add `ASSERT $ <= GRID_B`.

- [ ] **Step 1:** Add `GRID_A EQU SLOT_GRID_BASE`, `GRID_B EQU $AC00`, `GRID_B_END EQU GRID_B + 160*SLOT_ROW_STRIDE`. Add `shadow_grid: dw GRID_B`. Add `ASSERT $ <= GRID_B` before `SAVESNA`.
- [ ] **Step 2: Build check / Commit / CHECKPOINT** — behaviour unchanged (`GRID_B` reserved, inert).

> **STATUS: COMPLETE** (commit `825fe9a`).

---

## Stage 3: Parameterise the grid builder; build both grids

**Goal:** The grid emitter (`init_pipe_program`) can target an arbitrary grid base; at init, build BOTH `GRID_A` and `GRID_B` identically. Render still uses `GRID_A`.

**Files:** Modify `src/main.asm` — `init_pipe_program`, `init_pipes`.

- [ ] **Step 1:** Parameterise the emitter on a base (`ipp_grid_base`, init-only). Rows 0–158 trailers base-relative; row 159 → shared epilogue `SLOT_GRID_END`.
- [ ] **Step 2:** At init, emit `GRID_A` then `GRID_B`; write the shared epilogue once.
- [ ] **Step 3: Build check / Commit / CHECKPOINT** — behaviour unchanged.

> **STATUS: COMPLETE** (commits up to `2069ec0`).

---

## Stage 4: The `rebuild_column` routine

**Goal:** A band-structured routine `rebuild_column` that rebuilds **one pipe's full slot column** into a given grid base, for that pipe's `byte_x`/`gap_y`. In Approach 2 this routine is used only for the **recycle** path (Stage 7) — a recycling column changes shape and needs a full rebuild.

**Files:** `src/main.asm` — `rebuild_column` + `rc_*` helpers and scratch.

- [ ] **Step 1:** Implement `rebuild_column` (band-structured: body / cap-top / skip / cap-bot / body), parameterised on pipe index + grid base, reusing `prep_step`'s slot byte formats. Measured cost ≈ 30k T per call.
- [ ] **Step 2–5:** Build / commit / verify byte-correctness as a no-op against `GRID_A`.

> **STATUS: COMPLETE** (commits up to `8e181a6`). Byte-correctness was verified
> ("looks the same"). The per-frame rolling cursor `rolling_rebuild_step` was
> built but is **disabled** (`ret` at entry, commit `5d1ad9a`) — Approach 1's
> every-frame full rebuild is too costly. `rebuild_column` itself is sound and
> is reused by Stage 7. The disabled cursor is removed in Stage 9.

---

## Stage 5: Grid-targeted, incremental target-imm patch

**Goal:** Adapt the target-immediate patcher so it can (a) patch a **given grid** (not just the live one) and (b) run **incrementally** — a cursor processes a slice of the active list per call, completing a full pass over the 4-frame byte window.

**Study first:** `patch_pipe_targets` and the active list (`ACTIVE_PIPE_0..3`, `ACTIVE_COUNT`); how each active-list entry is the address of a target-imm byte inside a `GRID_A` slot; `wrap_byte_x` (where `patch_pipe_targets` is currently tail-called); the `GRID_B - GRID_A` offset.

**Files:** Modify `src/main.asm` — add a grid-targeted incremental variant of `patch_pipe_targets` (e.g. `patch_shadow_step`), plus a cursor word. Do **not** yet remove the existing `patch_pipe_targets` call.

- [ ] **Step 1:** Add `patch_shadow_step`: walks ~¼ of the active list per call; for each entry, computes the *shadow* grid's corresponding imm address (`entry + (shadow_grid - GRID_A)`) and applies the byte-position decrement. A cursor word tracks progress; 4 calls = one full pass.
- [ ] **Step 2:** This stage only ADDS the routine — it is not yet wired into `main_loop`. Build-verify it assembles and the active-list arithmetic is sound.
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`, ASSERT passes.
- [ ] **Step 4: Commit** — `git commit -m "feat: grid-targeted incremental target-imm patch (patch_shadow_step)"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: behaviour unchanged (`patch_shadow_step` defined but uncalled).

---

## Stage 6: Activate the double-buffer — spread the patch, swap on wrap

**Goal:** The live behaviour change. Each frame, call `patch_shadow_step` (¼ of the patch). On the byte boundary, swap live/shadow (SMC-patch `grid_call+1`). The wrap-frame `patch_pipe_targets` single-shot spike is retired.

**Study first:** `main_loop` (where to call `patch_shadow_step` once/frame); `advance_phase` / `wrap_byte_x` (the byte-boundary crossing, currently where `patch_pipe_targets` runs); the grid leapfrog — the shadow grid is two byte-positions behind the live one and must be patched to the next position over each window.

**Files:** Modify `src/main.asm` — `main_loop`; `advance_phase` / `wrap_byte_x`.

- [ ] **Step 1:** Call `patch_shadow_step` once per frame from `main_loop` (a low-cost slot — it is ~3k T).
- [ ] **Step 2:** On the byte-boundary crossing: swap — read `grid_call+1`, write `shadow_grid` into it (SMC), store the old operand into `shadow_grid`. Reset the `patch_shadow_step` cursor for the new window.
- [ ] **Step 3:** Remove the old single-shot `patch_pipe_targets` call from `wrap_byte_x` (leave the routine defined; deleted in Stage 9). The shadow grid, fully patched over the prior window, is now correct for the live position.
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "feat: double-buffer the grid — spread imm-patch, swap on byte boundary"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes scroll smoothly with **no positional jump or tear** at byte boundaries. Border profiler: the ~28k white wrap-frame spike is **gone** — wrap frames now cost the same as normal frames.

---

## Stages 7–8: Combined — per-grid caps, then amortised recycle

> **Why combined / resequenced.** Investigation during Stage 6 found that caps,
> the shadow patch, the recycle rebuild and the active list are one entangled
> problem, so the plan's original "Stage 7 recycle → Stage 8 caps" order is
> wrong:
>
> - The `ACTIVE_PIPE_N` active list has 112 entries/pipe. **110 are body-slot
>   target-imm addresses inside GRID_A; 2 (cap_top, cap_bot) are cap-handler
>   imm addresses** outside the grid. `patch_shadow_step` blindly adds the
>   `shadow_grid − GRID_A` offset to *every* entry — correct for the 110 body
>   entries, **garbage for the 2 cap entries** (it decrements memory outside
>   both grids). Currently semi-masked by `update_cap_imm_v2` rewriting the
>   real cap imms each frame, but it is wrong and fragile.
> - The cap screen position lives in a **single shared handler imm**. With two
>   grids at two byte positions, `patch_shadow_step` scrolling the shadow's caps
>   would move the *live* grid's caps too. Caps must become **per-grid**.
> - `rebuild_column`'s recycle path (Stage 8) must regenerate the active list,
>   including those cap entries — so the cap representation must be settled
>   first.
>
> Therefore: **Stage 7 = per-grid caps (do this first); Stage 8 = recycle.**
> The 3+1-parked recycle model is retained (user decision: keep 3 visible pipes
> + 1 parked pipe; do **not** switch to 4 continuously-scrolling pipes).

---

## Stage 7: Per-grid caps — fold the cap target into the grid slot

**Goal:** A cap row's slot carries its **own per-grid screen target**, decremented by `patch_shadow_step` exactly like a body slot. The cap handler becomes geometry-free for horizontal position (reads its target from the slot, not a shared imm). This (a) makes all 112 active-list entries grid-slot addresses, so `patch_shadow_step`'s blanket offset-add is correct, and (b) gives each grid an independent cap position — a prerequisite for the double buffer being correct. The cap *bitmap* stays grid-independent phase state, still refreshed by `update_cap_imm_v2`.

**Study first (read before writing any code):**
- The cap handler routine(s): how a cap row's `jp cap_handler` resolves, where the cap screen position is read from, and — critically — **how the handler continues to the next slot (`slot+6`) after drawing** (the `_next` mechanism). The grid runs with `SP` hijacked to screen RAM, so the handler must `jp` onward, not `call`/`ret`.
- `update_cap_imm_v2` — which imms are the cap *screen target* (must move per-grid) vs the cap *phase bitmap* (stays shared).
- `CAP_TARGET_TABLE`, `CAP_BLOCK`, `cap_top_handler_addrs` / `cap_bot_handler_addrs`, `cap_*_handler_pipe_N_target`.
- Cap slot emission in three places that must all change: init cap config (`configure_pipe_slots` via `CAP_BLOCK`), `rebuild_column`'s `rc_stamp_cap_slot`, and the active-list build (`configure_pipe_slots` Step 6, lines ~1226–1256).
- `patch_shadow_step` (`pss_*`) — confirms it needs no cap special-casing once entries are all grid addresses.

**Design (confirm against the study):** Redefine the 6-byte cap slot to carry a per-grid target as the operand of a `ld sp, cap_target` (`$31 lo hi`) followed by a 3-byte `jp cap_handler` (`$C3 hh hl`). `patch_shadow_step` decrements the `lo,hi` like a body target; the active-list cap entry becomes `slot+1` (a grid address). The handler reads `SP` for the cap position and `jp`-continues to `slot+6`. **Open question to resolve in study:** how the handler reaches `slot+6` without a grid-specific `_next` imm — `slot+6` is grid+row+pipe specific. If a grid-independent continuation cannot be encoded in 6 bytes, fall back to **two cap-handler instances** (one per grid, each with its own `_next` imms maintained for that grid). Pick the encoding the study supports and record the decision in the commit message.

**Files:** Modify `src/main.asm` — cap slot format; cap handler(s); `configure_pipe_slots` (cap stamping + Step 6 active-list cap entries); `rc_stamp_cap_slot`; `update_cap_imm_v2`; remove any cap-entry special handling in `patch_shadow_step`.

- [ ] **Step 1:** From the study, decide and write down (as a comment block near the cap handler) the new 6-byte cap slot format and the handler-continuation mechanism.
- [ ] **Step 2:** Update the cap handler(s) to take the cap screen target from the slot; keep the phase-bitmap imms refreshed by `update_cap_imm_v2`.
- [ ] **Step 3:** Update every cap-slot emitter — init/`configure_pipe_slots` cap stamping, `rc_stamp_cap_slot` — to emit the new format into the target grid.
- [ ] **Step 4:** Update the active-list build (`configure_pipe_slots` Step 6) so the cap_top/cap_bot entries are the cap slot's target-imm addresses (grid addresses), not handler-imm addresses.
- [ ] **Step 5:** Confirm `patch_shadow_step` is now correct with all entries as grid addresses; remove any cap-entry workaround.
- [ ] **Step 6: Build check** — `make` → `Errors: 0, warnings: 0`, ASSERT passes.
- [ ] **Step 7: Commit** — `git commit -m "feat: per-grid caps — cap screen target folded into the grid slot"`.
- [ ] **Step 8: CHECKPOINT** — Human `make run`: caps render correctly with the live grid swapping between GRID_A/GRID_B every byte boundary — no cap tear, no stale cap position after a swap. (Recycle is still the old path; run up to just before the first recycle, ~30 frames.)

---

## Stage 8: Recycle via amortised rebuild into both grids

**Goal:** The freeze fix. When a pipe recycles, rebuild its full column at `byte_x=29` + new `gap_y` into **both** grids, amortised over the parked pipe's lead time, with `ACTIVE_PIPE_N` regenerated. Keep the 3+1-parked model and a thin swap; retire `prep_step`/`ps_phase0..6`/`configure_pipe_slots`.

**Study first:** `do_swap`, `prep_step` + `ps_phase0..6`, `wrap_byte_x`'s `.swap_with_prep` branch, `rebuild_column` + `rc_*` helpers, the active-list build in `configure_pipe_slots` Step 6, `random_gap_y`, `prep_pipe_idx` / `activate_pipe_idx`, `write_jrskip_column`, `do_swap_fired`; the parked-pipe lead time (the parked pipe holds a JR-skip column from when it departed at `byte_x=1` until the next swap re-activates it at `byte_x=29` — ~100 frames).

**Design:**
- `rebuild_column` becomes **row-sliced incremental**: a driver processes a bounded row count per call (cursor word holds `{pipe, grid, row}`), reusing `rc_stamp_body_band` / `rc_stamp_cap_slot` for sub-ranges; ~30k T spread over enough frames to stay inside the flat budget (≥8 frames per grid → ≤~4k T/frame).
- The driver (or `rebuild_column`) also **regenerates `ACTIVE_PIPE_N`** for the rebuilt pipe. Cap entries are now grid addresses (Stage 7), so the regen is uniform.
- Keep `do_swap` as a **thin swap only**: on `byte_x==1`, exchange active/parked roles — set incoming `byte_x=29`, pick the departing pipe's new `gap_y` (`random_gap_y`), set the departing column to JR-skip in **both** grids (`write_jrskip_column` targeting both), set `activate_pipe_idx=incoming`, mark "rebuild incoming column in both grids".
- **Amortised driver in `main_loop`** replaces the `prep_step` build loop: while a rebuild is pending, advance a slice into GRID_A (+ active list) first, then GRID_B. `activate_pipe_idx` keeps `patch_shadow_step` off the rebuilding column until both grids are done (it already skips `activate_pipe_idx`). Both grids must complete before the pipe scrolls visible — verify against the lead time.
- Retire the `prep_step` / `configure_pipe_slots` calls (routines left defined; deleted in Stage 9).

**Files:** Modify `src/main.asm` — `rebuild_column` (incremental driver + cursor + active-list regen); `do_swap` (thin swap); `write_jrskip_column` (both grids); `main_loop` (amortised driver replacing the `prep_step` loop); `wrap_byte_x`.

- [ ] **Step 1:** Make `rebuild_column` row-sliceable — add an incremental driver + `{pipe,grid,row}` cursor; include active-list regen. Build clean; not yet wired into `main_loop` (Stage-5 pattern). Commit `feat: row-sliced incremental rebuild_column with active-list regen`.
- [ ] **Step 2:** Thin `do_swap`: JR-skip the departing column in both grids; arm the both-grid rebuild of the incoming column.
- [ ] **Step 3:** Add the amortised rebuild driver to `main_loop`, replacing the `prep_step` build loop; remove the `prep_step` / `configure_pipe_slots` calls.
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "feat: recycle pipes via amortised rebuild_column into both grids"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes recycle correctly (re-enter from the right with a new gap, no corruption, **no freeze**, no multi-second reset). A full session survives indefinitely. Border profiler: **no recycle spike** — recycle frames cost the same as normal frames.

---

## Stage 9: Cleanup; restore uniform sound; re-enable the flap

**Goal:** Remove now-dead machinery and exploit the flat frame cost — give the beeper a uniform per-frame budget and re-enable the flap.

**Files:** Modify `src/main.asm` — delete dead routines/data; the disabled `rolling_rebuild_step`; sound budget constants and `main_loop` classification; `read_input`.

- [ ] **Step 1:** Delete the disabled `rolling_rebuild_step` and its `rc_cursor`; delete `prep_step` + `ps_phase0..6` and their scratch, `configure_pipe_slots`, `shift_pipe_targets`, the single-shot `patch_pipe_targets`, and any now-orphaned scratch/EQUs. **Keep** `do_swap` (now the thin swap), `write_jrskip_column`, and `rebuild_column`. Recompute the memory map. Build must stay clean.
- [ ] **Step 2:** Replace the per-frame-type sound budget classification in `main_loop` with a single uniform `SND_SLICE` budget — frames are now all ~equal cost. Set it from the profiler-measured headroom (~22k T → ~800–900 delay-iters; calibrate). Remove the wrap/build classification and the now-dead `sound_heavy_frame`.
- [ ] **Step 3:** Re-enable the flap: uncomment the `call sfx_trigger_flap` in `read_input`.
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "cleanup: delete retired renderer machinery; uniform sound budget; re-enable flap"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: flat 50 Hz throughout; flap and score sounds play cleanly on every frame with no flutter; border profiler shows uniform band heights, no frame near the 70k ceiling.

---

## Self-review notes

- **Spec coverage:** two grids (Stages 1–3 ✓), `rebuild_column` (Stage 4 ✓), grid-targeted incremental imm-patch (Stage 5 ✓), double-buffer swap + spread patch retiring the wrap spike (Stage 6 ✓ — scroll verified; freezes on recycle pending Stage 8), per-grid caps (Stage 7), amortised recycle into both grids (Stage 8), cleanup + uniform sound + flap (Stage 9) — all Approach-2 spec sections mapped.
- **Approach-2 pivot:** Stages 1–4 are complete from the Approach-1 attempt and carry over unchanged. Stages 5–9 are the Approach-2 strategy (spread the cheap re-sync; amortise the recycle) — the per-frame full rebuild is abandoned.
- **Stages 7–8 resequenced:** the original Stage 7 (recycle) / Stage 8 (caps) order was inverted — caps must be made per-grid *before* the recycle rebuild, because the recycle regenerates the active list whose cap entries depend on the cap representation, and because `patch_shadow_step` is already incorrect on cap entries without the per-grid fix. See the combined-stages note above.
- **Staging discipline:** every stage ends building clean. Stages 7–8 are checkpoint-gated; the Stage 7 checkpoint can only verify up to the first recycle (the freeze fix lands in Stage 8).
- **Risk:** Stage 6 (done), Stage 7 (cap-format change touching the SP-hijacked grid) and Stage 8 (recycle) are the dangerous ones — each independently committed and checkpoint-gated. Measure with the profiler; do not trust estimates.
