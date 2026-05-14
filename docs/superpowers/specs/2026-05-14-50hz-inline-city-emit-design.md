# 50 Hz inline city emit — eliminate the cache entirely

**Date:** 2026-05-14
**Goal:** Replace the per-frame `update_city_cache` step (~30 k T-states) with inline city-row code generated directly into `PIPE_PROGRAM`, plus a stack of supporting optimizations. Target ≥ 30 k T-states of headroom per frame (≥ 43% margin under the 69,888 T-state 50 Hz budget) so the game runs rock-solid 50 Hz across both normal and wrap frames.

---

## 1. Problem

Current frame budget (after the latest patch + speed-fix work):

| Component | T-states |
|---|---|
| `update_city_cache` | ~30 k |
| `PIPE_PROGRAM` runtime | ~20 k |
| `patch_pipe_targets` (wrap) | ~25 k spike |
| `update_cap_imm` | ~1.5 k |
| bird / ground / score / attrs | ~10 k |
| state prep | ~2 k |
| **Non-wrap frame** | **~64 k** |
| **Wrap frame** | **~89 k** |

50 Hz budget is 69,888 T-states. We squeak under on non-wrap but blow it on wrap frames → effective 25–33 Hz with frame-to-frame stutter. The cache+patch overhead exceeds what the flat code-gen was supposed to save.

## 2. Approach — six interlocking changes

1. **Inline city emit, no cache.** City-row emits in `PIPE_PROGRAM` do the masked-OR work directly at the time of writing each cell to screen. Bake `bg_buffer` addresses as immediates at gen time. Use pipe bytes held in BC/DE (sky-A) and BC'/DE' (sky-B).
2. **Precomputed `(mask & bg)` per (pipe, city-row).** Refreshed once per frame in `update_city_smc`. Emits just read this byte and `or` it with the pipe-byte register.
3. **Cap immediates patched from a tight slot list.** Replace iterator-style `update_cap_imm` with a small flat list of 24 slot addresses and a straight-through loop.
4. **Per-row `exx` (not per-pipe) for sky-B and city-B rows.** One `exx` pair wraps all 3 pipes' emits on an odd row, instead of 3 × per-pipe `exx` pairs.
5. **`patch_pipe_targets` walks an active-list** (only the ~120 active rows), not all 480 (pipes × rows) slots.
6. **Tighter bird path.** Skip `compute_bird_overlap` when the bird hasn't crossed a pipe column this frame.

## 3. Architecture

### 3.1 Per-frame entry (`redraw_pipes_v2`)

```
redraw_pipes_v2:
    ; Load BC = M1_A<<8|L_A, DE = R_A<<8|M2_A from pipe_bitmap[phase*4]
    ; Load BC' / DE' similarly from pipe_bitmap_b[phase*4] (via exx)
    ; Save sky-A bytes to sky_a_L..R scratch (for cap_bot restore)
    ; Save sky-B bytes to sky_b_L..R scratch
    call update_cap_smc
    call update_city_smc       ; refreshes masks + precomputed (mask&bg) table
    ; BC/DE/BC'/DE' still hold sky pipe bytes — no reload needed
    call PIPE_PROGRAM
    ret
```

### 3.2 City emit template (30 bytes, 84 T-states per pipe per row)

For each city-band row's emit per pipe:

```
ld   hl, $target_L           ; baked = line_table[row] + byte_x - 1
ld   a,  ($prec_L_or)        ; baked addr in precomputed_mask_bg_table
or   c                       ; C = current variant's L byte (sky-A or sky-B via exx)
ld   (hl), a                 ; write L cell = pipe_L | (lmask & bg_L)
inc  l
ld   (hl), b                 ; M1 cell = pipe_M1 (no OR — fully inside pipe)
inc  l
ld   (hl), e                 ; M2 cell = pipe_M2
inc  l
ld   a,  ($prec_R_or)
or   d                       ; D = current variant's R byte
ld   (hl), a                 ; write R cell = pipe_R | (rmask & bg_R)
```

T-state breakdown: 10 + 13 + 4 + 7 + 4 + 7 + 4 + 7 + 4 + 13 + 4 + 7 = **84 T-states**.

### 3.3 Sky body emit (unchanged structurally, 32 T-states per pipe per row)

```
ld   sp, $target_R_plus_1    ; baked
push de
push bc
```

### 3.4 Cap row emit (12 bytes, ~50 T-states per pipe per row)

Caps don't OR with bg. They use direct screen writes via HL, baked `target_L` and 4 SMC immediates for the cap bytes:

```
ld   hl, $target_L
ld   (hl), $cap_L_imm        ; 4 SMC slots per cap emit
inc  l
ld   (hl), $cap_M1_imm
inc  l
ld   (hl), $cap_M2_imm
inc  l
ld   (hl), $cap_R_imm
```

12 bytes, 4 × (10T `ld (hl),n` + 4T `inc l`) = ~56 T-states.

Caps don't clobber BC/DE → no restore needed. This is a simplification over the previous design that used `ld bc,nn ; ld de,nn ; ld sp ; push ; push` and required restores.

### 3.5 Per-row `exx` wrapping

For odd-parity rows that contain at least one pipe in sky-body or city-body, the generator emits ONE `exx` at the row start and ONE at the row end, wrapping all 3 pipes' inline emits. For even-parity rows: no `exx`.

This requires the city emit and sky-body emit to use the same register pair semantics (B=M1, C=L, D=R, E=M2 for the current variant) — which they do.

Cap rows always emit between the row's `exx` pair if odd-parity, but don't use BC/DE so they're transparent to the wrap.

### 3.6 `update_city_smc` and the city precomputed table

The precomputed table is one packed buffer at `city_table` ($EF00). Each city emit slot occupies **6 bytes**:

```
offset 0:  precomp_L_or         ; written by update_city_smc, read by emit
offset 1:  precomp_R_or         ; written by update_city_smc, read by emit
offset 2:  bg_L_addr lo          ; baked at gen time
offset 3:  bg_L_addr hi
offset 4:  bg_R_addr lo
offset 5:  bg_R_addr hi
```

96 emits × 6 = 576 bytes. The emit's SMC immediate `ld a, ($prec_L_or)` is baked at gen time to point at `city_table + emit_idx * 6 + 0`; `$prec_R_or` is `+ 1`.

```
update_city_smc:
    ; Refresh sky scratch (8 bytes) and masks (2 bytes) — ~250 T-states
    ld   a, (phase)
    add  a, a
    add  a, a                          ; phase*4 in A
    ; ld de, sky_a_L ; ld hl, pipe_bitmap + (a as offset) ; ldi×4
    ; ld de, sky_b_L ; ld hl, pipe_bitmap_b + (a as offset) ; ldi×4
    ; load l_out_masks[phase] → lmask, r_out_masks[phase] → rmask

    ; Refresh the 96 precomputed (mask&bg) values
    ld   ix, city_table
    ld   b, 96
.lp:
    ld   l, (ix+2)
    ld   h, (ix+3)         ; HL = bg_L_addr
    ld   a, (hl)           ; bg_L byte
    ld   c, a
    ld   a, (lmask)
    and  c
    ld   (ix+0), a         ; precomp_L_or
    ld   l, (ix+4)
    ld   h, (ix+5)         ; HL = bg_R_addr
    ld   a, (hl)
    ld   c, a
    ld   a, (rmask)
    and  c
    ld   (ix+1), a         ; precomp_R_or
    ld   de, 6
    add  ix, de
    djnz .lp
    ret
```

Cost per entry: ~70 T-states. 96 × 70 + 250 (scratch) ≈ **~7 k T-states per frame**.

### 3.7 `update_cap_smc`

A tight loop over a 24-byte `cap_slot_list` (6 cap rows × 4 immediate addresses each). For each pipe-cap-row, the 4 cap-bitmap bytes are written to the slot addresses. The cap_bitmap bytes are pre-loaded into 4 registers/scratch slots at function entry to amortize the read.

Cost: ~1 k T-states per frame.

### 3.8 `patch_pipe_targets` (active-list)

```
patch_pipe_targets:
    ld   hl, active_list
    ld   b, (active_count)             ; max 144
.lp:
    ld   e, (hl) ; inc hl
    ld   d, (hl) ; inc hl
    ; DE = slot addr in pipe_program
    ld   a, (de)  ; sub 1  ; ld (de), a
    inc  de
    ld   a, (de)  ; sbc a, 0  ; ld (de), a
    djnz .lp
    ret
```

Per active entry: ~50 T-states. ~140 entries → ~7 k T-states.

`active_count` and `active_list` are populated by `gen_pipe_program` during the row walk: every time it emits a sky-body / cap / city emit, append the `ld sp,nn` or `ld hl,nn` immediate's address to `active_list`.

### 3.9 Bird path: skip `compute_bird_overlap` when not needed

`compute_bird_overlap` scans 3 pipes × 16 bird lines to detect overlap. It's only useful if at least one pipe's column range intersects col 8/9 (bird's column).

Track a flag `bird_overlap_needed` set by `wrap_byte_x` whenever any pipe's `byte_x` enters the [4, 11] range. Reset after one frame post-overlap. When clear, `restore_bird_bg` skips the overlap compute and just LDIR-style restores the 16 lines from `bg_buffer`. Save ~2 k T-states most frames.

## 4. Memory map

```
$DB00 .. $EEFF (5 KB)   pipe_program  (city emit is denser; ~4.5 KB usage)
$EF00 .. $F13F (576 B)  city_table (96 entries × 6 bytes: precomp + bg addrs)
$F140 .. $F15F (32 B)   sky scratch (sky_a_L..R, sky_b_L..R, lmask, rmask, cap_L_temp..R)
$F160 .. $F17F (32 B)   cap_slot_list (24 bytes + count + padding)
$F180 .. $F29F (288 B)  active_list (max 144 entries × 2 bytes)
$F2A0 .. $F2A1 (2 B)    active_count
$F2A2 .. $FEFF (~3.4 K) free
```

Removed: `city_cache` (was 384 B), `target_table` (960 B), `slot_addr_table` (960 B), `colcells_table`/`heights_table`/`pipe_hoist_data` (was ~24 B), `sky_row` (4 B). Net reclaim: **~2.3 KB**.

## 5. Cycle budget

| Component | T-states (non-wrap) | T-states (wrap) |
|---|---|---|
| `redraw_pipes_v2` entry (load regs + sky scratch) | ~200 | ~200 |
| `update_cap_smc` | ~1 k | ~1 k |
| `update_city_smc` (incl. precomputed table) | ~7 k | ~7 k |
| `PIPE_PROGRAM` runtime | ~22 k | ~22 k |
|   sky body emits | (~14 k) | (~14 k) |
|   city body emits | (~8 k) | (~8 k) |
|   cap emits | (~0.3 k) | (~0.3 k) |
| `patch_pipe_targets` | 0 | ~7 k |
| `restore_bird_bg` (most frames skip compute_bird_overlap) | ~3 k | ~3 k |
| `draw_bird` | ~1 k | ~1 k |
| `restore_bird_attrs` + `paint_bird_attrs` | ~2 k | ~2 k |
| `draw_ground` | ~1 k | ~1 k |
| `update_score` / `render_score` | ~0.5 k | ~0.5 k |
| `apply_pipe_attrs` (wrap only) | 0 | ~3 k |
| state prep | ~1 k | ~1 k |
| **Total** | **~38 k** | **~49 k** |

50 Hz budget = 69,888 T-states.
**Headroom: ~32 k (non-wrap) / ~21 k (wrap)** — i.e. 45% / 30% margin. Comfortable.

## 6. Gen-time work

`gen_pipe_program` runs once per recycle (~1.5 s avg). It does:

1. Zero `active_count` and `cap_slot_list`.
2. Walk rows 0..159.
3. For each row, decide for each pipe: skip / sky-body / cap / city-body / off.
4. Emit per-row `exx` start if any pipe needs sky-B or city-B on this row and row-parity is odd.
5. Emit each pipe's selected template, with the right baked addresses:
   - Sky body: target = `line_table[row] + byte_x + 3`.
   - Cap: `target_L = line_table[row] + byte_x - 1`. Append 4 slot addresses to `cap_slot_list`.
   - City body: `target_L`, `bg_L_addr = (line_table[row] | $8000) + (byte_x-1)`, `bg_R_addr = (line_table[row] | $8000) + (byte_x+2)`, `prec_L_or_addr = precomputed_mask_bg_table + emit_index*2 + 0`, `prec_R_or_addr` = ... + 1. Append (precomp_L_addr, precomp_R_addr, bg_L_addr, bg_R_addr) to `city_emit_list` for `update_city_smc` to walk.
6. Append the emit's "target slot" (`ld sp,nn` or `ld hl,nn` immediate) address to `active_list`.
7. Emit per-row `exx` end if started.
8. Emit prologue (`ld (saved_sp), sp`) at start of program and epilogue (`ld sp, (saved_sp) ; ret`) at end.

Gen total cost: ~30 k T-states. Triggered on recycle (deferred via `pending_regen`).

## 7. Migration / cleanup

After the new architecture is verified, remove (in commit-size chunks for easy bisection):

1. `update_city_cache` and its scratch variables.
2. `city_cache` memory region.
3. `update_cap_imm` (replaced by `update_cap_smc`).
4. `target_table`, `slot_addr_table`, `pipe_target_base`, `pipe_slot_base` (replaced by `active_list`).
5. Old `paint_LMMR` family and `paint_cap_rounded_*` family (dead since Task 8).
6. `redraw_pipes_linemajor` and `dispatch_sort` / `patch_block_*` machinery (dead since Task 8).

Net memory recovery: ~2.3 KB scratch + ~1.5 KB code.

## 8. Testing

1. **Build clean** — `make clean && make` produces zero errors.
2. **Visual correctness** — pipes render identical to current verified state: no skyscraper-in-pipe, clean cap pixels, no row-aliasing, no body-mismatch artifacts.
3. **Speed** — RED border occupies the top ~5–7 character rows only; CYAN dominates the bottom border (≥ 6 char rows of idle time) consistently across every frame, including wrap frames.
4. **Cadence** — frame counter over 30 s shows 1500 ± 5 frames.
5. **Tear test** — 5 min play: no horizontal seams, no cap flicker, no pipe partial-draw.
6. **Variable-height building correctness** — patch `cityscape_heights` with aggressive variation; pipes scrolling across abrupt height drops show pixel-perfect edges.

## 9. Risks

- **Gen complexity grows.** Inline city emit + active_list + per-row exx + per-emit precomputed addresses all increase `gen_pipe_program` complexity. Mitigation: thoroughly self-review the gen routine after writing; keep it well-commented.
- **`bird_overlap_needed` heuristic correctness.** If the flag falsely says "skip" when a pipe IS overlapping, the bird would stamp over a pipe pixel. Mitigation: err on the side of including the overlap compute (mark flag set whenever any pipe's `byte_x` is in [4, 13] — wider than strict overlap range).
- **`pipe_program` buffer size.** Inline city emit grows it to ~4.5 KB. Within the 5 KB allocation but tight. If recycle generates a worst-case layout that exceeds 5 KB, gen would scribble into `precomputed_mask_bg_table`. Mitigation: in `gen_pipe_program`, sanity-assert that the output cursor never exceeds the buffer end.

## 10. Out of scope

- Caps in city band city-aware rendering (caps overwrite cityscape pixels at their row; not perfect but not currently flagged as a problem).
- Sound effects.
- 4th pipe (architecture supports it once 3-pipe at 50 Hz is solid; not requested).

## 11. Acceptance criteria

- All 6 tests in §8 pass.
- CYAN idle band ≥ 6 char rows tall consistently.
- Game runs 50 Hz over a 5-minute play session with no perceived stutter.
- Code is clean, with the old dead routines (§7) removed.
