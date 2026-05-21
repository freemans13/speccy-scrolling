# Skip the prep-pipe column in PIPE_PROGRAM — design

**Date:** 2026-05-21
**Status:** design, pending plan
**Estimated saving:** ~3,526 T/frame, steady (every frame). ≈ 5% of the 70k budget.

## Problem

`PIPE_PROGRAM` (the SMC slot grid at `$DB00`) executes **all 4 pipe slot
columns on every one of its 160 rows, every frame**. One of those 4 columns
always belongs to the **prep pipe** — the pipe being prepared off-screen,
indexed by `prep_pipe_idx`. The prep pipe sits at `byte_x=29` (the invisible
right buffer column), so its slot column paints pipe pixels into memory the
player never sees.

Per frame, the prep column costs roughly:

| Rows | Slot type | Cost |
|---|---|---|
| ~110 body | `ld sp,nn ; push hl ; push de ; push bc` | 110 × 43 T = 4,730 T |
| 48 cap-skip | `JR +4` (already cheap) | 48 × 12 T = 576 T |
| 2 cap | `JP cap_handler` + handler | ~160 T |
| **Total** | | **~5,466 T/frame** |

This is pure waste — invisible output.

## Goal

Make the prep column cost ~1,920 T/frame (160 rows × 12 T `JR +4`) instead of
~5,466 T. Net steady saving **~3,526 T/frame**. No visual change.

## Why the obvious "just skip it" doesn't work

A slot is exactly **6 bytes** (`$31 lo hi $E5 $D5 $C5`). A `JR +4` skip needs
only 2 bytes, but there is no room to store *both* a skip jump *and* the real
slot content. So a JR-skipped column holds **no real slot data**. That forces
the rest of this design: the real slot build must happen at a different time.

The current architecture builds the prep column's real slots *during* the
~37-frame prep window via `prep_step` (7 phases, `ps_phase0..6`). If the column
is JR-skipped, `prep_step` has nothing to build. The real build must move to
*after* the pipe activates.

## Design

### 1. The prep column is always JR-skip

Every slot in the column named by `prep_pipe_idx` holds the 6-byte pattern
`$18 $04 $00 $00 $00 $00` (`JR +4` then 4 dead bytes). PIPE_PROGRAM steps the
slot in 12 T.

Exactly one column is the prep column at any time (the 4-pipe invariant), so
the saving is steady on every frame. During the ~8-frame post-swap window a
second column is also partly JR-skip (see §3), which saves slightly more.

The JR-skip mechanism is per-slot, so it handles 0, 1, or 2 skipped columns
uniformly — no dependence on *which* physical column is prep.

### 2. `prep_step` is deleted; `activate_step` replaces it

Because `do_swap` rewrites the departing column to JR-skip (§4), the prep
column is **already entirely JR-skip for the whole prep window** — there is
nothing for `prep_step` to do. Delete `prep_step` and its 7 phase routines
(`ps_phase0..6`, `ps_slot_addr_for_row`, the `prep_phase`/`prep_row` state).

Add `activate_step`: an amortised slot builder triggered by `do_swap`. It
rebuilds the **newly-activated** pipe's column from JR-skips into real
body+cap slots over ~8 frames (~20 rows/frame, ~1.5k T/frame). It is
`configure_pipe_slots` chunked — it reuses `screen_target_table_29` for body
targets (`byte_x=29`) and the `gap_y` chosen by `do_swap` for cap placement.

`activate_step` runs from `main_loop` in the slot currently occupied by
`prep_step` (the YELLOW profile region).

### 3. Activation timing — freeze at byte_x=29

When `do_swap` activates the prepared pipe, the pipe is **frozen at
`byte_x=29`** — not scrolled by `patch_pipe_targets`, not in the active walk —
until `activate_step` finishes building its column. Only then does the pipe
join the scroll.

This guarantees:
- The column is fully real before the pipe can become visible (`byte_x≤27`).
- `activate_step` builds against a fixed `byte_x=29`, so it can use
  `screen_target_table_29` directly with no moving-target arithmetic.
- `patch_pipe_targets` never walks a half-built column (the pipe is excluded
  from the active set until `activate_step` completes).

Cost: the pipe enters from the right edge ~8 frames later than today. It is
invisible the whole time, so there is no visible difference.

The existing "defer until ready" gate in `wrap_byte_x` (the `prep_phase==7`
guard) is repurposed: gate the pipe's entry into the scroll on
`activate_phase == DONE` instead.

### 4. `do_swap` changes

- **Departing column** (was an active pipe, hit `byte_x=1`): `do_swap` step 5
  already rewrites all 160 of this column's slots. Change it to write the
  constant JR-skip pattern (`$18 $04 $00 $00 $00 $00`) instead of retargeted
  body slots. The constant pattern is stack-blastable — same cost or cheaper
  than the current step 5. This column becomes the new prep column;
  `prep_pipe_idx` points at it (unchanged from today).
- **Incoming column** (was prep, all JR-skip): `do_swap` triggers
  `activate_step` (`activate_phase = 0`, `activate_row = 0`). It does **not**
  build slots itself — `do_swap` stays cheap, no 160-slot spike added to the
  swap frame.
- `do_swap` still picks the new `gap_y`; `activate_step` consumes it.

### 5. Remove the prep state plumbing

`prep_phase`, `prep_row`, `prep_gap_y` and the `prep_step` call site go away.
`prep_pipe_idx` stays — it still names the JR-skip column and is still skipped
by `patch_pipe_targets`, `apply_pipe_attrs`, etc. Add `activate_phase`,
`activate_row`, `activate_gap_y`.

The `do_swap_fired` / `skip_prep_step` interaction in `main_loop` is
re-pointed: skip `activate_step` on the swap frame itself (the same one-frame
deferral that exists for `prep_step` today).

## Net effect

| | Change |
|---|---|
| Steady | −3,526 T/frame |
| 8 frames after each swap (~1 swap / 37 frames) | `activate_step` adds ~1.5k T/frame — still a net win on those frames |
| Swap frame | `do_swap` step 5 unchanged in size or slightly cheaper (constant pattern) |
| Code size | `prep_step` + 7 phases deleted; one simpler `activate_step` added — net smaller |

## Risks and known pitfalls

- **`activate_step` must finish within ~8 frames.** 160 rows / 8 frames =
  20 rows/frame. The freeze-at-29 + `activate_phase==DONE` gate is the safety
  net: if the build is somehow late, the pipe simply stays frozen one more
  wrap rather than appearing half-built.
- **`do_swap` partial-rewrite trap** (memory: `do_swap_partial_rewrite_bug`):
  all 6 bytes of every slot in the departing column must be written — leaving
  stale bytes turns cap-skip rows into JP-to-ROM opcodes. Writing the full
  6-byte JR-skip pattern satisfies this.
- **`ACTIVE_PIPE_<n>` stale entries** (memory: `active_pipe_stale_entries`):
  the activated pipe's `ACTIVE_PIPE` sublist must be populated by
  `activate_step` as it builds real slots, and must not be walked by
  `patch_pipe_targets` until the build is complete.
- **EXX/djnz bank confusion** (memory: `exx_djnz_bank_bug`): any new loop in
  `activate_step` that uses EXX must keep an even EXX count between `ld b,n`
  and `djnz`.
- **Blast radius:** `do_swap`, `wrap_byte_x`, `main_loop`, `update_cap_imm_v2`,
  and `init_pipes` all reference prep state. Each must be re-pointed at the
  new lifecycle. This is the main implementation risk — it is a lifecycle
  change, not a local edit.

## Out of scope

- The textured-pipe attribute rearchitecture ("A") — degrades the visual.
- Pre-baked patch-target LUTs ("D") — slower than the in-place decrement.
- Two-line body rows ("C") — saves only ~1.1k, not worth the grid restructure.

These were evaluated and rejected; see conversation history. This spec is the
single confirmed visual-neutral win.
