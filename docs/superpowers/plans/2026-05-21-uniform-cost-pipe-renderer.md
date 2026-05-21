# Uniform-Cost Pipe Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the spiky pipe renderer with a double-buffered, rolling-rebuild design so every frame costs a flat ~32–35k T-states — no wrap or recycle spikes.

**Architecture:** Two slot grids (live / shadow). Render from the live grid; each frame rebuild one pipe's column into the shadow grid band-by-band; swap the two on a byte-boundary crossing. Recycle is absorbed into the rebuild, retiring `do_swap` / `prep_step` / `configure_pipe_slots` / the active list / `patch_pipe_targets`.

**Tech Stack:** Z80 assembly, sjasmplus, single file `src/main.asm` (~4800 lines). No unit-test harness.

**Spec:** `docs/superpowers/specs/2026-05-21-uniform-cost-pipe-renderer-design.md`

---

## Nature of this plan

This is a **staged** plan for a high-risk replacement of the core renderer.
Each stage (= one task) is a self-contained milestone that leaves the game
**building clean and runnable**, validated in Fuse via the border profiler.

Because the rolling rebuild must mirror the *existing* slot, template, and
cap-handler byte formats exactly, the heavy stages instruct the implementer to
**study the named existing routines and reproduce their formats** — pre-writing
that Z80 blind would be fabrication. Each such stage names the exact routines
to read first. Stage 1 (mechanical) is given as concrete code.

**Per-stage verification:**
1. `make` from the project root → `Errors: 0, warnings: 0`.
2. CHECKPOINT: the human runs `make run` in Fuse and confirms the stated
   visual / border-profiler criteria. The assistant cannot run the emulator.

Stages must be executed in order; later stages depend on earlier ones.

---

## Stage 1: Render through an SMC-patched grid pointer

**Goal:** `redraw_pipes_v2` calls the grid through a patchable target instead of the hard-coded `PIPE_PROGRAM` ($DB00). With the target still set to $DB00, behaviour is identical. This proves the indirection before a second grid exists.

**Files:** Modify `src/main.asm` — `redraw_pipes_v2` (the `call PIPE_PROGRAM` at the line reading `call    PIPE_PROGRAM`, currently ~3145).

- [ ] **Step 1: Add a live-grid base variable**

Insert near the pipe state declarations (after `pipe_state` block, alongside other `dw` scratch like `body_a_bc`):

```
live_grid:   dw PIPE_PROGRAM          ; base of the grid redraw_pipes_v2 renders
```

- [ ] **Step 2: Render through the pointer**

In `redraw_pipes_v2`, replace:

```
        call    PIPE_PROGRAM
```

with an indirect call (Z80 has no `call (hl)`; push a return address and `jp (hl)`):

```
        ld      hl, .pp_return
        push    hl                      ; return address for the grid epilogue's RET
        ld      hl, (live_grid)
        jp      (hl)
.pp_return:
```

The grid epilogue is `ld sp,(saved_sp) ; ret` — the `ret` consumes the pushed `.pp_return`. Behaviour is identical to the old `call`.

- [ ] **Step 3: Build check**

Run: `make` — expect `Errors: 0, warnings: 0`.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "refactor: render pipe grid through a live_grid pointer"
```

- [ ] **Step 5: CHECKPOINT**

Human runs `make run`: the game must look and run **exactly as before** — pipes scroll, no glitch, border profile unchanged. This verifies the indirect call path.

---

## Stage 2: Allocate the second grid (memory reshuffle)

**Goal:** Reserve a second 5120-byte grid (`GRID_B`) and a renamed `GRID_A` for the existing one, with no behaviour change. `live_grid` / a new `shadow_grid` both initially point at `GRID_A`.

**Study first:** the EQU/memory-map block at the top of `src/main.asm` (lines ~12–80) — `SLOT_GRID_BASE`, `SLOT_GRID_END`, `SLOT_ADDR_TABLE`, `ACTIVE_PIPE_0..3`, `ACTIVE_LIST_END`; and confirm the top of free RAM vs the stack at `$8000`.

**Files:** Modify `src/main.asm` — EQU block; add `shadow_grid` variable.

- [ ] **Step 1: Define GRID_A / GRID_B**

Add EQUs: `GRID_A EQU SLOT_GRID_BASE` (existing grid, unchanged address). Place `GRID_B` in 5120 contiguous free bytes. Candidate space: after `SLOT_GRID_END` and the active lists are reclaimed in later stages, but for now find a free 5120-byte run. If none is contiguous, this step also relocates `SLOT_ADDR_TABLE` / active lists to free a run — make those moves explicitly here and recompute every dependent EQU. Document the final map in a comment block.

- [ ] **Step 2: Add the shadow_grid variable**

```
shadow_grid: dw GRID_B                 ; grid currently being rebuilt
```

and change `live_grid` initial value to `GRID_A`.

- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: reserve second pipe grid GRID_B and memory map for it"
```

- [ ] **Step 5: CHECKPOINT** — Human `make run`: behaviour unchanged (GRID_B exists but is unused/unbuilt).

---

## Stage 3: Parameterise the grid builder; build GRID_B as a clone

**Goal:** The routine that emits the slot grid (`init_pipe_program` and whatever the build/`prep_step` path uses) can target an arbitrary grid base. At init, build BOTH grids identically. Render still uses `GRID_A`.

**Study first:** `init_pipe_program` and the row-emission loop (slot byte format `$31 lo hi $E5 $D5 $C5`, the `EXX`, the `JP next-row` trailer); `SLOT_ROW_STRIDE`; how row JP-trailers are computed (they must point within the *same* grid — so the builder must add the grid base, not assume `$DB00`).

**Files:** Modify `src/main.asm` — grid-emission routine(s).

- [ ] **Step 1:** Add a grid-base parameter (a register or an SMC-patched base word) to the grid emitter so it writes rows and JP-trailers relative to a given base.
- [ ] **Step 2:** At init, call the emitter twice — once for `GRID_A`, once for `GRID_B` — producing two byte-identical grids for the current pipe geometry.
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 4: Commit** — `git commit -m "feat: parameterise grid emitter on base; build both grids at init"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: behaviour unchanged. (Optional diagnostic: temporarily point `live_grid` at `GRID_B` and confirm the game still renders correctly, then revert — proves GRID_B is a valid grid.)

---

## Stage 4: The rolling column-rebuild routine

**Goal:** A routine `rebuild_column` that rebuilds **one pipe's full slot column** into a given grid, band-structured (body band / cap-top / skip band / cap-bot / body band), for that pipe's current `byte_x` and `gap_y`. Initially exercised as a no-op verifier: each frame, rebuild one column of the *live* grid to its *current* geometry — output must be byte-identical to what is already there.

**Study first:** `prep_step` (the 7-phase column builder — it already does exactly this work, spread differently); `BODY_TEMPLATE`, `CAP_BLOCK`, `CAP_TARGET_TABLE`; how a body slot's target address is computed (`line_table` / per-row screen address + `byte_x` offset); the cap row range computation from `gap_y`.

**Files:** Modify `src/main.asm` — add `rebuild_column`; add a per-frame rebuild cursor in `main_loop`.

- [ ] **Step 1:** Implement `rebuild_column` (pipe index + target grid base → stamps that pipe's column band-by-band). Reuse `BODY_TEMPLATE` / `CAP_BLOCK` stamping logic from `prep_step`. Hard target ≤8k T-states; count it with the border profiler.
- [ ] **Step 2:** In `main_loop`, add a cursor that calls `rebuild_column` for one pipe per frame against the **live** grid at its current geometry (a self-overwrite with identical bytes).
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 4: Commit** — `git commit -m "feat: band-structured rolling column rebuild (no-op verify)"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: pipes render **identically** (the rebuild reproduces the existing grid). Border profiler: the rebuild band is ≤8k T and the frame stays well under 70k.

---

## Stage 5: Double-buffer activation and swap

**Goal:** The rolling rebuild targets the **shadow** grid for the *next* byte position; on a byte-boundary crossing, swap `live_grid` / `shadow_grid` (SMC-patch the render target) and recompute shadow `byte_x` values. Retire `patch_pipe_targets`.

**Study first:** `advance_phase` / `wrap_byte_x` (where `byte_x` steps and where `patch_pipe_targets` is currently called); the SMC render-target from Stage 1.

**Files:** Modify `src/main.asm` — `main_loop` rebuild cursor; `advance_phase` / `wrap_byte_x`; remove the `patch_pipe_targets` call.

- [ ] **Step 1:** Rebuild cursor targets `shadow_grid`, building each pipe's column for `byte_x − 1` (the next window). One pipe per frame; all four done across the 4-frame window.
- [ ] **Step 2:** On the byte-boundary crossing, swap the live/shadow pointers (and SMC render target) and update the shadow pipes' `byte_x`.
- [ ] **Step 3:** Remove the `patch_pipe_targets` call from the wrap path (leave the routine defined for now; deleted in Stage 8).
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "feat: double-buffer the pipe grid; swap on byte boundary"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes scroll smoothly with **no positional jump or tear** at byte boundaries. Border profiler: no wrap spike — wrap frames now cost the same as normal frames.

---

## Stage 6: Recycle via the rebuild

**Goal:** When a pipe reaches the left edge, recycle it (`byte_x → 29`, new `gap_y`) by simply updating its state — the rolling rebuild then stamps its new column for free. Retire `do_swap`, `prep_step`, `configure_pipe_slots`.

**Study first:** `do_swap`, `prep_step`, `ps_phase6`, `wrap_byte_x`'s recycle branch, `random_gap_y`, `prep_pipe_idx` / `activate_pipe_idx`.

**Files:** Modify `src/main.asm` — `wrap_byte_x` recycle branch; remove calls into `do_swap` / `prep_step` / `configure_pipe_slots`.

- [ ] **Step 1:** Replace the `do_swap` call with a minimal recycle: set the pipe's `byte_x = 29` and pick a new `gap_y`. The shadow rebuild already rebuilds full columns, so the recycled pipe's new column is produced on the normal cursor schedule.
- [ ] **Step 2:** Confirm the rebuild reaches the recycled pipe's column before that pipe becomes visible (it re-enters at the invisible buffer column `byte_x=29`; verify the 4-frame rebuild window covers the 4-frame `byte_x=29` dwell). If the timing is tight, the recycled pipe is rebuilt first on the cursor that window.
- [ ] **Step 3:** Remove calls to `do_swap` / `prep_step` / `configure_pipe_slots` (routines left defined; deleted in Stage 8).
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "feat: recycle pipes via the rolling rebuild; retire do_swap path"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: pipes recycle correctly (re-enter from the right with a new gap, no corruption, no ~2–4s reset crash). Border profiler: **no recycle spike** — recycle frames cost the same as normal frames.

---

## Stage 7: Cap handlers under double-buffering

**Goal:** Resolve the spec's open detail — cap rows currently `JP` to shared handlers carrying byte-position imms; with two grids representing two byte windows, cap state must be per-grid.

**Study first:** the cap handler routines, `update_cap_imm_v2`, `CAP_TARGET_TABLE`, `cap_top_target_imm_addrs`, `ps_cap_top_target` / `ps_cap_bot_target`; how a cap row's `JP cap_handler` resolves and where the cap's screen position lives.

**Files:** Modify `src/main.asm` — cap handler(s), `update_cap_imm_v2`, `rebuild_column`'s cap bands.

- [ ] **Step 1:** Decide and implement the per-grid cap approach — either (a) two cap-handler instances, one per grid, each with its own imms written by `rebuild_column` when it stamps that grid's cap bands; or (b) fold the cap screen position into the grid slot so the handler is geometry-free. Choose (a) unless studying the handler shows (b) is clearly simpler.
- [ ] **Step 2:** Update `rebuild_column` to stamp the chosen grid's cap state. Update / retire `update_cap_imm_v2` accordingly.
- [ ] **Step 3: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 4: Commit** — `git commit -m "feat: per-grid cap handling for the double-buffered renderer"`.
- [ ] **Step 5: CHECKPOINT** — Human `make run`: pipe caps render correctly in both grids across scrolling and recycle — no cap tearing, no stale cap position after a swap.

---

## Stage 8: Delete dead machinery; re-uniform the sound; re-enable the flap

**Goal:** Remove the now-unused old machinery, and exploit the flat frame cost: give the beeper a uniform per-frame budget and re-enable the flap.

**Files:** Modify `src/main.asm` — delete dead routines/data; sound budget constants and `main_loop` classification; `read_input`.

- [ ] **Step 1:** Delete `do_swap`, `prep_step`, `configure_pipe_slots`, `patch_pipe_targets`, the active list (`ACTIVE_PIPE_0..3`), the JR-skip column code, `SLOT_ADDR_TABLE`, and any now-orphaned scratch/EQUs. Recompute the memory map. Build must stay clean.
- [ ] **Step 2:** Replace the three-way sound budget classification in `main_loop` with a single uniform `SND_SLICE` budget (frames are now all ~equal cost; pick a value with profiler margin). Remove the wrap/build classification and the now-dead `sound_heavy_frame`.
- [ ] **Step 3:** Re-enable the flap: uncomment the `call sfx_trigger_flap` in `read_input`.
- [ ] **Step 4: Build check** — `make` → `Errors: 0, warnings: 0`.
- [ ] **Step 5: Commit** — `git commit -m "cleanup: delete retired renderer machinery; uniform sound budget; re-enable flap"`.
- [ ] **Step 6: CHECKPOINT** — Human `make run`: flat 50 Hz throughout; flap and score sounds both play cleanly on every frame with no flutter; border profiler shows uniform band heights everywhere, no frame near the 70k ceiling.

---

## Self-review notes

- **Spec coverage:** two grids (Stages 1–3), render-from-live (Stage 1), rolling band-structured rebuild (Stage 4), swap-on-wrap retiring `patch_pipe_targets` (Stage 5), recycle absorbed retiring `do_swap`/`prep_step`/`configure` (Stage 6), cap handlers under double-buffer (Stage 7), deletions + memory reclaim + uniform sound + flap (Stage 8) — all spec sections mapped.
- **Staging discipline:** every stage ends building clean and runnable, with a profiler checkpoint — matches the spec's "keep the build runnable / validate each stage" requirement.
- **Honest deferral:** the rebuild-internal and cap-handler stages name the exact existing routines to mirror rather than pre-writing speculative Z80 — this is deliberate for an assembly rewrite, not a placeholder gap.
- **Risk:** Stages 5–7 are the dangerous ones (live double-buffer, recycle, caps). Each is independently committed and checkpoint-gated so a regression is isolated to one stage.
