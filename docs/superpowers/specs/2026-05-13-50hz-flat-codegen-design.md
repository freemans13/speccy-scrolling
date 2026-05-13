# Flat code-gen pipe renderer for silky 50 Hz

**Date:** 2026-05-13
**Goal:** Replace the dispatch-driven `redraw_pipes_linemajor` with a Joffa-style flat code-generated stack-blast renderer that runs every active row in well under one raster line (224 T-states) and total frame budget well under 50 Hz (69888 T-states), with zero tearing by construction.

---

## 1. Problem

Current state:

- Game runs at 25 Hz, jumping to 50 Hz for one or two frames "every second or so" — the brief 50 Hz windows correlate with a pipe momentarily sitting in a buffer column (byte_x in 0..3 or 28..31), which skips that pipe's attr and emit work.
- Visible tearing in the cityscape band, because per-row dispatch overhead spikes past 224 T-states for some rows.

Diagnosis from reading `src/main.asm`:

- `redraw_pipes_linemajor` walks 160 scan lines and, per row, runs the three-pipe emit block. Each pipe has ~6 `cp`/`jr`/`jp` decisions per row to decide skip/body/cap, plus the city-cursor check at row top.
- Per-pipe emit cost ≈ 11 k T-states (per project memory). Three pipes ≈ 33 k T-states/frame on the pipes alone.
- Worst rows in the city band — where the cursor check fires and one or more cell dispatches chain through SMC blocks — exceed 224 T-states, producing scanline-rate tearing in that band.
- Wrap frames add `wrap_byte_x` + `apply_pipe_attrs` + `patch_pipe_smc` sort/link + `restore_trailing_pipe_attrs` on top, pushing total frame past 70 k.

The cause is *dispatch overhead*, not the actual screen writes. The fix is to eliminate dispatch from the inner loop entirely.

## 2. Approach — Joffa-style flat code generation

At wrap time (once per 4 frames), generate a straight-line program in a dedicated buffer (`pipe_program`). The program contains, in scan-line order, exactly the byte writes each line needs and nothing else. Per-frame execution does `call redraw_pipes_v2`, which preloads phase-shifted body bytes into BC/DE/BC'/DE' and then `jp pipe_program`. Each scan line in the program is straight-line stack-blast push code; rows fall through linearly.

This is the same family of technique Joffa Smith used for Cobra and Hyper Sports and that Keith Burkhill used for Firefly: pay generation cost once, then run a branch-free hot loop that the Z80 can stream at near-peak instruction throughput.

## 3. Memory map

Current ($8000–$FFFF):

```
$8000 .. ~$9FFF   code (existing — assembled .asm)
$A000 .. $BFFF    code + tables (existing free area, ~8 KB)
$C000 .. $D7FF    bg_buffer (6 KB)
$D800 .. $DAFF    BACKUP_ATTRS (768 B)
$DB00 .. $FFFF    free (~9.5 KB)
```

New allocations:

```
$DB00 .. $EAFF    pipe_program  (4 KB) — generated code
$EB00 .. $EC7F    city cache (384 B: 32 city rows × 3 pipes × 4 bytes; each slot already resolved per cell)
$EC00 .. $FEFF    free
$FF00 .. $FFFF    stack
```

Buffer size justification: 120 active rows × ~30 bytes/row average = 3.6 KB, plus ~50 bytes header/trailer, plus headroom for worst-case-positioned pipes. 4 KB is comfortable.

## 4. Per-row code templates

All targets below are absolute screen addresses. For a pipe occupying screen columns `[byte_x-1, byte_x, byte_x+1, byte_x+2]` = `[L, M1, M2, R]`, stack-blast writes downward: `push DE` decrements SP by 2 then stores D at (SP+1) and E at (SP); a second `push BC` does the same one word lower. With `BC = M1<<8 | L` and `DE = R<<8 | M2`, setting `SP = line_addr + byte_x + 3` (one byte past R) yields `(line_addr+byte_x+2) = R`, `(line_addr+byte_x+1) = M2`, `(line_addr+byte_x) = M1`, `(line_addr+byte_x-1) = L`. The generator therefore emits `ld sp, line_table[row] + byte_x + 3` for each visible pipe per row.

Register convention inside `pipe_program`:

```
BC  = M1_A << 8 | L_A    (body sky-A, first pair)
DE  = R_A  << 8 | M2_A   (body sky-A, second pair)
BC' = M1_B << 8 | L_B    (body sky-B, first pair)
DE' = R_B  << 8 | M2_B   (body sky-B, second pair)
HL, IX, IY free
```

### 4.1 Empty row

```
; nothing — falls through into next row's first byte
```
Cost: 0 T-states.

### 4.2 Sky body row (even = A variant), N pipes visible

```
ld sp, $imm_p1_target   ; 10T
push de                 ; 11T
push bc                 ; 11T
... repeat per pipe ...
```
Cost: 32T per visible pipe. 3 pipes = 96T. **Well inside the 224T raster budget.**

### 4.3 Sky body row (odd = B variant)

```
exx                     ; 4T   swap to B-variant registers
... same push pattern with BC'/DE' ...
exx                     ; 4T   swap back
```
Cost: 96T + 8T = 104T for 3 pipes.

### 4.4 Cap row (cap A or cap B)

The cap row uses cap-specific byte values, not the body cache, so we embed them as immediates patched by `update_cap_smc`:

```
ld bc, $imm_cap_p1_lo_pair   ; 10T  (M1<<8 | L)
ld de, $imm_cap_p1_hi_pair   ; 10T  (R<<8  | M2)
ld sp, $imm_p1_target        ; 10T
push de                      ; 11T
push bc                      ; 11T
... per cap-visible pipe ...
```
Cost per pipe per cap row: 52T. Caps land on at most 2 rows per pipe × 3 pipes = 6 rows worst case.

### 4.5 City body row (covers rows 128..159 = the city band)

Each of the four pipe cells lives in its own screen column, and each column has its own `cityscape_heights[col]`. On a given city-band row, any subset of the four cells (`{L, M1, M2, R}`) can be in front of a building while the others are still in front of sky. The render template must therefore handle the case where the four bytes pushed to screen are a *heterogeneous mix* of sky-variant and city-variant pipe bytes, and where the L/R OR-with-bg only applies to whichever of {L, R} is actually in front of a building on this row.

The render template doesn't make these decisions at runtime — the **city cache** does, at refresh time (§6.2). The render template just pops 4 pre-resolved bytes for this (row, pipe) and pushes them.

City cache layout: a flat 384-byte buffer at `$EB00`, indexed as `city_cache[(row - CITY_TOP) * 12 + pipe * 4 + cell]` for `row ∈ [128, 159]`, `pipe ∈ [0, 2]`, `cell ∈ {L=0, M1=1, M2=2, R=3}`.

Per-cell value at cache refresh time:

```
col = byte_x_pipe + cell - 1                ; L=byte_x-1, M1=byte_x, M2=byte_x+1, R=byte_x+2
if cityscape_heights[col] >= (CITY_BOTTOM - row):
    if cell == L or cell == R:
        slot = pipe_bitmap_city_X[phase*4 + cell] OR bg_buffer[col][row]
    else:                                    ; M1/M2 — fully-opaque pipe, no edge bits to OR
        slot = pipe_bitmap_city_X[phase*4 + cell]
else:
    slot = pipe_bitmap[phase*4 + cell]       ; this cell is still in front of sky on this row
```

Where `X ∈ {a, b}` is chosen by `row & 1` (even = A variant, odd = B variant) to preserve the existing checker dither.

```
ld sp, $imm_city_p1_rowN_buf ; 10T  SP → 4-byte cache slot for this pipe & row
pop bc                       ; 10T  BC = M1 << 8 | L_OR'd
pop de                       ; 10T  DE = R_OR'd << 8 | M2
ld sp, $imm_p1_target        ; 10T
push de                      ; 11T
push bc                      ; 11T
```
Cost per pipe: 62T. Three pipes: 186T — inside the 224T raster budget. BC/DE are clobbered for the row, which is fine because the next row's entry preamble re-establishes BC/DE for whichever variant (sky-A, sky-B, or another city row) it needs; the variant register set is a *row-scoped* invariant, not a *function-scoped* one.

If the row after a city row is a sky-A or sky-B body row, the generator emits the appropriate variant's BC/DE reload prologue at that row's start (a single `ld bc,nn / ld de,nn` pair = 20T, or `exx` if the previous row left the correct shadow set primed). The bookkeeping is done at generation time, not at runtime.

### 4.6 Function epilogue

```
ret
```

## 5. The generator — two paths

A naive full regenerate of `pipe_program` costs ~80 k T-states (~3.6 KB output × ~22 T/byte for `ld (iy+0),n / inc iy`), which amortized over a 4-frame wrap cycle would consume ~20 k/frame — more than the renderer itself saves. So the design splits regeneration into two paths:

### 5.1 Patch path (common, every wrap)

Between wraps, byte_x changes by exactly ±1 per pipe and gap_y is unchanged. The *structure* of `pipe_program` (which rows emit cap vs body vs city, which rows are empty) is unchanged. Only the `$imm_pX_target` 16-bit immediates need updating because each pipe's screen column moved by 1.

Per pipe, the renderer maintains a `target_table[row]` of 320 bytes (160 rows × 2 bytes) and a `slot_addr_table[row]` of 320 bytes pointing at the `ld sp, nn` immediate in `pipe_program` for that pipe-row (or `$0000` if that pipe is in gap on that row).

`patch_pipe_targets` per wrap:

1. For each pipe (3): walk `target_table` rows 0..159, decrement each by 1 (= byte_x decremented). For active rows, write the new target into the corresponding `pipe_program` slot via `slot_addr_table[row]`.
2. Skip rows where `slot_addr_table[row] == 0` (pipe in gap).

Cost: ~120 active rows × 3 pipes × ~30T = ~11 k T-states per wrap = 2.7 k T-states amortized per frame.

### 5.2 Full regen path (rare, on gap_y change)

A pipe's `gap_y` only changes when it wraps off-screen and is recycled with a new random gap_y. That happens once per pipe-cycle — roughly every 1.5 seconds at the current scroll rate. The full regen is allowed to be expensive (~80 k T) on that single frame because it's amortized over ~75 wrap-frames before the next gap_y change.

To keep the hit invisible, `gen_pipe_program` is *split across two frames*: on frame N (the recycle frame) it builds the first 80 rows; on frame N+1 it builds the remaining 80 rows. While the new program is being built, the old program continues to render — pipe positions don't actually change for the recycling pipe until the new gap_y takes effect (which we sequence to coincide with completion of the regen).

`gen_pipe_program` walks rows 0..159 and, for each pipe, classifies the row as body / cap-top / gap / cap-bottom / off-screen, then emits the corresponding template from §4 and records each emitted `ld sp, nn` immediate's address into `slot_addr_table[row]`. Also rebuilds `target_table[row]` from line_table + byte_x.

### 5.3 Pseudocode

```
gen_pipe_program:                ; full path
    ld iy, pipe_program          ; output cursor
    ld b, 0                      ; row counter
.row_lp:
    ; For each pipe P (1..3):
    ;   classify(row, gap_y_P) → {body, cap_t, cap_b, gap, off}
    ;   if active:
    ;     - emit sky-body / cap / city-body template per §4
    ;     - record IY+offset_of_ld_sp_imm into slot_addr_table_P[row]
    ;     - record target = line_table[row] + byte_x_P + 3 into target_table_P[row]
    ;   else:
    ;     - record slot_addr_table_P[row] = $0000
    inc b
    ld a, b
    cp GROUND_TOP
    jr c, .row_lp
    ld (iy+0), $C9               ; emit RET
    ret

patch_pipe_targets:              ; patch path — called every wrap
    ; For each pipe P (1..3):
    ;   For each row 0..159:
    ;     slot = slot_addr_table_P[row]
    ;     if slot == 0: continue
    ;     target_table_P[row] -= 1     ; byte_x decremented
    ;     (slot) = target_table_P[row].lo
    ;     (slot+1) = target_table_P[row].hi
    ret
```

## 6. Per-phase byte values — what changes when

| Value class           | Source                                 | Patched in           | When            |
|-----------------------|----------------------------------------|----------------------|-----------------|
| Body sky-A 4 bytes    | `pipe_bitmap[phase*4 + 0..3]`          | `redraw_pipes_v2` entry | Every frame (reload BC/DE) |
| Body sky-B 4 bytes    | `pipe_bitmap_b[phase*4 + 0..3]`        | `redraw_pipes_v2` entry | Every frame (reload BC'/DE') |
| Cap A/B 4 bytes each  | `cap_rounded_bitmap[phase*4 + 0..3]`   | `update_cap_imm`     | Every frame (12 immediate patches) |
| City 4 bytes per pipe per city row | Per cell: city-variant bitmap OR bg_buffer (L/R only) if `cityscape_heights[col_cell]` covers row; else sky-variant bitmap. Independent per cell. | `update_city_cache` | Every frame (refresh 384-byte cache at $EB00 — 32 city rows × 3 pipes × 4 bytes) |
| Screen targets        | `line_table[row] + byte_x + 3`         | `patch_pipe_targets` | Every wrap |
| Program structure     | Per-row emit pattern                   | `gen_pipe_program` (split across 2 frames) | Every gap_y change (~1× per 1.5 s per pipe) |

## 7. Integration

Replace inside `frame_update`:

```
call redraw_pipes_linemajor   →   call redraw_pipes_v2
```

Inside `advance_phase`'s `.wrap` branch, after `wrap_byte_x` + `apply_pipe_attrs`:

```
call patch_pipe_targets        ; new — patch screen_target immediates in pipe_program
```

`patch_pipe_smc` is replaced by `patch_pipe_targets` (the SMC bumping in the old paint routines is no longer needed).

`update_smc` and `update_cap_smc` are largely deleted — the old paint routines (`paint_LMMR`, `paint_LMMR_city`, `paint_LMM`, ..., `paint_cap_rounded_*`) become dead code. The SMC patching that fed them is replaced by:

- `update_phase_regs` (called inside `redraw_pipes_v2`): reload body BC/DE/BC'/DE' from `pipe_bitmap[phase*4]` / `pipe_bitmap_b[phase*4]`.
- `update_cap_imm` (kept, slimmed): patch 12 cap immediates.
- `update_city_cache` (new): refresh the 96-byte city L/R OR'd cache.

Bird, ground, score, attrs (`apply_pipe_attrs`, `restore_pipe_attrs`, `paint_city_attrs`, etc.) are unchanged.

Old dispatch SMC machinery (`dispatch_sort`, `patch_block_PXL/PXR`, `smc_cursor_row`, `smc_first_block`, the entire dispatch_back path) is deleted.

## 8. Cycle budget

Sky frame (no wrap):

| Component                          | T-states |
|------------------------------------|----------|
| `redraw_pipes_v2` (entry + jp)     |    ~40   |
| 64 sky-A rows × 96T                |   6144   |
| 64 sky-B rows × 104T               |   6656   |
| 16 city-A rows × 200T (3 pipes)    |   3200   |
| 16 city-B rows × 208T (3 pipes)    |   3328   |
| `update_city_cache` (96 cells/frame, ~50T each) |  ~5000   |
| ~6 cap rows × ~160T                |    960   |
| Bird (restore + draw + attrs)      |  ~4000   |
| Ground                             |  ~1000   |
| Attrs / state                      |  ~2000   |
| **Total**                          | **~32 k** |

Wrap frame: + `wrap_byte_x` + `apply_pipe_attrs` + `patch_pipe_targets` (amortized 3 k) + `restore_trailing_pipe_attrs` ≈ **+7 k → 39 k**.

50 Hz budget: 69 888 T-states. **Headroom: ~30 k T-states.** Plenty for a 4th or 5th pipe, a richer cityscape, parallax, sound effects.

Per-row T-state cost is uniform 96–208T (max 224T raster line budget) → **tearing structurally impossible inside the city band.**

## 9. Testing strategy

This is assembled with sjasmplus and run in Fuse. The verification path:

1. **Build clean.** `make clean && make` produces `build/main.sna`. No assembler errors, no overlap warnings.
2. **Byte-for-byte parity check on a snapshot frame.** Before deleting the old paint routines, build `main.sna` with `redraw_pipes_linemajor` still wired in, run to a known seed (rand_state forced to a fixed value, halt count to 100), Fuse-dump screen ($4000–$57FF) and attributes. Build with `redraw_pipes_v2` wired in instead, repeat, diff. Must be byte-identical. If they differ, the new renderer is wrong before we ship.
3. **Profile border bands.** Use the existing border-color profiling (`out ($fe), a` markers). Verify the BLUE/GREEN/WHITE bands all start within the upper half of the screen and CYAN (idle-after-halt) is at least 30 lines tall. CYAN < 5 lines = budget overrun.
4. **Tear test.** Run for 5 minutes of real time. Visually inspect for any seam in the city band, any cap mid-flicker, any pipe-body partial draw. None permitted.
5. **Cadence test.** Frame counter at known scroll speed should advance at 50/s. Take a 30-second video, frame-count the scroll progression, confirm 1500 ± 5 frames.
6. **Memory safety.** Verify `pipe_program` region ($DB00–$EAFF) does not overlap stack ($FF00 down) under deepest call nest. Verify `gen_pipe_program` does not write past $EAFF in the worst-case layout (gap_y = 8, all 3 pipes maximally drawing).
7. **Wrap regression.** Reset the game several times to randomise pipe layout; verify the full-rebuild generator path produces a working program for every random gap_y combination, not just the initial one.
8. **Variable-height building correctness.** Hand-construct a `cityscape_heights` array containing aggressive height variation (e.g. `[40, 0, 16, 40, 8, 32, 0, 24, …]`) and confirm:
   - Pipes scrolling across abrupt height drops show no flicker, no stale building bytes, no missing pixels on either side of the pipe.
   - A pipe straddling a 4-column span where all four building heights differ shows each cell transitioning into the city band at its own row (not all four together).
   - The bg-buffer OR'd L/R edges on the city side line up pixel-perfectly with adjacent buildings, no halo, no break.
   - Compare a still-frame against a reference screenshot taken from the current (pre-change) renderer with the same height array and the same pipe layout — must be byte-identical in the city band, except for any cell where the old M1/M2-stay-sky shortcut introduced a discrepancy the new design fixes.

## 10. Open questions / decisions deferred to implementation

- **Generator implementation language.** All Z80, no host-side preprocessor: the generator runs on the Speccy, on real metal. Confirmed.
- **City OR cache addressing.** `(city_pX_L_rowN)` slots could be a single flat 96-byte table indexed by `row - CITY_TOP`. Lay out so a pipe's L/R values for a row are contiguous (helps loads in the city template).
- **Cap row register strategy.** Resolved: use `ld bc,nn / ld de,nn` immediates per cap row; patched per phase by `update_cap_imm` (12 patches × 13T = 156T per frame).
- **City-row register clobber.** Resolved: city rows pop fresh BC/DE from the 4-byte cache slot (§4.5), clobbering the body-variant registers; the next body row's prologue reloads BC/DE explicitly. No `exx`/IX juggling required across city↔body row transitions.
- **First active row alignment.** `pipe_program` entry point should be the first row that emits — preceding empty rows can simply not exist in the program, with `redraw_pipes_v2` falling through to it. Saves ~50 T-states of fall-through. Confirm in implementation.
- **What to do with `paint_LMMR` et al.** They become dead code. Remove during the same change to recover the ~1.5 KB they occupy.

## 11. Out of scope

- Bird rendering changes (current is already cheap).
- Ground rendering changes.
- Attribute scroll changes (separate routine; not on the hot path).
- 4-pipe gameplay (becomes feasible after this change; not part of this spec).
- Sound (no current sound; not affected).
- Score render (cheap, only fires on score change).

## 12. Acceptance criteria

- All 5 minutes of test 9.4 show no tearing, no seam, no flicker.
- Frame cadence is exactly 50 Hz sustained for 30 seconds (test 9.5).
- CYAN profile band ≥ 30 lines tall on every frame (test 9.3).
- Byte parity test passes on at least 3 distinct pipe configurations (test 9.2).
- No assembler errors; binary fits within $8000–$FFFF.
