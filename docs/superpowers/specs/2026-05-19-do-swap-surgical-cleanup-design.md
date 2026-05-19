# do_swap Surgical Cleanup — Design Spec

**Date**: 2026-05-19
**Status**: design approved, awaiting implementation
**Author**: pair-programming with Claude

## Goal

Reduce `do_swap`'s ~16.6 k T-state cost (15.4 k clear loop + 1.2 k ACTIVE_PIPE zero-fill) so the swap-frame budget fits under the 70 k T-state per-frame ceiling, eliminating the recurring "magenta-dominant" 25 Hz blip seen every 28 frames.

Measured swap-frame total before this change: ~82 k T (12 k over budget). After this change: ~69 k T (1 k under budget).

## Background

`do_swap` runs from `wrap_byte_x` when an active pipe scrolls off the left edge (`byte_x=1`). The full-swap path currently does two over-cautious cleanups:

1. **Dep column clear** (~15.4 k T): writes `$00` to all 960 bytes (160 rows × 6 bytes) of the departing pipe's slot column.
2. **`ACTIVE_PIPE_<dep>` zero-fill** (~1.2 k T): writes `$00` to all 224 bytes of dep's sublist via SP-hijack `push hl`.

Both are belt-and-braces safety:

- The dep clear neutralises:
  - Old body slots that would still draw at `byte_x=1` (= visible left-edge ghost pipe).
  - Old cap slots whose `$C3` opcodes would JP to handlers that write to stale targets.
  - The risk of partial-rewrite decoding stray target bytes as opcodes (cap-skip rows were NOPs; partial rewrite turned them into 3-byte JP-to-ROM opcodes — the original ~2 s reset bug).

- The zero-fill protects against the case where prep doesn't reach phase 6 before the dep pipe rotates back to active, leaving `patch_pipe_targets` to decrement stale slot+1 addresses.

Both protections fire on **every** swap, but only a small subset of the work is actually load-bearing.

## Insight

Every row of dep's pre-swap slot column falls into one of three categories, computable from `pipe_state[dep].gap_y` (still valid at do_swap entry):

| Category | Range | Pre-swap content | Real danger | Surgical fix |
|---|---|---|---|---|
| Body rows | `0..cap_top_row-1` + `cap_bot_row+1..159` (~110 rows for typical gap_y) | `$31 lo hi $E5 $D5 $C5` | Body slot draws at OLD byte_x (visible) | Patch bytes 1, 2 to `line_addr[row]+34` (buffer-col target) — slot continues firing, but invisibly |
| Cap rows | exactly `cap_top_row` and `cap_bot_row` | `$C3 hlo hhi $00 $00 $00` | JP to handler with stale target; some handler addresses (e.g. `$8EE7` = RST 20h) reset the CPU when byte 0 is cleared but bytes 1-2 stay | Clear bytes 0, 1, 2 to `$00 $00 $00` — full 3-byte NOP slide guarantees safe decode regardless of handler address |
| Cap-skip rows | `cap_top_row+1..cap_bot_row-1` (PIPE_GAP-1 = 47 rows) | `$00 × 6` | None — already NOPs | Don't touch |

For zero-fill: with `prep_step` running 10 rows/frame, prep always reaches phase 6 in ~20 frames (< 28-frame swap interval), so `ACTIVE_PIPE_<dep>` is always rebuilt before dep next becomes active. Zero-fill is redundant on the full-swap path. Keep it on the fallback path (where `prep_phase < 7` means phase 6 may not have run).

## Architecture

### Step-by-step plan for `do_swap` full-swap path

Replace the current step-5 clear loop and step-6 cap deactivate with **three small loops keyed off `pipe_state[dep].gap_y`**, and move the ACTIVE_PIPE zero-fill into the fallback branch.

```
.ds_full_swap:
    1. Read incoming-pipe index, save to ds_inc.            (unchanged)
    2. Read dep's OLD gap_y from pipe_state[dep*2+1].       (NEW — save in ds_old_gap_y)
    3. Set pipe_state[inc] = (29, prep_gap_y).              (unchanged)
    4. Arm inc's cap_top and cap_bot slots.                 (unchanged — steps 2-3 in current code)
    5. Write cap_*_target and cap_*_next imms for inc.      (unchanged — steps 4-7 in current code)

    -- NEW STEPS (replace current step 5 + 6) --
    6. Patch body rows of dep's column to buffer targets:
         band_1 = rows 0..(old_gap_y - 2)
         band_2 = rows (old_gap_y + PIPE_GAP + 1)..159
         For each row r in band_1 ∪ band_2:
             slot[r][dep] + 1, +2 ← screen_target_table_29[r]   (target.lo, target.hi)
    7. Clear OLD cap rows to NOP slide:
         For r ∈ { old_gap_y - 1, old_gap_y + PIPE_GAP }:
             slot[r][dep] + 0, +1, +2 ← $00, $00, $00
    -- end new steps --

    8. prep_pipe_idx = dep; random_gap_y; prep_phase = 0.   (unchanged — step 7 in current code)
    return
```

### Step-by-step plan for `do_swap` fallback path

```
do_swap (entry):
    Save dep index.
    if prep_phase == 7: branch to .ds_full_swap (above).
    else: fallback path (below).

.ds_fallback:
    -- NEW: zero-fill ACTIVE_PIPE_<dep> moved here from entry --
    1. Zero-fill ACTIVE_PIPE_<dep> (224 bytes via SP-hijack push hl ×112).
    -- end new --
    2. Pick new random gap_y.                               (unchanged)
    3. Clear all 6 bytes of dep's 160 slot rows.            (unchanged — safe full clear since fallback is the rare-edge case)
    4. Set pipe_state[dep] = (29, new gap_y).               (unchanged)
    5. Set prep_pipe_swap_pending = dep + 1.                (unchanged)
    6. Reset prep_phase = 0.                                (unchanged)
    return
```

The zero-fill in fallback covers the case where prep didn't reach phase 6 and dep's sublist might still have stale entries when dep eventually becomes active again.

## Components

### `ds_old_gap_y` — new scratch byte

One additional byte of scratch (alongside `ds_dep`, `ds_inc`, etc.) to hold dep's OLD gap_y across the patch loops. Read once at start of `.ds_full_swap`, used by both the body-row patch and the cap-row clear.

### `.ds_full_swap` body-row patch

Two loops (band 1 and band 2), each:

- Compute `slot[start_row][dep] + 1` as initial HL.
- Compute `screen_target_table_29 + start_row*2` as initial HL' (use alt bank EXX).
- For each row: write target.lo, inc HL, write target.hi, advance HL by `SLOT_ROW_STRIDE - 1` (= 31), advance HL' by 2.
- Loop count from `B = (cap_top_row - 0)` for band 1, `B = (160 - cap_bot_row - 1)` for band 2.

Per-row cost: ~30 T (4 reg moves between EXX banks + 2 writes + HL advance + djnz). 110 rows total ≈ 3.3 k T.

### `.ds_full_swap` cap-row clear

Two single-shot writes (cap_top_row and cap_bot_row):

- Compute `slot[cap_top_row][dep]` as HL.
- Write `$00` to (HL), inc HL, write `$00`, inc HL, write `$00`.
- Repeat for cap_bot_row.

Per cap row: ~50 T. Both ≈ 100 T.

### `.ds_fallback` zero-fill

Move existing SP-hijack zero-fill (REPT 112 push hl) into fallback path. ~1.2 k T per invocation.

## Data flow

```
wrap_byte_x: byte_x=1 detected → call do_swap(A = dep_idx)

do_swap:
    save A → ds_dep
    if (prep_phase == 7):
        .ds_full_swap:
            save pipe_state[dep].gap_y → ds_old_gap_y     (NEW READ)
            arm inc's slots                                (unchanged)
            patch dep body rows                            (NEW: band 1 + band 2)
            clear dep cap rows                             (NEW: 2 specific rows)
            update prep state                              (unchanged)
    else:
        .ds_fallback:
            zero-fill ACTIVE_PIPE_<dep>                    (MOVED here from entry)
            full clear + state update                      (unchanged)
    ret
```

Invariants preserved:
- `pipe_state[dep]` is **read** before any writes that overwrite it; the gap_y read happens at the top of `.ds_full_swap`, well before step 7 overwrites `pipe_state[dep]`.
- `pipe_state[dep].byte_x` was set to 1 by wrap_byte_x's iteration; do_swap leaves it at 1 (becomes the prep pipe's frozen byte_x). Unchanged.

## Error handling

The design's safety hinges on one invariant: `prep_step` reaches phase 6 before any pipe completes a full 28-wrap rotation back to dep's slot. At 10 rows/frame this is guaranteed structurally (~20 frames vs 28-frame interval).

If for some reason a frame is dropped (halt missed) such that prep is delayed and dep flips back to active before phase 6 runs, `patch_pipe_targets` would walk stale entries — exactly the bug the original belt-and-braces zero-fill protected against.

Mitigation:
- Fallback path keeps the zero-fill (covers `prep_phase < 7` at swap time).
- If we ever lower prep rows/frame back to 5, or if frame timing slips below the budget for an extended period, we may need to re-enable zero-fill on the full path. Watch for: stale-entry corruption symptoms (game crash with RST 38h pattern in slot bytes).

The cap-row clear writes 3 bytes (not 1 as in the original step-6). This guarantees safe decode regardless of which pipe's handler address contained dangerous opcodes — `$E7` (RST 20h), `$F7` (RST 30h), `$EF` (RST 28h), `$FF` (RST 38h), `$D9` (EXX), `$32` (LD nn, A 3-byte), etc. Cost is ~40 T extra over the original 1-byte clear; trivial vs the 12 k T saved overall.

## Testing

Acceptance criteria:

1. **Build clean** (`make`, 0 errors, 0 warnings).
2. **Game runs indefinitely past first swap** (= no resets, no infinite hangs).
3. **Pipes render fully** (cap + body) on every active pipe, frame after frame, including the swap frame itself.
4. **Border profile under budget on swap frames**: the magenta region (= PIPE_PROGRAM + frame_update body) should occupy roughly the same proportion of the visible area on swap frames as on non-swap frames. If swap frames still show magenta dominance compared to non-swap frames, the optimisation didn't deliver the expected ~13 k T saving.
5. **No new visual artifacts on the first frame post-swap**: dep's old pipe position should not show pixels. The patched body slots write to buffer cols (invisible). The cleared cap rows execute as 3 NOPs followed by 3 stale bytes; since those stale bytes are also NOPs (cap slot bytes 3-5 were always `$00`), the cap rows execute as 6 NOPs.

Manual test plan:
1. Build: `make`. Expect `Errors: 0, warnings: 0`.
2. Run: `make run`. Play for at least 10 seconds (~5 swaps).
3. Look for cyan blip frames (= halt missed). Should be substantially less frequent than before this change, ideally eliminated.
4. Look for ghost pipes at left edge of screen after a swap. Should not appear.

## Scope

In scope:
- `do_swap` full-swap path refactor (steps 5 + 6 replaced).
- `do_swap` entry zero-fill moved into fallback path.
- One additional scratch byte (`ds_old_gap_y`).

Out of scope:
- `patch_pipe_targets` optimisations.
- PIPE_PROGRAM padding-NOPs replacement (still ~4.5 k T, can be tackled separately).
- Reducing prep_step row-rate.
- 4-pipe spacing changes (architectural, separate spec).

## Self-review

- **Placeholders**: none.
- **Internal consistency**: cap_top_row, cap_bot_row formulas match `(gap_y - 1)` and `(gap_y + PIPE_GAP)` used elsewhere in code. ✓
- **Scope**: focused on do_swap. Fits a single implementation plan. ✓
- **Ambiguity**: "body row" and "cap-skip row" boundaries explicitly stated in the table. The exact rows covered by the band loops are: band 1 = `0..(gap_y - 2)` inclusive (= `gap_y - 1` rows), band 2 = `(gap_y + PIPE_GAP + 1)..159` inclusive (= `111 - gap_y` rows). Total = `gap_y - 1 + 111 - gap_y` = 110 rows. ✓
