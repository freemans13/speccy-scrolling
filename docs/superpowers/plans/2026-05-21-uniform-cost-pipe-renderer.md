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

## Stage 7: Recycle into the shadow grid (amortised rebuild)

**Goal:** When a pipe recycles (`byte_x → 29`, new `gap_y`), its column changes shape and needs a full `rebuild_column` — in **both** grids. Amortise these rebuilds over the recycling pipe's invisible lead time so no frame spikes. Retire the old `do_swap` / `prep_step` configure path.

**Study first:** `do_swap`, `prep_step`, `ps_phase6`, `wrap_byte_x`'s recycle branch, `random_gap_y`, `prep_pipe_idx`; the buffer-column lead time a recycled pipe has before becoming visible.

**Files:** Modify `src/main.asm` — `wrap_byte_x` recycle branch; an amortised recycle-rebuild driver in `main_loop`; remove `do_swap` / `prep_step` / `configure_pipe_slots` calls.

- [ ] **Step 1:** On recycle, set the pipe's `byte_x = 29` and a new `gap_y`, and mark its column "needs full rebuild in both grids".
- [ ] **Step 2:** Add an amortised driver: each frame, advance a bounded slice of the recycled column's `rebuild_column` into whichever grid still needs it. Ensure both grids' copies of that column are complete before the pipe scrolls into view (verify against the buffer-column lead time; the recycled column gets rebuild priority that window).
- [ ] **Step 3:** Remove the `do_swap` / `prep_step` / `configure_pipe_slots` calls (routines left defined; deleted in Stage 9).
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "feat: recycle pipes via amortised rebuild_column into both grids"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes recycle correctly (re-enter from the right with a new gap, no corruption, no multi-second reset crash). Border profiler: **no recycle spike** — recycle frames cost the same as normal frames.

---

## Stage 8: Cap handlers under double-buffering

**Goal:** Cap rows `JP` to shared cap handlers carrying byte-position imms; with two grids at two byte positions, cap state must be per-grid. Resolve this.

**Study first:** the cap handler routines, `update_cap_imm_v2`, `CAP_TARGET_TABLE`, `ps_cap_top_target` / `ps_cap_bot_target`; how a cap row's `JP cap_handler` resolves and where the cap screen position lives; how `patch_shadow_step` and `rebuild_column` touch cap rows.

**Files:** Modify `src/main.asm` — cap handler(s), `update_cap_imm_v2`, `patch_shadow_step` / `rebuild_column` cap handling.

- [ ] **Step 1:** Implement per-grid cap state — either (a) two cap-handler instances, one per grid, each with imms maintained for that grid; or (b) fold the cap screen position into the grid slot so the handler is geometry-free. Choose (a) unless (b) is clearly simpler after study.
- [ ] **Step 2:** Ensure the spread patch and the recycle rebuild maintain the correct grid's cap state; update/retire `update_cap_imm_v2`.
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 4: Commit** — `git commit -m "feat: per-grid cap handling for the double-buffered renderer"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: pipe caps render correctly across scrolling and recycle — no cap tearing, no stale cap position after a swap.

---

## Stage 9: Cleanup; restore uniform sound; re-enable the flap

**Goal:** Remove now-dead machinery and exploit the flat frame cost — give the beeper a uniform per-frame budget and re-enable the flap.

**Files:** Modify `src/main.asm` — delete dead routines/data; the disabled `rolling_rebuild_step`; sound budget constants and `main_loop` classification; `read_input`.

- [ ] **Step 1:** Delete the disabled `rolling_rebuild_step` and its `rc_cursor`; delete `do_swap`, `prep_step`, `configure_pipe_slots`, the single-shot `patch_pipe_targets`, the JR-skip prep-column code, and any now-orphaned scratch/EQUs. Recompute the memory map. Build must stay clean.
- [ ] **Step 2:** Replace the per-frame-type sound budget classification in `main_loop` with a single uniform `SND_SLICE` budget — frames are now all ~equal cost. Set it from the profiler-measured headroom (~22k T → ~800–900 delay-iters; calibrate). Remove the wrap/build classification and the now-dead `sound_heavy_frame`.
- [ ] **Step 3:** Re-enable the flap: uncomment the `call sfx_trigger_flap` in `read_input`.
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "cleanup: delete retired renderer machinery; uniform sound budget; re-enable flap"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: flat 50 Hz throughout; flap and score sounds play cleanly on every frame with no flutter; border profiler shows uniform band heights, no frame near the 70k ceiling.

---

## Self-review notes

- **Spec coverage:** two grids (Stages 1–3 ✓), `rebuild_column` (Stage 4 ✓), grid-targeted incremental imm-patch (Stage 5), double-buffer swap + spread patch retiring the wrap spike (Stage 6), recycle via amortised rebuild retiring `do_swap`/`prep_step` (Stage 7), per-grid cap handlers (Stage 8), cleanup + uniform sound + flap (Stage 9) — all Approach-2 spec sections mapped.
- **Approach-2 pivot:** Stages 1–4 are complete from the Approach-1 attempt and carry over unchanged. Stages 5–9 are the Approach-2 strategy (spread the cheap re-sync; amortise the recycle) — the per-frame full rebuild is abandoned.
- **Staging discipline:** every stage ends building clean and runnable with a profiler checkpoint.
- **Risk:** Stage 6 (live double-buffer swap) and Stage 7 (recycle) are the dangerous ones — each independently committed and checkpoint-gated. Measure with the profiler; do not trust estimates.
