# Spec: Fixed-Slot Dispatch — Eliminate the Per-Second Recycle Pause

**Date:** 2026-05-14
**Status:** Design approved, awaiting implementation plan
**Input:** `docs/superpowers/2026-05-14-handoff-recycle-pause.md`
**Supersedes:** Steps 1, 2, 4 in the handoff doc. This spec implements Step 3.

## 1. Problem

The game runs at steady 50Hz on every frame except the once-per-~75-frames recycle frame. On a recycle, `gen_pipe_program` regenerates the entire flat pipe-render program from scratch at a cost of ~95k T-states. The recycle frame total (~140–165k T-states) exceeds the 50Hz budget (69888 T-states) by 2×, producing a visible 1-frame pause every second and a white border band across the visible area.

## 2. Goal

Make the recycle frame fit in 50Hz. Wrap-frame (~68k) and normal-frame (~40k) budgets must remain unchanged. Visual output must remain pixel-identical to the current working baseline.

**Acceptance criteria:**
- Border profiler shows the white band on recycle frames covering less than one scanline (vs. current ~entire visible area).
- Steady 50Hz for 60+ seconds of continuous gameplay (45+ recycles).
- No visual glitches at cap or gap transitions through recycle events.
- No frame skip detectable in Fuse frame-step.
- Builds clean in sjasmplus (zero errors, zero warnings).

## 3. Approach

Replace the regenerate-from-scratch model with a **fixed program structure + SMC role-swap**. `PIPE_PROGRAM` is pre-emitted once at init as a 480-slot grid (160 rows × 3 pipes) in row-major render order. Each slot is one of four templates: **body**, **skip**, **cap_top**, **cap_bot**. On recycle, only the slots that change role are re-templated in place — a localized ~96-row patch instead of a 480-row regen.

Estimated recycle cost: **~12k T-states** (vs. current ~95k). Recycle frame total: 40k normal + 14k wrap + 12k recycle = **66k**. Fits with ~4k margin.

## 4. Memory layout

### 4.1 Slot grid — mixed-size by row band, with per-row EXX

`PIPE_PROGRAM_A` at `$DB00`, 4 KB allocation.

| Element | Size | Layout |
|---|---|---|
| Normal row (rows 0..127) | 16 B | `[EXX 1B][pipe0 5B][pipe1 5B][pipe2 5B]` |
| City row (rows 128..159) | 31 B | `[EXX 1B][pipe0 10B][pipe1 10B][pipe2 10B]` |
| Normal band total | 2048 B | 128 × 16 |
| City band total | 992 B | 32 × 31 |
| Epilogue | ~5 B | `ld sp, (saved_sp); ret` |
| **Grand total** | **~3045 B** | |

**Why the per-row EXX byte:** the current renderer uses **A-pattern body bytes on even rows and B-pattern on odd rows** for row-parity dithering on pipe edges (a load-bearing visual feature — see `pipe_bitmap` vs `pipe_bitmap_b` at main.asm:250 and :265). Implementing this in a fixed grid requires alternating BC/DE between A-values and B-values at each row boundary. A single `exx` instruction (1 byte, 4T) at the start of every row swaps main↔shadow register sets, achieving the alternation with zero per-pipe overhead. `redraw_pipes_v2` sets up main=B, shadow=A at PIPE_PROGRAM entry so the first `exx` at row 0 swaps to main=A for the even row.

Slot addresses are pre-computed at init into `slot_addr_table[160][3]` (960 B at `$F140`, reusing the deprecated `ACTIVE_LIST_B` allocation):
- Normal: `$DB00 + row*16 + 1 + pipe*5`  (the `+1` skips the row's leading EXX byte)
- City: `$DB00 + 2048 + (row-128)*31 + 1 + pipe*10`

**Why mixed normal/city slot sizes:** uniform 5-byte cannot hold the city-band emit (10 bytes minimum: `ld sp, cache; pop bc; pop de; ld sp, screen; push de; push bc`). Uniform 10-byte overflows at 4800 B (allocation is 4096 B). Mixed is the only fit.

**Execution model:** code falls straight through. At each row boundary, the EXX byte fires to swap A↔B; the 3 pipe slots in that row push whichever variant is in the main register set. PIPE_PROGRAM is entered with `call PIPE_PROGRAM` from `redraw_pipes_v2`; the epilogue restores SP and returns.

### 4.2 Slot templates

**Normal band — 5 bytes per pipe slot, plus 1 byte EXX at row start:**

| Element | Bytes | Meaning |
|---|---|---|
| row EXX | `D9` | `exx` — swap main↔shadow register sets (A↔B alternation) |
| body | `31 lo hi D5 C5` | `ld sp, screen_target; push de; push bc` |
| skip | `00 00 00 00 00` | 5 × NOP |
| cap_top | `CD lo hi 00 00` | `call cap_top_handler_pipe_N; nop; nop` |
| cap_bot | `CD lo hi 00 00` | `call cap_bot_handler_pipe_N; nop; nop` |

**City band — 10 bytes per pipe slot, plus 1 byte EXX at row start:**

| Element | Meaning |
|---|---|
| row EXX | `D9` (`exx`) |
| body | `31 lc hc C1 D1 31 ls hs D5 C5` = `ld sp, cache_addr; pop bc; pop de; ld sp, screen_target; push de; push bc` |
| skip | 10 × NOP |
| cap_top | `CD lo hi 00 00 00 00 00 00 00` = `call cap_top_handler_pipe_N; 7 × nop` |
| cap_bot | same shape, `call cap_bot_handler_pipe_N; 7 × nop` |

Only `cap_bot` can land in the city band (requires `gap_y + 48 ≥ 128`, i.e. `gap_y ≥ 80`). City `cap_top` templates exist for symmetry of the slot-write path but are never selected in practice.

### 4.3 Cap handlers — 6 routines (HL-only, A/B agnostic)

Placed in code segment after `init_pipe_program`. ~20 B each. Total ~120 B.

```
cap_top_handler_pipe_0:
    ld (saved_caller_sp), sp     ; 4B, 20T — preserve call's return-address SP
cap_top_handler_pipe_0_target:
    ld sp, $0000                 ; 3B, 10T — SMC imm, patched by patch_pipe_targets each wrap
cap_top_handler_pipe_0_de:
    ld hl, $0000                 ; 3B, 10T — SMC imm, patched by update_cap_imm each frame
    push hl                      ; 1B, 11T — pushes the M2/R cap byte pair
cap_top_handler_pipe_0_bc:
    ld hl, $0000                 ; 3B, 10T — SMC imm, patched by update_cap_imm each frame
    push hl                      ; 1B, 11T — pushes the L/M1 cap byte pair
    ld sp, (saved_caller_sp)     ; 4B, 20T
    ret                          ; 1B, 10T
                                 ; ≈20 B, ≈112T per call
```

**Why HL instead of BC/DE for the cap pushes:** the cap slot may execute in either main=A or main=B state (depending on row parity), but caps themselves have no A/B variant. Using HL keeps BC/DE untouched, so the row's main register set survives the cap call and is correct for subsequent body slots in the same row. This eliminates the need for A/B-paired cap handlers.

**The `ld (saved_caller_sp), sp; ld sp, target ... ld sp, (saved_caller_sp); ret` envelope is load-bearing:** the cap slot enters via `call`, which pushes the return address onto the caller's stack. The inner `ld sp, target` clobbers SP, so without explicit save/restore the `ret` would pop garbage.

City cap_bot handlers (when `cap_bot` lands in rows 128..159) use the same handler shape. The OR-with-cityscape masking for city caps happens at `update_cap_imm` time when computing the cap byte imms — not in the handler. So no separate city cap handlers are needed.

The cap-handler `ld sp, <target>` immediate is registered in `active_list` and decrements on every wrap alongside body slot targets.

### 4.4 Active list — per-pipe sparse sublists

Three contiguous 112-entry sublists at `ACTIVE_LIST_A` (`$FA40`, 720 B, sufficient for 336 × 2 B = 672 B):

```
active_pipe_0:  112 entries (224 bytes)
active_pipe_1:  112 entries (224 bytes)
active_pipe_2:  112 entries (224 bytes)
ACTIVE_COUNT:   336 (constant; pipe count is fixed)
```

Each entry: 2-byte address of a target-imm `lo` byte (either a body slot's target or a cap handler's target). 112 = 160 active rows − 48 gap rows per pipe.

**Why per-pipe (not interleaved by row):** on recycle only the recycled pipe's 112-entry sublist needs rebuilding. Interleaved would force walking every-3rd-entry of the full 336 list. Per-pipe saves ~7k T-states per recycle.

**Why sparse (skip slots not represented):** dense-with-dummies would force `patch_pipe_targets` to walk 480 entries (~20k T-states), pushing the wrap frame past the 50Hz budget. Sparse keeps `patch_pipe_targets` at its current ~14k.

**Why skip-slot bytes can be all-NOP:** skip slots are not in active_list → never patched. NOP bytes stay NOP under any sequence of wraps. The alternative (dense list, patching NOP bytes) corrupts the program after one wrap: decrementing `$00` produces `$FF` (= `rst $38`), which is junk-executable.

## 5. Hot paths

### 5.1 `configure_pipe_slots(pipe, new_gap_y)` — the recycle replacement

Replaces `gen_pipe_program`. Called from the recycle handler with the recycling pipe and its new gap_y.

```
1. Read byte_x from pipe_state[pipe].byte_x
2. Single pass over rows 0..159; for each row r (the row's leading EXX byte
   is NOT rewritten — it stays $D9 throughout the grid's lifetime):
     determine slot type for (r, new_gap_y):
       r == new_gap_y - 1               → cap_top
       r == new_gap_y + 48              → cap_bot
       r in [new_gap_y, new_gap_y + 47] → skip
       otherwise                        → body
     write the 5- or 10-byte template (band-dependent) at slot_addr_table[r][pipe]
     for body templates: target = line_table[r] + (byte_x - 1)*2 + 4
     for cap_top/cap_bot: write template; cap handler target updated in step 3
     advance active_pipe_N cursor:
       skip          → emit nothing
       body          → emit slot_addr + 1
       cap_top/bot   → emit cap handler's target-imm lo byte
3. Recompute cap_top_target_pipe_N and cap_bot_target_pipe_N immediates in the
   pipe's cap handlers (= line_table[cap_row] + (byte_x - 1)*2 + 4).
4. Store new_gap_y to pipe_state[pipe].gap_y
```

The single 0..159 pass fuses the template write and the active-sublist build, eliminating two-pass overhead and any min/max boundary arithmetic. The pass is branch-free per row except for the slot-type dispatch (a small 4-way decoder on `r`'s relation to `new_gap_y`).

**Cost:** 160 rows × ~70T (template byte writes + body target compute + active emit) ≈ **~12k T-states**.

### 5.2 `patch_pipe_targets` — unchanged

Walks all three active sublists back-to-back, SP-hijack pop addresses, decrement lo byte with hi-byte borrow handling. 336 entries × ~42T = ~14k T-states. No structural change required.

The current build's SMC linking inside `patch_pipe_targets` must be confirmed order-independent; the new active_list is in per-pipe slot-address order (sequential within pipe) which differs from current interleaved row-major order.

### 5.3 `update_cap_imm` — simplified

Currently reads `cap_slot_table` (24 B of indirection) and writes cap bytes into PIPE_PROGRAM slots. New version writes directly to 12 fixed addresses (6 cap handlers × 2 imms each: bc and de). The `cap_slot_table` indirection is deleted.

### 5.4 PIPE_PROGRAM execution

Identical shape and count to the current build: 480 slots in row-major order. Body and skip slots execute inline. Cap slots dispatch via `call` to a handler (~140T including `ret`). Net per-frame impact vs. current inline cap rendering: +400T (negligible).

## 6. Initialization

`init_pipe_program`, called once at game start after the existing `init_background` etc.:

1. Build `slot_addr_table[160][3]` using the layout formulas (normal vs city bands).
2. Cap handler routines (6 of them) are assembled at fixed labels in the code segment — no runtime emit needed.
3. Write a `$D9` (EXX) byte at the start of every row in the grid (160 rows = 160 EXX bytes total).
4. For every (row, pipe), write the default body template into the slot with target = `line_table[row] + (initial_byte_x - 1)*2 + 4`.
5. Write epilogue (`ld sp, (saved_sp); ret`) at the end of the slot grid.
6. For each pipe, call `configure_pipe_slots(pipe, initial_gap_y[pipe])` to apply the initial cap/skip configuration. This also builds each pipe's initial active sublist.

## 7. Deletions

The following code becomes dead and is removed:

- `gen_pipe_program` and all sublabels (`.row_lp`, `.emit_a`, `.do_cap`, `.emit_city_body`, `.append_active_slot`, `.full_done`, `.row_limit_smc`).
- Chunked-gen state vars: `gen_chunk_state`, `gen_iy_save`, `gen_row_save`, `wraps_during_gen`.
- Shadow-buffer scaffolding: `shadow_buf_addr`, `shadow_list_addr`, `shadow_count_addr`, `live_list_addr`, `live_count_addr`, `active_set`, `PIPE_PROGRAM_B` EQU, `ACTIVE_LIST_B` EQU, `ACTIVE_COUNT_B` EQU.
- Old `cap_slot_table` and its update logic in `update_cap_imm`.

## 8. Preserved unchanged

- `update_city_cache_fast` — feeds CITY_CACHE consumed by city-band body slots.
- `recompute_city_overlay` — feeds CITY_OVERLAY consumed by `update_city_cache_fast`.
- `CITY_BG_TABLE` and its init.
- Bird, ground, score rendering.
- Frame structure in `frame_update`.
- `wrap_byte_x` and the wrap_pending / pending_regen state machine (still triggers `configure_pipe_slots` on recycle instead of `gen_pipe_program`).

## 9. Risks and mitigations

1. **Cap handler SP save/restore correctness.** The save/restore pair around the inner SP-hijack is mandatory; getting it wrong corrupts the stack and crashes. *Mitigation:* implement one handler first, single-step in Fuse with breakpoints on entry/exit, verify return address survives.

2. **Mixed slot-size address arithmetic.** Off-by-one in the row<128 vs row≥128 split would emit slots into adjacent slots, producing garbage opcodes. *Mitigation:* `slot_addr_table` is pre-computed at init; dump the table to assert correct values at boundaries (row 127 pipe 2, row 128 pipe 0).

3. **City cap_bot rendering.** Triggered when `gap_y ≥ 80`. *Mitigation:* test cases with explicitly forced `gap_y ∈ {80, 100, 111}` to exercise the city cap_bot handler.

4. **Active list order assumptions in `patch_pipe_targets`.** Per-pipe sublists differ from current interleaved order. *Mitigation:* audit current `patch_pipe_targets` for any order-dependent SMC links; the walker should be order-independent on correctness (decrement is commutative), but the current SMC-chained jp z structure may assume something subtle.

5. **Per-row EXX correctness.** The leading EXX byte at every row depends on PIPE_PROGRAM being entered with `main=B, shadow=A`. `redraw_pipes_v2` must be modified to load B into BC/DE last (not A) before calling PIPE_PROGRAM. *Mitigation:* explicit setup in `redraw_pipes_v2`; verify in Fuse by single-stepping row 0 entry and confirming even-row pushes are A-pattern bytes.

6. **Cap handler does not touch BC/DE.** Using HL avoids the A/B parity split for caps. *Mitigation:* enforced by handler shape; no runtime check needed but verify pattern visually that row-parity dithering survives caps.

## 10. Test plan

1. **Build:** sjasmplus reports zero errors and zero warnings.
2. **Boot:** game starts, initial cityscape + 3 pipes appear correctly.
3. **First recycle (~frame 75):** no corruption, smooth pipe scroll. Border profiler shows no white band during the recycle frame.
4. **Sustained gameplay:** 60+ seconds = 45+ recycles; no accumulating drift, no glitch, no frame skip.
5. **Edge `gap_y` cases:** force `gap_y` to extremes (1, 50, 80, 111) and exercise recycles in each band, including city-band cap_bot.
6. **Frame-step in Fuse:** pipes move exactly 1 pixel per `advance_phase` call (2 px/frame) with no 2-pixel jumps anywhere.
7. **Wrap-frame budget:** confirm border profiler shows wrap-frame total within 50Hz (margin should be the same ~2k as today).

## 11. Out of scope

- Step 1 gen optimizations (handoff §"Step 1"). Skipped — would optimize code that this spec deletes.
- Shadow buffer / chunked gen (handoff §"Step 2", §"Step 4"). Superseded by this approach.
- Any change to bird, ground, score, score-attr, or input handling.
- Any frame-cost optimization outside the recycle path.

## 12. Joffa-style alignment

- **Pre-compute everything:** slot_addr_table, body/skip/cap templates as fixed byte sequences, cap handler entry points all resolved at assembly time.
- **No per-line branches at render time:** PIPE_PROGRAM is straight-line code; slot type is encoded as bytes, not as a runtime branch.
- **Sorted cursors, race-the-beam:** existing wrap/render timing preserved.
- **SMC code-gen:** the entire approach is SMC role-swap.
- **Mathematical, not heuristic:** the recycle cost is bounded by row count, not a "good enough" approximation.
- **Visual quality is the spec:** the recycle pause is the failure mode; eliminating it is the contract.
