# Pre-Baked Slot Templates — Design Spec

**Date:** 2026-05-15
**Status:** Approved (brainstorming → writing-plans)

## Problem

The game now renders three scrolling pipes on a 48K Spectrum at 50 Hz. The slot-grid renderer (`PIPE_PROGRAM` at `$DB00`) handles the per-frame stack-blast in ~16 k T-states, comfortably under the 70 k T-state per-frame budget on **normal** frames.

On **recycle frames** (every ~40 frames, when a pipe's `byte_x` wraps from 1 back to 29 with a fresh random `gap_y`), `configure_pipe_slots` rewrites all 160 slot positions for the recycled pipe — body slots, cap slots, skip slots, cap-handler imms, and active list. Even after the recent band-loop / IY-direct / IX-active optimization, it still costs ~44 k T-states. Combined with PIPE_PROGRAM (~16 k) and the rest of `frame_update` (~6 k), the recycle frame lands at ~66 k T — right on the edge, and observably tips over often enough to produce a perceptible 25 Hz jerk roughly twice per second during play.

We want **butter-smooth scrolling**: every frame fits the 70 k budget, no exceptions.

## Key Insight

`configure_pipe_slots` always runs at `byte_x = 29` (the recycle position) and with `gap_y` drawn from the fixed set `{8, 16, 24, ..., 96}` (12 values from `random_gap_y`). That means there are only **12 distinct slot-grid layouts** in the whole game, and they can all be pre-computed once at boot.

## Design

### Architecture

The per-frame renderer (`PIPE_PROGRAM`) is unchanged. The per-wrap target decrement (`patch_pipe_targets`) is unchanged. Only `configure_pipe_slots` is replaced: instead of computing the slot layout on every recycle, it copies a pre-built template and patches a few pipe-specific values.

### Memory Layout

```
$C000 .. $CF50  TEMPLATE STORE (3.86 KB):
                  body_template:     800 bytes  (shared all-body slot grid for byte_x=29)
                  cap_blocks[12]:    12 × 250 = 3000 bytes (cap_top + 48 skip + cap_bot per gap_y)
                  cap_target_table:  12 × 4   = 48 bytes (pre-computed cap_*_target imms per gap_y)

$D800 .. $DAFF  BACKUP_ATTRS                          (existing, unchanged)
$DB00 .. $E4FF  SLOT GRID (PIPE_PROGRAM)              (existing, unchanged)
$E500 .. $E73F  free
$E740 .. $F43F  SLOT_ADDR_TABLE                       (existing, unchanged)
$F440 .. $FA3F  free
$FA40 .. $FCDF  ACTIVE_PIPE_0..2 sublists             (existing, unchanged)
```

Templates sit in the `$C000..$D7FF` range — the same area freed when the cityscape's `BG_BUFFER` / `CITY_BASE_LUT` were ripped out. `BACKUP_ATTRS` at `$D800..$DAFF` is left untouched.

### Data Structures

#### `body_template` — 800 bytes at `$C000`

A canonical all-body slot column for `byte_x = 29`. Row `R` (0..159) at offset `R*5`:

```
$31, line_table[R].lo + 32, line_table[R].hi, $D5, $C5
```

(`$31 lo hi` is `ld sp, target`; `$D5 $C5` is `push de ; push bc`.)

#### `cap_blocks` — 12 × 250 bytes at `$C320`

A per-gap_y "cap + skip overlay" that covers 50 rows from `gap_y - 1` through `gap_y + 48` inclusive (1 cap_top + 48 skip + 1 cap_bot = 50 rows × 5 bytes = 250 bytes per block).

For `gap_y = G`, the block at row offset `R` (where `R` is 0..49 relative to the block):

```
R == 0       (= cap_top, screen row G-1):
                 $C3, 0, 0, $00, $00     ← handler addr patched at recycle
R in 1..48   (= skip,    screen rows G..G+47):
                 $00, $00, $00, $00, $00
R == 49      (= cap_bot, screen row G+48):
                 $C3, 0, 0, $00, $00     ← handler addr patched at recycle
```

#### `cap_target_table` — 12 × 4 bytes at `$CEE8`

Per gap_y, the cap handler's `target` immediate values, pre-computed:

```
[gap_y] -> word(cap_top_target), word(cap_bot_target)
  cap_top_target = line_table[gap_y - 1] + 32
  cap_bot_target = line_table[gap_y + 48] + 32
```

Used at recycle to patch `cap_top_handler_pipe_<N>_target` and `cap_bot_handler_pipe_<N>_target` without runtime computation.

### Routines

#### `build_slot_templates` — new, called once at boot

Walks `line_table` and the 12 `gap_y` values, fills the template store. Called from `start` BEFORE `init_pipes`.

#### `configure_pipe_slots(A=pipe, E=gap_y, B=0, C=160)` — replaced

```
1. Stamp body_template to pipe's slot column:
   for R in 0..159:
     copy body_template[R*5..R*5+5] -> slot[R][pipe]

2. Stamp cap_block[gap_y/8 - 1] at row offset gap_y-1:
   for R in 0..49:
     copy cap_block[gap_y][R*5..R*5+5] -> slot[gap_y-1+R][pipe]

3. Patch cap_top slot's handler address:
   slot[gap_y-1][pipe] + 1..+2 := cap_top_handler_pipe_<pipe>
   slot[gap_y+48][pipe] + 1..+2 := cap_bot_handler_pipe_<pipe>

4. Patch cap handler target imms from cap_target_table[gap_y]:
   cap_top_handler_pipe_<pipe>_target := cap_target_table[gap_y].cap_top
   cap_bot_handler_pipe_<pipe>_target := cap_target_table[gap_y].cap_bot

5. Patch cap handler _next imms via compute_next_slot:
   cap_top_handler_pipe_<pipe>_next := compute_next_slot(gap_y-1, pipe)
   cap_bot_handler_pipe_<pipe>_next := compute_next_slot(gap_y+48, pipe)

6. Rebuild this pipe's active sublist (ACTIVE_PIPE_<pipe>):
   walk 160 slot positions; for each non-zero slot first byte,
   append slot+1 (if $31 body) or cap_*_target_imm_addrs[pipe] (if $C3 cap)
   to the sublist. Total entries = 112 (110 body + 2 cap).
```

### Cost Estimate per Recycle

| Step | Cost          |
|------|---------------|
| 1. Body stamp         | 160 × ~50 T = ~8000 T |
| 2. Cap overlay        | 50 × ~50 T = ~2500 T |
| 3-5. Cap patches      | ~500 T |
| 6. Active rebuild     | 160 × ~30 T = ~5000 T |
| **Total recycle**     | **~16 000 T** |

**Recycle frame total:** 16 k (recycle) + 16 k (PIPE_PROGRAM) + 6 k (bird/ground/state) = **~38 k T**, well under the 70 k budget. About 50% margin.

Step 6 is actually the costliest single line; an alternative is to pre-bake the active-list layout per gap_y (12 × 112 bytes = ~1.3 KB) and stamp at recycle, reducing it to ~3 k T and bringing total recycle to ~14 k. Defer this micro-optimization unless soak testing shows we need it.

### Boot Sequence

```
start:
  di
  ld sp, $8000
  ld a, 5; out ($fe), a
  call paint_attrs
  call init_background
  call refill_base_attrs
  call backup_base_attrs
  call build_slot_templates          ; NEW
  call init_pipes                    ; uses new configure_pipe_slots
  call init_bird
  call apply_pipe_attrs
  im 1
  ei
  main_loop:
    ...
```

### What Gets Deleted

The current band-loop body of `configure_pipe_slots` (~400 lines including `cps_emit_body`, all the band-1..5 loops, and the post-loop section), plus scratch vars `cps_row_start`, `cps_row_end`, `cps_active_save`.

The `compute_next_slot` helper stays (used in step 5).

## Edge Cases

- **Active list invariant:** Step 6 must produce exactly 112 entries per pipe. If it doesn't, `patch_pipe_targets` walks off into garbage. The pipe-loop counter in step 6 is bounded at 160 rows; the produced entry count is fixed by the gap_y arithmetic and the template's `gap_y`-dependent skip range, so the count is deterministically 112 for all valid `gap_y`.
- **Cap-handler race:** Unlike the split-configure design we tried, recycle now runs to completion on a single frame. The cap handler's `_next` and `_target` imms are patched before the frame returns. The next `PIPE_PROGRAM` call sees a fully consistent slot grid + cap-handler state. The cap-handler race that bit the split design cannot occur here.
- **Init order:** `build_slot_templates` must run before `init_pipes`. Boot sequence above enforces this.
- **gap_y outside table range:** `random_gap_y` is deterministically restricted to multiples of 8 from 8 to 96. The 12-element lookup table covers all valid values. Initial `pipe_state` gap_y values (64, 40, 88) all map to valid entries.

## Testing

Empirical only — Z80 has no unit harness.

1. **Visual smoke:** game runs, pipes render correctly across multiple recycles.
2. **Border-color regression:** the wide RED band on recycle frames is gone. Recycle frame looks like a normal frame.
3. **Score-based soak:** play to score ≥ 200 (~15 recycles). No magenta-freeze, no jerky scrolling.

## Non-Goals

- No new visual features. The visible output is identical to the current renderer; only the recycle-frame *timing* changes.
- No change to per-frame rendering. PIPE_PROGRAM, `patch_pipe_targets`, bird/ground/score code all untouched.
- No further frame-budget optimization beyond fixing the recycle spike. Normal frames are already well under budget.

## Risks

- **Template-store overlap with BACKUP_ATTRS:** Templates start at `$C000`, BACKUP_ATTRS lives at `$D800..$DAFF`. The body_template (800 bytes) + cap_blocks (3000 bytes) + cap_target_table (48 bytes) = 3848 bytes ending at `$CF08`, well before `$D800`. Safe.
- **Active list rebuild correctness:** Step 6 of the new `configure_pipe_slots` is new code. The current `configure_pipe_slots` builds the active list as a side-effect of the band loops. The replacement must produce equivalent entries. Tested empirically via score soak.
- **Initial `init_pipes` behavior:** `init_pipes` currently calls the original `configure_pipe_slots` for each pipe. After this change, it calls the new template-based one, which produces identical slot-grid output for the initial gap_y values. No behavior change at boot.
