# Skip the prep-pipe column — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PIPE_PROGRAM` step over the invisible prep-pipe's slot column with a 12 T `JR +4` per row instead of executing a 43 T body push, saving ~3,526 T/frame steady, with no visual change.

**Architecture:** A pipe's slot column is held as JR-skip slots (`$18 $04 $00 $00 $00 $00`) for its whole ~37-frame prep window. The real column build (`prep_step`) is re-timed to run *after* the pipe activates, while the pipe is frozen at `byte_x=29` (invisible). Once the build completes the pipe unfreezes and joins the scroll.

**Tech Stack:** Z80 assembly, sjasmplus, single file `src/main.asm`. No unit-test framework — verification is `make` (expect `Errors: 0, warnings: 0`) plus a human `make run` in Fuse. The assistant cannot run the emulator.

**Important context for the implementer:**
- This is an interlocked lifecycle refactor. Read the design spec `docs/superpowers/specs/2026-05-21-skip-prep-column-design.md` first.
- Read these auto-memory files before starting — each documents a trap this change can re-trigger: `do_swap_partial_rewrite_bug`, `active_pipe_stale_entries`, `exx_djnz_bank_bug`, `slot_grid_nop_slide`, `split_cap_handler_race`. Path: `~/.claude-personal/projects/-Users-freemans-github-freemans13-speccy-scrolling/memory/`.
- The asm in this plan is given as **algorithm + register contract + reference routine to mimic**, not pre-written line-by-line. Z80 of this intricacy must be written iteratively against the assembler. Each task ends build-clean and is human-verified before the next starts.
- Regenerate the listing before inspecting addresses: `tools/sjasmplus/sjasmplus --fullpath --lst=build/main.lst src/main.asm`.

---

## Lifecycle reference (current vs target)

**Current:** column always holds real slots. `do_swap` retargets the departing column's body slots to `byte_x=29`. `prep_step` rebuilds the prep column over its ~37-frame prep window — the column executes real (invisible) slots the whole time = the waste.

**Target:** a pipe's column is JR-skip during its ~37-frame prep window. At `do_swap`, the activating pipe is frozen at `byte_x=29`; `prep_step` (driven by a new `activate_pipe_idx`) rebuilds *that* column post-swap; when `prep_phase` reaches 7 the pipe unfreezes. The departing column is rewritten to JR-skip and becomes the next prep column.

**Key invariant:** a column is JR-skip ⟺ its pipe is not currently rendering visible output. Exactly one column is JR-skip at any time except for the build window, where the activating column is transitioning JR-skip→real.

---

## Phase 1 — Add the JR-skip primitive (no behaviour change)

### Task 1: Add a JR-skip column writer

**Files:**
- Modify: `src/main.asm` — add a new routine near `build_slot_templates` (line ~1333) / `init_pipe_program` (line ~479).

- [ ] **Step 1: Add `write_jrskip_column`**

Routine contract:
- **In:** `A` = pipe index (0..3).
- **Effect:** writes the 6-byte pattern `$18 $04 $00 $00 $00 $00` into all 160 slots of that pipe's column in `PIPE_PROGRAM`, and writes `$D9` (EXX) into each row's pre-slot byte if not already present (rows still need their EXX + JP trailer intact — only the 6 slot bytes change).
- Slot address: `slot[row][pipe] = SLOT_GRID_BASE + 1 + row*32 + pipe*6` — mimic the address math in `do_swap` step 2 (lines 2615-2641) and `init_pipe_program` (lines 495-507).
- Do **not** touch the EXX byte, the other 3 columns, the row trailer, or pad bytes. Only the 6 bytes of this pipe's slot per row.
- Clobbers: AF, BC, DE, HL, IY are all free here.

Why `$18 $04`: `JR e` with `e=$04` advances PC by `2 + 4 = 6` from the slot start — exactly to the next slot. Same pattern already used for cap-skip rows in `build_slot_templates` (lines 1378-1392).

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`. The routine is defined but not yet called — no behaviour change.

- [ ] **Step 3: Commit**

```bash
git add src/main.asm
git commit -m "feat: add write_jrskip_column (prep-column skip primitive)"
```

### Task 2: Add the activate-lifecycle state variables

**Files:**
- Modify: `src/main.asm` — near the existing prep state vars (`prep_pipe_idx` line 197, `prep_phase` line 206, etc.).

- [ ] **Step 1: Add variables**

```
activate_pipe_idx:  db 255      ; pipe whose column prep_step is currently building post-swap; 255 = none
```

`prep_phase`, `prep_row`, `prep_gap_y` are **reused** as-is — they already drive `prep_step`. `activate_pipe_idx` is the only new variable; it redirects `prep_step` from "the prep pipe" to "the activating pipe". Initialise to 255 (no build in progress).

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 3: Commit**

```bash
git add src/main.asm
git commit -m "feat: add activate_pipe_idx lifecycle variable"
```

---

## Phase 2 — Re-time the build and cut over (behaviour change)

> After every task in this phase, the human runs `make run` for ≥ 30 s of play and ≥ 10 swap cycles, watching for resets, mid-screen corruption, and missing/garbled pipes. Do not start the next task until the human confirms green.

### Task 3: Point `prep_step` at `activate_pipe_idx`

**Files:**
- Modify: `src/main.asm` — `prep_step` and its phases `ps_phase0`..`ps_phase6` (lines 1635-2064), and `ps_slot_addr_for_row` (line 1578).

**Context:** `prep_step` and its phases currently read `prep_pipe_idx` to decide which column to build (e.g. `ps_slot_addr_for_row` at line 1578, `ps_phase0` at 1676). The build target must become `activate_pipe_idx`.

- [ ] **Step 1: Replace the column-index source**

In `prep_step`, `ps_phase0`..`ps_phase6`, and `ps_slot_addr_for_row`: every read of `prep_pipe_idx` that selects *which column to write* becomes a read of `activate_pipe_idx`. Reads of `prep_pipe_idx` used for *skipping* (none should be in `prep_step`) stay. Grep for `prep_pipe_idx` within lines 1578-2064 and audit each occurrence.

- [ ] **Step 2: Guard `prep_step` against `activate_pipe_idx == 255`**

At the top of `prep_step` (line 1635): if `activate_pipe_idx == 255`, `ret` immediately (nothing to build).

- [ ] **Step 3: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 4: Manual smoke check**

At this point `activate_pipe_idx` is still 255 forever (nothing sets it), so `prep_step` is now effectively disabled. The game will mis-prepare pipes — this task is **expected to look broken on `make run`**. Confirm the build is clean and commit; the next task wires the trigger. Tell the human: "Expect broken pipes after this commit — Task 4 fixes it."

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "refactor: prep_step builds activate_pipe_idx column, gated on 255 sentinel"
```

### Task 4: Make `do_swap` JR-skip the departing column and trigger the post-swap build

**Files:**
- Modify: `src/main.asm` — `do_swap` full-swap path (lines 2584-2972).

**Context:** Read the full `do_swap.full_swap` path first. Today it: (1) sets incoming `byte_x=29`/`gap_y`; (2-3) arms incoming cap slots + writes cap target imms; (5) rewrites the departing column's 160 body-slot targets to `byte_x=29`; (7) sets `prep_pipe_idx=dep`, picks new `gap_y`, resets `prep_phase=0`.

- [ ] **Step 1: Replace step 5 (departing-column rewrite) with a JR-skip write**

The departing column must become JR-skip. Replace the step-5 body-slot-target rewrite (the ~160-row loop, per the do_swap header comment lines 2453-2458) with a call to `write_jrskip_column` (Task 1) with `A = ds_dep`. This writes all 6 bytes of every slot — which also satisfies the `do_swap_partial_rewrite_bug` trap (no stale bytes left). Step-5's old cap-deactivate sub-step is now redundant (the JR-skip overwrites cap rows too) — remove it.

- [ ] **Step 2: Move incoming cap-arming out of `do_swap`**

Steps 2 and 3 (arming the incoming column's cap slots + cap target imms, lines 2611-2764-ish) must be **deleted from `do_swap`** — the incoming column is now JR-skip and gets fully rebuilt (caps included) by `prep_step` post-swap. `prep_step`'s phases already arm caps (`ps_phase` cap handling); confirm `prep_step` covers cap arming before deleting from `do_swap`. If `prep_step` does NOT currently arm caps (verify against `ps_phase3`..`ps_phase6`), keep do_swap step 2-3 but retarget it to run after the build instead — note this for the implementer to resolve against the actual phase code.

- [ ] **Step 3: Trigger the post-swap build**

After `do_swap` sets `prep_pipe_idx = dep` (step 7), also set:
- `activate_pipe_idx = ds_inc` (the just-activated pipe — its column needs building).
- `prep_phase = 0`, `prep_row = 0` (restart the build machine; these resets likely already exist in step 7 — verify).
- `prep_gap_y` = the new incoming pipe's `gap_y` (the build needs it; today `prep_gap_y` is the pre-swap value — confirm it now holds the activating pipe's gap_y, set it explicitly if not).

Keep `do_swap` setting incoming `byte_x=29` (step 1) — the freeze relies on it.

- [ ] **Step 4: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`. Regenerate the listing and recompute `SLOT_GRID_END` if slot emission size changed (memory: `slot_grid_nop_slide`).

- [ ] **Step 5: Human verification**

`make run`, ≥ 30 s, ≥ 10 swaps. The activating pipe is not yet frozen (Task 5) so it may scroll in half-built — expect possible transient corruption on the entering pipe. Confirm: no resets, the 3 established pipes render correctly, swaps still occur. Tell the human what to expect.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "refactor: do_swap JR-skips departing column, triggers post-swap build"
```

### Task 5: Freeze the activating pipe until its build completes

**Files:**
- Modify: `src/main.asm` — `wrap_byte_x` (lines 2390-2444), `patch_pipe_targets` (lines 2198-2378).

**Context:** While `activate_pipe_idx`'s column is being built (`prep_phase < 7`), that pipe must not scroll (`wrap_byte_x` must not decrement its `byte_x`) and must not be walked by `patch_pipe_targets`.

- [ ] **Step 1: Freeze in `wrap_byte_x`**

In the `.outer` loop (lines 2393-2430), the per-pipe skip currently tests `prep_pipe_idx` (lines 2398-2400). Add: also skip the pipe if `C == activate_pipe_idx` AND `prep_phase != 7`. When the build is done (`prep_phase == 7`) clear `activate_pipe_idx` back to 255 so the pipe scrolls normally from then on — do this clear once, e.g. in `wrap_byte_x` after the loop, or in `prep_step` when it reaches phase 7.

- [ ] **Step 2: Freeze in `patch_pipe_targets`**

`patch_pipe_targets` (lines 2198-2378) currently skips only `prep_pipe_idx` (the per-pipe `cp`/`jr z` at 2211, 2253, 2295, 2337). Add the same `activate_pipe_idx`-while-building skip for each of the 4 pipe blocks. A half-built column has JR-skip slots with no target imms — walking it would corrupt memory (memory: `active_pipe_stale_entries`).

- [ ] **Step 3: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 4: Human verification**

`make run`, ≥ 60 s, ≥ 15 swaps. Now the activating pipe should freeze at the right edge (`byte_x=29`, invisible), then start scrolling in cleanly once built. Confirm: no resets, no corruption, every pipe renders fully, swap cadence looks normal. **Confirm the all-black-border frames are reduced** (this is the symptom we are chasing). Use border profiling if needed.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "feat: freeze activating pipe at byte_x=29 until column build completes"
```

### Task 6: Initialise pipe 3's column as JR-skip at startup

**Files:**
- Modify: `src/main.asm` — `init_pipe_program` (lines 479-610), `init_pipes` (lines 1468-1577).

**Context:** At startup pipe 3 is the prep pipe (`prep_pipe_idx db 3`, line 197). Its column must start as JR-skip, and no build should be in progress.

- [ ] **Step 1: JR-skip pipe 3 at init**

After `init_pipe_program` emits the grid and `init_pipes` configures pipes 0-2, call `write_jrskip_column` with `A=3`. Ensure `init_pipes` does NOT also run the old prep build for pipe 3. Set `activate_pipe_idx = 255` and `prep_phase = 7` (idle) at init so `prep_step` does nothing until the first `do_swap`.

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 3: Human verification**

`make run`. Confirm the game starts correctly (3 visible pipes, pipe 3 invisible at the right), and runs ≥ 60 s / ≥ 15 swaps clean. The first swap should still produce a correct entering pipe.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: init pipe 3 column as JR-skip; build idle until first swap"
```

---

## Phase 3 — Cleanup

### Task 7: Remove dead prep-lifecycle code and the fallback path

**Files:**
- Modify: `src/main.asm` — `do_swap` fallback path (lines 2488-2581), `wrap_byte_x` (`prep_pipe_swap_pending` handling, lines 2431-2441), and any now-unused prep variables.

**Context:** Per the existing handoff note, the `do_swap` fallback path is already dead code (the `prep_phase==7` defer guard prevents reaching it). The freeze (Task 5) keeps that guarantee. Confirm nothing reaches the fallback, then remove it and `prep_pipe_swap_pending`.

- [ ] **Step 1: Audit then delete**

Grep `prep_pipe_swap_pending` and the fallback label. Confirm no live path reaches the fallback (the `wrap_byte_x` `.swap_with_prep` guard at 2414-2416 still gates `do_swap` on `prep_phase==7`). Delete the fallback path, `prep_pipe_swap_pending`, and `.wbx_apply_pending`. Delete any prep variable that grep shows is now unreferenced.

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 3: Human verification**

`make run`, ≥ 60 s, ≥ 15 swaps. Behaviour must be identical to Task 6's result.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "chore: remove dead do_swap fallback path and prep_pipe_swap_pending"
```

### Task 8: Verify the saving and update CLAUDE.md budget notes

**Files:**
- Modify: `CLAUDE.md` — the per-frame T-state targets section.

- [ ] **Step 1: Border-profile the saving**

Ask the human to compare the MAGENTA (PIPE_PROGRAM) border band height before/after — it should be visibly shorter. Each ~3.5k T ≈ ~16 scanlines.

- [ ] **Step 2: Update the budget notes**

Update `CLAUDE.md`'s per-frame targets to reflect the prep-column skip. Note that `PIPE_PROGRAM` now JR-skips the prep column.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update frame budget for prep-column skip"
```

---

## Self-review notes

- **Spec coverage:** §1 JR-skip column → Tasks 1, 4, 6. §2 prep_step re-timed → Task 3 (re-timing chosen over deletion; see plan intro). §3 freeze timing → Task 5. §4 do_swap changes → Task 4. §5 remove plumbing → Task 7. Saving verification → Task 8.
- **Open verification points flagged for the implementer:** (a) whether `prep_step` phases already arm cap slots — Task 4 Step 2 branches on this; (b) exact current resets in `do_swap` step 7 — Task 4 Step 3; (c) where best to clear `activate_pipe_idx` to 255 — Task 5 Step 1. These need confirming against the live code, not assumed.
- **Risk:** Task 4 is the highest-blast-radius change. It is split from the freeze (Task 5) deliberately so each is human-verified alone.
