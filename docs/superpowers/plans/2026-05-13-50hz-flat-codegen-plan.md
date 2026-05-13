# 50 Hz Flat Code-Gen Pipe Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `redraw_pipes_linemajor` and its dispatch machinery in `src/main.asm` with a Joffa-style flat code-generated stack-blast renderer that runs all active rows in under one raster line and the whole frame in well under 50 Hz budget.

**Architecture:** A pre-generated straight-line program at `$DB00` emits exactly the screen writes each scan line needs and nothing else. A 384-byte city cache at `$EB00` holds per-cell-resolved pipe bytes for the city band (handles varying building heights per cell independently). Two regen paths: a cheap per-wrap target patch and a rarer full structural rebuild on `gap_y` change.

**Tech Stack:** sjasmplus (Z80 assembler), Fuse (ZX Spectrum emulator), single source file `src/main.asm`. No automated test framework — verification is by build success, Fuse memory inspection, byte-for-byte screen parity against the existing renderer, and visual cadence/tear inspection.

**Source spec:** `docs/superpowers/specs/2026-05-13-50hz-flat-codegen-design.md`

---

## File Structure

All code lives in `src/main.asm`. The plan adds new labels/routines, modifies a few existing call sites, and (in the last tasks) deletes obsolete code. No new source files.

Memory regions touched (per spec §3):

| Region            | Address       | Size   | Purpose                                                          |
|-------------------|---------------|--------|------------------------------------------------------------------|
| `pipe_program`    | $DB00–$EAFF   | 4 KB   | Generated straight-line render program                           |
| `city_cache`      | $EB00–$EC7F   | 384 B  | 32 city rows × 3 pipes × 4 pre-resolved bytes                    |
| `target_table`    | $EC80–$EE3F   | 960 B  | 3 pipes × 320 B (160 rows × 2 B) — current screen target per row |
| `slot_addr_table` | $EE40–$EFFF   | 960 B  | 3 pipes × 320 B — `pipe_program` immediate-slot addr per row     |

(All addresses are below the $FF00 stack and above the existing bg_buffer/BACKUP_ATTRS at $C000–$DAFF, so no collision.)

Routines added:
- `redraw_pipes_v2` — per-frame entry: preload BC/DE/BC'/DE'; `jp pipe_program`.
- `update_phase_regs` — write phase-shifted sky-A/B body bytes into BC/DE/BC'/DE' source slots (inlined into `redraw_pipes_v2`).
- `update_cap_imm` — patch the 12 cap-row `ld bc,nn / ld de,nn` immediates from `cap_rounded_bitmap[phase*4]`.
- `update_city_cache` — fill the 384-byte cache from pipe_state, cityscape_heights, bg_buffer, and the current phase's bitmaps.
- `patch_pipe_targets` — per-wrap: walk `target_table`, decrement each entry, write through to the corresponding `pipe_program` immediate via `slot_addr_table`.
- `gen_pipe_program` — full regenerate: walk rows 0..159, classify each pipe per row, emit the appropriate row template, record slot addresses and targets.

Routines deleted at the end:
- `paint_LMMR`, `paint_LMMR_city`, `paint_LMM`, `paint_LMM_city`, `paint_LM`, `paint_LM_city`, `paint_L`, `paint_L_city`, `paint_MMR`, `paint_MMR_city`, `paint_MR`, `paint_MR_city`, `paint_R`, `paint_R_city`.
- `paint_cap_rounded_LMMR`, `paint_cap_rounded_LMMR_city`, `paint_cap_rounded_LMM`, `paint_cap_rounded_LMM_city`, `paint_cap_rounded_LM`, `paint_cap_rounded_LM_city`, `paint_cap_rounded_L`, `paint_cap_rounded_L_city`, `paint_cap_rounded_MMR`, `paint_cap_rounded_MMR_city`, `paint_cap_rounded_MR`, `paint_cap_rounded_MR_city`, `paint_cap_rounded_R`, `paint_cap_rounded_R_city`.
- `redraw_pipes_linemajor` (the whole body).
- `dispatch_sort`, `dispatch_sort_sentinel`, `dispatch_first_row_init`, `dispatch_first_block_init`, `dispatch_sort_swapped`, `dispatch_sentinel_block`, `patch_block_P1L`, `patch_block_P1R`, `patch_block_P2L`, `patch_block_P2R`, `patch_block_P3L`, `patch_block_P3R`.
- `update_smc`, `update_cap_smc`, `patch_pipe_smc` (replaced by the new per-frame entry path).
- Caches `city_aL_cache`, `city_aR_cache`, `city_bL_cache`, `city_bR_cache`, `city_cL_cache`, `city_cR_cache`.

---

## Task 0: Initialize git for incremental commits

The project is not currently a git repo. Initialize one so each task can commit and we can diff/roll back individual steps.

**Files:**
- Create: `.gitignore`
- Initialize: `.git/`

- [ ] **Step 1: Initialize git repo**

```bash
cd /Users/freemans/github/freemans13/speccy-scrolling
git init
```

Expected: `Initialized empty Git repository in .../speccy-scrolling/.git/`

- [ ] **Step 2: Add a `.gitignore`**

Create `/Users/freemans/github/freemans13/speccy-scrolling/.gitignore`:

```
build/
tools/sjasmplus/build/
*.sym
*.lst
.DS_Store
```

- [ ] **Step 3: Initial commit of pre-change state**

```bash
git add .gitignore src/main.asm Makefile docs/
git commit -m "snapshot: pre-50Hz-flat-codegen baseline"
```

Expected: commit succeeds. `git log --oneline` shows one commit.

- [ ] **Step 4: Confirm build still works from baseline**

```bash
make clean && make
```

Expected: assembles without error. `build/main.sna` exists.

---

## Task 1: Reserve memory regions and add EQUs

Add the new memory map constants and `ds` reservations at the top of the data area of `main.asm`. Nothing is wired up yet — this just stakes out the addresses.

**Files:**
- Modify: `src/main.asm` (top constants + new buffer reservations near the existing `pipe_state` block around line 141)

- [ ] **Step 1: Add address EQUs near the top constants**

In `src/main.asm`, find the block ending at line 40 (`CITY_BOTTOM EQU 160`) and add immediately after:

```
PIPE_PROGRAM        EQU $DB00       ; generated render program (4 KB)
PIPE_PROGRAM_END    EQU $EB00
CITY_CACHE          EQU $EB00       ; 32 rows × 3 pipes × 4 bytes = 384 B
CITY_CACHE_END      EQU $EC80
TARGET_TABLE        EQU $EC80       ; 3 pipes × 320 B
TARGET_TABLE_END    EQU $EE40
SLOT_ADDR_TABLE     EQU $EE40       ; 3 pipes × 320 B
SLOT_ADDR_TABLE_END EQU $F000
```

- [ ] **Step 2: Assemble to confirm no syntax errors**

```bash
make clean && make
```

Expected: PASS — `build/main.sna` produced, no assembler errors.

- [ ] **Step 3: Commit**

```bash
git add src/main.asm
git commit -m "add memory map constants for pipe_program, city_cache, target/slot tables"
```

---

## Task 2: Add `redraw_pipes_v2` entry stub and `update_phase_regs`

Add the new per-frame entry point. It loads BC/DE with sky-A pre-shifted bytes, BC'/DE' with sky-B, then `jp PIPE_PROGRAM`. Not yet called from anywhere — just present in the binary.

**Files:**
- Modify: `src/main.asm` (insert before `redraw_pipes_linemajor` near line 1329)

- [ ] **Step 1: Write the routine**

Add immediately before `redraw_pipes_linemajor`:

```
;----------------------------------------------------------------
; redraw_pipes_v2: per-frame entry into the flat code-gen renderer.
; Loads BC/DE with sky-A pre-shifted body bytes, BC'/DE' with sky-B,
; then jumps to the generated program at PIPE_PROGRAM.
;
; Register convention inside PIPE_PROGRAM:
;   BC  = M1_A << 8 | L_A      (body sky-A pair 1)
;   DE  = R_A  << 8 | M2_A     (body sky-A pair 2)
;   BC' = M1_B << 8 | L_B      (body sky-B pair 1)
;   DE' = R_B  << 8 | M2_B     (body sky-B pair 2)
;----------------------------------------------------------------
redraw_pipes_v2:
        ld      (saved_sp), sp
        ; --- Sky-A pair into BC/DE ---
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap
        add     hl, bc                  ; HL → pipe_bitmap[phase*4]
        ld      c, (hl)                 ; C = L_A
        inc     hl
        ld      b, (hl)                 ; B = M1_A   →  BC = M1<<8 | L
        inc     hl
        ld      e, (hl)                 ; E = M2_A
        inc     hl
        ld      d, (hl)                 ; D = R_A    →  DE = R<<8 | M2
        ; --- Sky-B pair into BC'/DE' ---
        exx
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap_b
        add     hl, bc
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        inc     hl
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        exx
        ; --- Call generated program ---
        call    PIPE_PROGRAM            ; program ends with RET
        ld      sp, (saved_sp)
        ret
```

- [ ] **Step 2: Assemble to confirm**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 3: Verify the routine is present in the symbol table**

```bash
grep redraw_pipes_v2 build/main.sym
```

Expected: a line showing `redraw_pipes_v2` at an address inside $8000–$BFFF.

- [ ] **Step 4: Seed PIPE_PROGRAM with a RET so the call doesn't crash if invoked early**

Add a temporary seed routine after `redraw_pipes_v2`. This is removed in Task 5 when `gen_pipe_program` arrives.

```
seed_pipe_program_with_ret:
        ld      a, $C9                  ; RET
        ld      (PIPE_PROGRAM), a
        ret
```

And call it from `start:` immediately after `im 1`, before `ei`. Find around line 56–57:

```
        im      1
        call    seed_pipe_program_with_ret      ; TEMP — replaced by gen_pipe_program later
        ei
```

- [ ] **Step 5: Assemble and verify still builds**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "add redraw_pipes_v2 entry stub + temporary RET seed at PIPE_PROGRAM"
```

---

## Task 3: Implement `update_city_cache`

Fill the 384-byte cache at `$EB00`. Per (city-row, pipe, cell), compute the right byte based on whether that cell's column has cityscape covering that row.

**Files:**
- Modify: `src/main.asm` (add new routine; place it near the bottom data area, e.g. before `clear_pipe_col` around line 3043)

- [ ] **Step 1: Write the routine**

Add this routine to `main.asm`:

```
;----------------------------------------------------------------
; update_city_cache: refresh 384-byte cache at CITY_CACHE.
;   slot[(row - CITY_TOP) * 12 + pipe * 4 + cell] =
;     if cityscape_heights[col_cell] >= (CITY_BOTTOM - row):
;       L/R: pipe_bitmap_city_X[phase*4 + cell] OR bg_buffer[col_cell][row]
;       M1/M2: pipe_bitmap_city_X[phase*4 + cell]
;     else:
;       pipe_bitmap[phase*4 + cell]
;
; X = 'a' for even rows, 'b' for odd rows.
; col_cell = byte_x_pipe + cell - 1 (cell ∈ {0=L, 1=M1, 2=M2, 3=R}).
;
; Cost target: ~5 k T-states/frame.
;----------------------------------------------------------------
update_city_cache:
        push    iy
        ld      iy, CITY_CACHE          ; output cursor → first slot
        ld      d, CITY_TOP             ; D = current scan-line row
.row_lp:
        ; For each pipe (3), emit 4 bytes into the cache.
        ; Outer reg usage:
        ;   D = row
        ;   IY = cache cursor
        ;   We use HL/BC freely; preserve D and IY across pipe iterations.
        ld      b, 0                    ; pipe index 0
.pipe_lp:
        push    bc                      ; save pipe idx
        push    de                      ; save row

        ; Get byte_x for this pipe → C
        ld      hl, pipe_state
        ld      a, b
        add     a, a                    ; pipe * 2 (each pipe is 2 bytes)
        add     a, l
        ld      l, a                    ; HL → pipe_state[pipe*2] (byte_x)
        ld      c, (hl)                 ; C = byte_x

        ; For each cell 0..3, decide sky vs city and write slot byte.
        ld      e, 0                    ; cell index
.cell_lp:
        push    bc                      ; save byte_x
        push    de                      ; save cell index

        ; col_cell = byte_x + cell - 1
        ld      a, c
        add     a, e
        dec     a                       ; A = col_cell
        ld      l, a
        ld      h, 0
        ld      bc, cityscape_heights
        add     hl, bc
        ld      a, (hl)                 ; A = cityscape_heights[col_cell]
        ld      b, a                    ; B = height (saved for later)

        ; Compute (CITY_BOTTOM - row) = building-coverage threshold
        pop     de                      ; restore cell index → E
        pop     hl                      ; restore byte_x → L (junk H)
        pop     af                      ; restore saved row from earlier (D)
        push    af                      ; (keep it pushed for next iter — restore at end)
        ; ... above restores got tangled; rewrite using a simpler reg map below.
```

The push/pop juggling here is getting hard to follow. Rewrite with a flatter approach using a small `.fill_one_cell` helper that takes (row, pipe, cell) in dedicated registers. Replace the above with the **simpler structure** below.

- [ ] **Step 2: Replace `update_city_cache` with the clearer version**

Delete what you just wrote and use this clean version. State is held in fixed memory variables to avoid stack-juggling.

```
;----------------------------------------------------------------
city_row_temp:   db 0                  ; current row
city_pipe_temp:  db 0                  ; current pipe index
city_bx_temp:    db 0                  ; current pipe byte_x
city_cell_temp:  db 0                  ; current cell index 0..3

update_city_cache:
        ld      iy, CITY_CACHE          ; output cursor
        ld      a, CITY_TOP
        ld      (city_row_temp), a
.row_lp:
        xor     a
        ld      (city_pipe_temp), a
.pipe_lp:
        ; Load this pipe's byte_x → city_bx_temp
        ld      hl, pipe_state
        ld      a, (city_pipe_temp)
        add     a, a                    ; pipe * 2 (entry stride)
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      a, (hl)                 ; byte_x
        ld      (city_bx_temp), a

        xor     a
        ld      (city_cell_temp), a
.cell_lp:
        call    .fill_one_cell          ; writes 1 byte at IY, advances IY
        inc     iy
        ld      a, (city_cell_temp)
        inc     a
        ld      (city_cell_temp), a
        cp      4
        jr      c, .cell_lp

        ld      a, (city_pipe_temp)
        inc     a
        ld      (city_pipe_temp), a
        cp      NUM_PIPES
        jr      c, .pipe_lp

        ld      a, (city_row_temp)
        inc     a
        ld      (city_row_temp), a
        cp      GROUND_TOP              ; = CITY_BOTTOM = 160
        jr      c, .row_lp
        ret

.fill_one_cell:
        ; Compute col_cell = byte_x + cell - 1
        ld      a, (city_bx_temp)
        ld      hl, city_cell_temp
        add     a, (hl)
        dec     a
        ld      e, a                    ; E = col_cell (0..31 in playfield)
        ; cityscape_heights[col_cell]
        ld      hl, cityscape_heights
        ld      d, 0
        add     hl, de
        ld      a, (hl)                 ; A = height
        ld      b, a                    ; B = height
        ; threshold = CITY_BOTTOM - row
        ld      a, CITY_BOTTOM
        ld      hl, city_row_temp
        sub     (hl)                    ; A = CITY_BOTTOM - row
        ; If height >= threshold: city. Else: sky.
        cp      b
        jr      z, .is_city
        jr      c, .is_city             ; threshold < height → covered
        ; ---- sky variant: pipe_bitmap[phase*4 + cell] ----
        ld      hl, pipe_bitmap
.write_bitmap:
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase*4
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → bitmap[phase*4]
        ld      a, (city_cell_temp)
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → bitmap[phase*4 + cell]
        ld      a, (hl)
        ld      (iy+0), a
        ret
.is_city:
        ; Pick city bitmap A or B based on row parity
        ld      a, (city_row_temp)
        and     1
        jr      nz, .is_city_b
        ld      hl, pipe_bitmap_city_a
        jr      .have_city_bitmap
.is_city_b:
        ld      hl, pipe_bitmap_city_b
.have_city_bitmap:
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → city_bitmap[phase*4]
        ld      a, (city_cell_temp)
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → city_bitmap[phase*4 + cell]
        ld      a, (hl)                 ; A = city pipe byte for this cell
        ; M1 (cell=1) and M2 (cell=2): no OR. L (0) and R (3): OR with bg_buffer.
        ld      hl, city_cell_temp
        ld      c, (hl)                 ; C = cell
        ld      b, a                    ; B = city pipe byte
        ld      a, c
        cp      1
        jr      z, .write_b             ; M1 — no OR
        cp      2
        jr      z, .write_b             ; M2 — no OR
        ; L or R: OR with bg_buffer[col_cell][row].
        ; bg_buffer address layout mirrors screen, but with bit 15 set
        ; (BG_BUFFER = $C000). Compute screen-row addr from line_table,
        ; then bit-7 of high byte → bg_buffer.
        ld      a, (city_row_temp)
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      a, (hl)
        ld      e, a
        inc     hl
        ld      a, (hl)
        or      $80                     ; bg_buffer addr (BG_BUFFER mirrors $4000 region with bit 15 set)
        ld      d, a                    ; DE = bg_buffer[row][0]
        ld      a, (city_bx_temp)
        ld      hl, city_cell_temp
        add     a, (hl)
        dec     a                       ; A = col_cell
        ; DE + A = bg_buffer byte addr
        add     a, e
        ld      e, a
        jr      nc, .no_carry
        inc     d
.no_carry:
        ld      a, (de)
        or      b                       ; A = pipe city byte OR bg byte
        ld      (iy+0), a
        ret
.write_b:
        ld      (iy+0), b
        ret
```

- [ ] **Step 3: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 4: Add a one-shot temporary call from `start:` so we can inspect the cache**

In `start:` (around line 44), add immediately before `im 1`:

```
        call    update_city_cache       ; TEMP — for inspection in Task 3
```

- [ ] **Step 5: Run in Fuse and inspect the cache**

```bash
make run
```

In Fuse:
1. Wait ~1 second for `start` to execute through to `main_loop`.
2. Pause (F5).
3. Open the memory monitor (`Machine → Debugger`, or `F11`).
4. View memory at `$EB00`. The first 12 bytes are (pipe 0 row 128) cells L,M1,M2,R then (pipe 1 row 128) and (pipe 2 row 128). For starting pipe positions (byte_x = 14, 21, 28 by default — confirm against `init_pipes`), most cells at row 128 should be sky-variant since few buildings reach 32 px.
5. Sanity check: verify at least one byte in the cache matches `pipe_bitmap[0]` (the sky-A L byte for phase 0). The two should be equal for any all-sky-row pipe.

- [ ] **Step 6: Remove the temporary call from `start:`**

```
        call    update_city_cache       ; TEMP — remove this line
```

- [ ] **Step 7: Commit**

```bash
git add src/main.asm
git commit -m "add update_city_cache: per-cell-resolved 384 B cache at \$EB00"
```

---

## Task 4: Implement `patch_pipe_targets` (per-wrap target update)

After each wrap, every pipe's `byte_x` decremented by 1, so every active screen target also decremented by 1. Walk the 320-entry `target_table` per pipe; for each active row (slot_addr non-zero), decrement the saved target and write the new lo/hi bytes through to the `ld sp,nn` immediate in `pipe_program`.

**Files:**
- Modify: `src/main.asm` (place near `wrap_byte_x`, around line 750)

- [ ] **Step 1: Write the routine**

```
;----------------------------------------------------------------
; patch_pipe_targets: called after wrap_byte_x. For each of 3 pipes,
; walks 160 rows; for each row whose slot_addr_table entry is non-zero,
; decrements target_table[row] (since byte_x dropped by 1) and writes
; the new 16-bit target into the ld sp,nn immediate slot at slot_addr.
;
; ~11 k T-states amortized over 4 frames = 2.7 k per frame.
;----------------------------------------------------------------
patch_pipe_targets:
        ld      b, NUM_PIPES
        ld      iy, 0                   ; IY = pipe index 0
.pipe_lp:
        push    bc                      ; save pipe loop counter
        push    iy                      ; save pipe idx

        ; HL → target_table[pipe * 320]
        push    iy
        pop     hl                      ; HL = pipe_idx (0/1/2)
        ; multiply HL by 320 (=$140)
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        add     hl, hl                  ; *8
        add     hl, hl                  ; *16
        add     hl, hl                  ; *32
        ld      de, hl                  ; (sjasmplus syntax for ld d,h / ld e,l)
        add     hl, hl                  ; *64
        add     hl, hl                  ; *128
        add     hl, hl                  ; *256
        ; HL = pipe * 256. Need pipe * 320 = pipe*256 + pipe*64.
        ; DE currently = pipe*32; we need pipe*64. Re-derive: simpler — use table lookup.
        ; Replace the math: use a 3-entry pointer table.
        pop     iy                      ; restore pipe_idx
        pop     bc                      ; restore loop counter
        push    bc
        push    iy
        ld      hl, pipe_target_base
        push    iy
        pop     de                      ; DE = pipe_idx
        add     hl, de
        add     hl, de                  ; HL → pipe_target_base[pipe*2]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl                  ; HL = target_table base for this pipe
        ld      de, slot_addr_base
        push    bc
        push    iy
        pop     bc
        add     hl, bc                  ; wrong direction — abandon this and use a flat layout.
```

Stop. The arithmetic above is wrong twice over. Use the cleaner approach below with a 3-entry pointer table indexed by pipe.

- [ ] **Step 2: Replace with the clean version**

Delete the broken draft and use this. Add a pair of small base-pointer tables to the data section first.

Find an appropriate data spot (e.g. just after `pipe_state` near line 141) and add:

```
pipe_target_base:
        dw      TARGET_TABLE + 0 * 320
        dw      TARGET_TABLE + 1 * 320
        dw      TARGET_TABLE + 2 * 320

pipe_slot_base:
        dw      SLOT_ADDR_TABLE + 0 * 320
        dw      SLOT_ADDR_TABLE + 1 * 320
        dw      SLOT_ADDR_TABLE + 2 * 320
```

Then add the routine:

```
patch_pipe_targets:
        ld      b, NUM_PIPES
        ld      c, 0                    ; pipe index
.pipe_lp:
        push    bc

        ; HL = target_table base for this pipe
        ld      a, c
        add     a, a                    ; pipe * 2 (16-bit entries)
        ld      e, a
        ld      d, 0
        ld      hl, pipe_target_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = target_table[pipe]

        ; DE = slot_addr_table base for this pipe (preserved as IX)
        pop     bc
        push    bc
        ld      a, c
        add     a, a
        ld      e, a
        ld      d, 0
        push    hl                      ; preserve target table ptr
        ld      hl, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a
        push    hl
        pop     ix                      ; IX = slot_addr_table[pipe]
        pop     hl                      ; HL = target_table[pipe]

        ; Loop 160 rows: for each, if slot_addr != 0, decrement target, write through.
        ld      b, 160                  ; row counter
.row_lp:
        ; Check slot_addr_table entry at IX
        ld      a, (ix+0)
        ld      e, a
        ld      a, (ix+1)
        ld      d, a
        or      e
        jr      z, .next                ; slot_addr = 0 → skip row
        ; Decrement target_table entry (HL+0/+1)
        ld      a, (hl)
        sub     1
        ld      (hl), a
        ld      c, a
        inc     hl
        ld      a, (hl)
        sbc     a, 0
        ld      (hl), a
        ld      b, a                    ; (clobbers row counter temporarily — fix below)
        dec     hl                      ; HL back to lo byte
        ; ... clobbering B is a bug. Use a different reg pair for the lo/hi write.
```

Stop again — `B` is the row counter, clobbering it loses the loop. Use a fresh register for the target's hi byte. Continue with:

```
        ; Re-write this section after .row_lp:
.row_lp:
        ld      a, (ix+0)
        ld      e, a
        ld      a, (ix+1)
        ld      d, a
        or      e
        jr      z, .next
        ; target -= 1: read lo/hi without clobbering B
        ld      a, (hl)
        sub     1
        ld      (hl), a
        ld      c, a                    ; C = new lo
        inc     hl
        ld      a, (hl)
        sbc     a, 0
        ld      (hl), a
        dec     hl                      ; HL back to lo
        ; Write through to pipe_program slot: (DE) = C, (DE+1) = A
        ex      de, hl                  ; HL ↔ DE; HL = slot addr, DE = target table ptr
        ld      (hl), c
        inc     hl
        ld      (hl), a
        dec     hl
        ex      de, hl                  ; restore: HL = target table ptr, DE = slot addr
.next:
        inc     hl
        inc     hl                      ; target_table stride = 2
        inc     ix
        inc     ix                      ; slot_addr stride = 2
        djnz    .row_lp

        pop     bc
        inc     c
        dec     b
        jr      nz, .pipe_lp
        ret
```

Combine the working pieces into a single routine. The result is:

```
patch_pipe_targets:
        ld      b, NUM_PIPES
        ld      c, 0                    ; pipe index
.pipe_outer:
        push    bc

        ld      a, c
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, pipe_target_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = target_table[pipe]
        push    hl

        pop     hl
        push    hl                      ; (HL preserved across next block)
        ld      a, c
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a
        push    hl
        pop     ix                      ; IX = slot_addr_table[pipe]
        pop     hl                      ; HL = target_table[pipe]

        ld      b, 160
.row_lp:
        ld      a, (ix+0)
        ld      e, a
        ld      a, (ix+1)
        ld      d, a
        or      e
        jr      z, .next
        ld      a, (hl)
        sub     1
        ld      (hl), a
        ld      c, a
        inc     hl
        ld      a, (hl)
        sbc     a, 0
        ld      (hl), a
        dec     hl
        ex      de, hl
        ld      (hl), c
        inc     hl
        ld      (hl), a
        dec     hl
        ex      de, hl
.next:
        inc     hl
        inc     hl
        inc     ix
        inc     ix
        djnz    .row_lp

        pop     bc
        inc     c
        dec     b
        jp      nz, .pipe_outer
        ret
```

- [ ] **Step 3: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 4: Commit (still un-wired — will be exercised in Task 8)**

```bash
git add src/main.asm
git commit -m "add patch_pipe_targets: per-wrap target decrement + slot write-through"
```

---

## Task 5: Implement `gen_pipe_program` shell with sky body emit only

Walk rows 0..127 (sky band). For each row and each pipe, classify (body / cap-top / gap / cap-bot / body-bot / off) and emit the sky-body row template if applicable. Skip cap and city for now — those come in Tasks 6 and 7. Empty rows emit nothing (just fall through to the next row).

**Files:**
- Modify: `src/main.asm` (place after `patch_pipe_targets`)

- [ ] **Step 1: Write the routine shell**

```
;----------------------------------------------------------------
; gen_pipe_program: full regenerate of the flat render program.
; Walks rows 0..159; for each pipe, classifies row and emits the
; appropriate template at IY (output cursor in pipe_program).
; Records slot addresses into slot_addr_table[pipe][row] and screen
; targets into target_table[pipe][row].
;
; TASK 5: sky body only. Cap/city emit added later.
;----------------------------------------------------------------
gen_pipe_program:
        ; Zero the slot_addr_table so unused rows are marked inactive.
        ld      hl, SLOT_ADDR_TABLE
        ld      de, SLOT_ADDR_TABLE + 1
        ld      (hl), 0
        ld      bc, SLOT_ADDR_TABLE_END - SLOT_ADDR_TABLE - 1
        ldir

        ld      iy, PIPE_PROGRAM
        ld      b, 0                    ; row counter
.row_lp:
        ld      c, 0                    ; pipe counter
.pipe_lp:
        push    bc
        ; Classify row B for pipe C → decide template
        ;   body row     : row < gap_y_C - 1
        ;   cap top      : row == gap_y_C - 1
        ;   in gap       : gap_y_C <= row < gap_y_C + PIPE_GAP
        ;   cap bot      : row == gap_y_C + PIPE_GAP
        ;   body bot     : gap_y_C + PIPE_GAP < row < GROUND_TOP
        ;   off (above)  : never (gap_y in 8..96 so cap_t always >= 7)
        ;   off (below)  : row >= GROUND_TOP
        ld      hl, pipe_state
        ld      a, c
        add     a, a
        add     a, l
        ld      l, a                    ; HL → pipe_state[pipe*2]
        ld      a, (hl)                 ; A = byte_x
        ld      e, a                    ; E = byte_x
        inc     hl
        ld      a, (hl)                 ; A = gap_y
        ld      d, a                    ; D = gap_y

        ; row in (gap_y .. gap_y+PIPE_GAP-1)?  in_gap if true.
        ld      a, b
        cp      d
        jr      c, .not_in_gap          ; row < gap_y
        ld      a, d
        add     a, PIPE_GAP
        ld      l, a                    ; L = gap_y + PIPE_GAP
        ld      a, b
        cp      l
        jr      nc, .not_in_gap         ; row >= gap_y+PIPE_GAP
        ; In gap — skip.
        jp      .pipe_done
.not_in_gap:
        ; Active row. Pipe pixel column = byte_x in E (already loaded).
        ; For TASK 5: emit sky-body template regardless (cap/city later).
        ; Don't filter cap/city yet — emit body for ALL active rows.
        ; This produces visually-wrong caps and city; gets fixed in Task 6-7.

        ; --- Emit: ld sp, line_table[row]+byte_x+3 ; push de ; push bc ---
        ;   ld sp, nn       opcode = $31, then nn lo, nn hi (3 bytes)
        ;   push de         opcode = $D5                    (1 byte)
        ;   push bc         opcode = $C5                    (1 byte)
        ;
        ; Determine variant: even row uses BC/DE (sky-A), odd row uses exx-wrapped BC'/DE' (sky-B).
        ld      a, b
        and     1
        jr      z, .emit_a
        ; --- Odd row: prepend exx (only if not already exx'd; for simplicity emit always) ---
        ld      (iy+0), $D9             ; exx
        inc     iy
.emit_a:
        ; Record slot addr → slot_addr_table[pipe][row] = IY+1 (the immediate, not the opcode)
        push    iy
        pop     hl
        inc     hl                      ; HL = address of the nn-lo byte of "ld sp,nn"
        ; slot_addr_table[pipe][row] address = SLOT_ADDR_TABLE + pipe*320 + row*2
        push    hl                      ; save slot-immediate addr
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = SLOT_ADDR_TABLE base for this pipe
        ld      a, b
        add     a, a                    ; row*2
        add     a, l
        ld      l, a
        jr      nc, .nc1
        inc     h
.nc1:
        pop     de                      ; DE = slot-immediate addr (= IY+1)
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Compute screen_target = line_table[row] + byte_x + 3, store in target_table[pipe][row] ---
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de                  ; HL → line_table[row]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      a, (pipe_state)         ; quick: we need byte_x for THIS pipe (C)
        ; Re-load byte_x for pipe C (E was clobbered above)
        ld      hl, pipe_state
        ld      a, c
        add     a, a
        add     a, l
        ld      l, a
        ld      a, (hl)                 ; A = byte_x
        add     a, 3                    ; +3 for stack-blast offset
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = line_addr + byte_x + 3
        push    hl                      ; save target

        ; Save into target_table[pipe][row]
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_target_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = target_table base for pipe
        ld      a, b
        add     a, a
        add     a, l
        ld      l, a
        jr      nc, .nc2
        inc     h
.nc2:
        pop     de                      ; DE = target
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Emit the actual bytes at IY ---
        ld      (iy+0), $31             ; ld sp, nn
        ld      (iy+1), e               ; lo
        ld      (iy+2), d               ; hi
        ld      (iy+3), $D5             ; push de
        ld      (iy+4), $C5             ; push bc
        ld      de, 5
        add     iy, de

        ; If odd row, append exx to swap back
        ld      a, b
        and     1
        jr      z, .pipe_done
        ld      (iy+0), $D9             ; exx
        inc     iy

.pipe_done:
        pop     bc                      ; restore pipe loop state
        inc     c
        ld      a, c
        cp      NUM_PIPES
        jp      c, .pipe_lp

        inc     b
        ld      a, b
        cp      GROUND_TOP
        jp      c, .row_lp

        ld      (iy+0), $C9             ; emit RET — end of program
        ret
```

The arithmetic-heavy parts of this routine are slow to read. The implementer should add comments as they go. The structure is: outer loop over rows, inner over pipes, classify, emit header (optional exx), emit `ld sp,nn ; push de ; push bc`, optional trailing exx.

- [ ] **Step 2: Assemble**

```bash
make clean && make
```

Expected: PASS (the routine is self-contained, no syntax errors).

- [ ] **Step 3: Wire `gen_pipe_program` into `init_pipes` (one-time call at start)**

Find `init_pipes` (around line 506) and replace its body with:

```
init_pipes:
        xor     a
        ld      (phase), a
        call    update_city_cache
        call    gen_pipe_program
        call    redraw_pipes_v2
        ret
```

Also remove the temporary `seed_pipe_program_with_ret` line from `start:` (added in Task 2) since gen_pipe_program now seeds it.

- [ ] **Step 4: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 5: Run in Fuse**

```bash
make run
```

Expected behavior at this point: **WRONG** rendering — pipes will draw as solid 4-byte rectangles top-to-bottom of the playfield (caps not yet special-cased, gap rows skipped correctly, but no cityscape handling, no city OR'd L/R). This is expected. The visual signal we care about:
- Three vertical solid pipe-coloured bars at the initial pipe columns.
- No flicker, no garbage.
- Bird still visible.

If you see anything else (full-screen garbage, lock-up, crash to ROM), there's a bug in the gen path. Fix before continuing.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "add gen_pipe_program: sky-body emit only; wire into init_pipes"
```

---

## Task 6: Extend `gen_pipe_program` with cap row emit + add `update_cap_imm`

For cap rows, emit `ld bc,nn ; ld de,nn ; ld sp,nn ; push de ; push bc` (8 bytes). Record the slot addresses of the four `nn` immediates so `update_cap_imm` can refresh them per phase.

**Files:**
- Modify: `src/main.asm` (extend `gen_pipe_program`; add `update_cap_imm`; add `cap_slot_table` data)

- [ ] **Step 1: Reserve `cap_slot_table`**

Near the existing `pipe_target_base` / `pipe_slot_base` block, add:

```
; cap_slot_table: addresses of the 4 immediate slots per cap-row per pipe.
; 2 cap rows × 3 pipes × 4 slots × 2 bytes = 48 bytes.
; Order: [pipe0_capt_bc_lo_addr, pipe0_capt_de_lo_addr, pipe0_capb_bc_lo_addr, pipe0_capb_de_lo_addr,
;         pipe1_..., pipe2_...]. Zero = inactive.
cap_slot_table: ds 24                   ; 12 16-bit pointers
```

- [ ] **Step 2: Modify `gen_pipe_program`'s row classification to detect cap rows**

In the `.not_in_gap` block, before falling into the sky-body emit, add cap detection:

```
.not_in_gap:
        ; Cap-top check: row == gap_y - 1
        ld      a, d                    ; D = gap_y
        dec     a
        cp      b
        jr      z, .emit_cap            ; row == gap_y-1 → cap top
        ; Cap-bot check: row == gap_y + PIPE_GAP
        ld      a, d
        add     a, PIPE_GAP
        cp      b
        jr      z, .emit_cap_bot
        ; Otherwise: body row — fall through to existing emit
        jp      .emit_body
.emit_cap:
        ; ... see Step 3
.emit_cap_bot:
        ; ... see Step 3
.emit_body:
        ; existing sky-body emit code from Task 5 goes here
```

- [ ] **Step 3: Add the cap emit blocks**

Inside `gen_pipe_program`, fill in `.emit_cap` and `.emit_cap_bot` to emit the cap template and record slot addresses into `cap_slot_table`. Both blocks share the same template (top and bottom caps draw the same pixel pattern — only the row differs). Use this for both, parameterised by an offset index:

```
.emit_cap:
        ld      a, 0                    ; cap-top offset within cap_slot_table for this pipe = 0
        jp      .do_cap
.emit_cap_bot:
        ld      a, 4                    ; cap-bot offset = 4 (after 2 cap-top slots)
.do_cap:
        ld      l, a                    ; L = within-pipe offset
        ; Build pointer cap_slot_table + pipe*8 + offset
        ld      a, c                    ; pipe
        add     a, a
        add     a, a
        add     a, a                    ; pipe * 8
        add     a, l
        ld      l, a
        ld      h, 0
        ld      de, cap_slot_table
        add     hl, de                  ; HL → cap_slot_table[pipe*8 + offset]

        ; Emit "ld bc, nn" — opcode $01, then nn lo, nn hi
        ld      (iy+0), $01
        ; record slot addr = IY+1
        push    iy
        pop     de
        inc     de
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl                      ; HL → next slot (de_lo_addr)
        ld      (iy+1), 0               ; placeholder (patched by update_cap_imm)
        ld      (iy+2), 0
        ; Emit "ld de, nn" — opcode $11, then nn lo, nn hi
        ld      (iy+3), $11
        push    iy
        pop     de
        inc     de
        inc     de
        inc     de
        inc     de                      ; DE = IY+4 (de-imm lo)
        ld      (hl), e
        inc     hl
        ld      (hl), d
        ld      (iy+4), 0               ; placeholder
        ld      (iy+5), 0
        ; Emit "ld sp, nn ; push de ; push bc" — same as sky-body tail
        ; Compute screen target for THIS row (same code as sky-body), then emit ld sp+pushes
        ; ... (same target compute + emit as sky-body)
        ; Then record slot_addr_table[pipe][row] as the address of the ld sp,nn immediate
        ; (for patch_pipe_targets to find on wrap).
        ; Implementer: copy the target-compute and slot-record logic from .emit_body, but
        ; emit at IY+6..IY+10 (after the 6 bytes of ld bc,nn ; ld de,nn).
        ; Total cap row = 11 bytes; advance IY by 11.
        ; Then jp .pipe_done.
```

The cap emit is mostly copy-and-adapt from the sky-body emit. The only differences are:
1. Two extra `ld bc,nn / ld de,nn` instructions prefixed (6 extra bytes).
2. Slot addresses for those 4 immediates recorded into `cap_slot_table` (not `slot_addr_table` — that one tracks the `ld sp` immediate).
3. Implementer must copy or refactor the slot/target compute into a helper to avoid duplicating ~30 lines.

- [ ] **Step 4: Add `update_cap_imm` to refresh cap-row immediates per phase**

```
;----------------------------------------------------------------
; update_cap_imm: for each (pipe, cap-row) recorded in cap_slot_table,
; writes the current phase's cap byte values into the bc-imm and de-imm
; slots in pipe_program.
;
; bc-imm holds M1<<8 | L (lo=L, hi=M1).
; de-imm holds R<<8  | M2 (lo=M2, hi=R).
; Source: cap_rounded_bitmap[phase*4 + 0..3] = [L, M1, M2, R].
;----------------------------------------------------------------
update_cap_imm:
        ; Compute current cap bytes
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      c, a
        ld      b, 0
        ld      hl, cap_rounded_bitmap
        add     hl, bc
        ld      a, (hl)                 ; A = L
        ld      (cap_L_temp), a
        inc     hl
        ld      a, (hl)
        ld      (cap_M1_temp), a
        inc     hl
        ld      a, (hl)
        ld      (cap_M2_temp), a
        inc     hl
        ld      a, (hl)
        ld      (cap_R_temp), a

        ; Walk cap_slot_table (12 16-bit entries, paired bc-slot then de-slot per cap-row).
        ld      ix, cap_slot_table
        ld      b, 6                    ; 6 cap-rows worst case (3 pipes × 2 caps)
.lp:
        ld      l, (ix+0)
        ld      h, (ix+1)
        ld      a, h
        or      l
        jr      z, .skip                ; slot=0 means cap row not present
        ; (HL) = L, (HL+1) = M1
        ld      a, (cap_L_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_M1_temp)
        ld      (hl), a
        ; Now the de-slot
        ld      l, (ix+2)
        ld      h, (ix+3)
        ld      a, (cap_M2_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_R_temp)
        ld      (hl), a
.skip:
        ld      de, 4
        add     ix, de                  ; advance to next cap-row pair (4 bytes)
        djnz    .lp
        ret

cap_L_temp:  db 0
cap_M1_temp: db 0
cap_M2_temp: db 0
cap_R_temp:  db 0
```

- [ ] **Step 5: Call `update_cap_imm` from `redraw_pipes_v2` entry**

In `redraw_pipes_v2`, immediately after the EXX section and before `call PIPE_PROGRAM`:

```
        exx
        ; ↑ end of sky-B load
        call    update_cap_imm          ; refresh cap immediates from cap_rounded_bitmap[phase*4]
        call    PIPE_PROGRAM
```

- [ ] **Step 6: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 7: Run in Fuse**

```bash
make run
```

Expected behavior: pipes now have **rounded cap pixels** at top and bottom of the gap (matching the visual style of the old renderer). City band still wrong (will be fixed in Task 7).

- [ ] **Step 8: Commit**

```bash
git add src/main.asm
git commit -m "add cap-row emit + update_cap_imm; pipes now have proper rounded caps"
```

---

## Task 7: Extend `gen_pipe_program` with city row emit (uses city cache)

For rows in CITY_TOP..CITY_BOTTOM-1 (= 128..159), emit the city template that pops 4 bytes from `city_cache[row][pipe]` then pushes to the screen target.

**Files:**
- Modify: `src/main.asm` (extend `gen_pipe_program`'s `.emit_body` to branch into a city emit on city rows)

- [ ] **Step 1: Modify the `.emit_body` block to detect city band**

At the top of `.emit_body`, add:

```
.emit_body:
        ld      a, b
        cp      CITY_TOP
        jr      c, .emit_sky_body       ; row < CITY_TOP → sky
        ; row in 128..159 → city template
        jp      .emit_city_body
.emit_sky_body:
        ; existing sky-body emit code (unchanged)
        ...
.emit_city_body:
        ; new — see Step 2
```

- [ ] **Step 2: Add the city emit block**

```
.emit_city_body:
        ; City template (10 bytes total):
        ;   ld sp, $imm_city_cache_slot   ; opcode $31 + 2 bytes (3 bytes total)
        ;   pop bc                        ; $C1                  (1)
        ;   pop de                        ; $D1                  (1)
        ;   ld sp, $imm_screen_target     ; $31 + 2 bytes        (3)
        ;   push de                       ; $D5                  (1)
        ;   push bc                       ; $C5                  (1)

        ; Compute city_cache slot addr = CITY_CACHE + (row-CITY_TOP)*12 + pipe*4
        ld      a, b
        sub     CITY_TOP
        ; A = row offset (0..31). Multiply by 12.
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        ld      de, hl                  ; (sjasmplus: ld d,h \ ld e,l)
        add     hl, hl                  ; *8
        add     hl, de                  ; *12
        ld      de, CITY_CACHE
        add     hl, de                  ; HL = CITY_CACHE + (row-CITY_TOP)*12
        ld      a, c                    ; A = pipe
        add     a, a
        add     a, a                    ; pipe * 4
        add     a, l
        ld      l, a
        jr      nc, .city_nc1
        inc     h
.city_nc1:
        ; HL = city_cache slot addr for (row, pipe)
        ; Emit "ld sp, HL"
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $C1             ; pop bc
        ld      (iy+4), $D1             ; pop de

        ; Now emit "ld sp, screen_target ; push de ; push bc" (same 5 bytes as sky body)
        ; — and record slot_addr_table[pipe][row] = address of the screen-target imm = IY+6.
        push    iy
        pop     hl
        ld      de, 6
        add     hl, de
        ; HL = address of screen-target lo byte
        ; Save into slot_addr_table[pipe][row]
        push    hl
        ; (slot table lookup, identical pattern to sky-body Task 5 Step 1)
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a
        ld      a, b
        add     a, a
        add     a, l
        ld      l, a
        jr      nc, .city_nc2
        inc     h
.city_nc2:
        pop     de                      ; DE = address of screen-target imm
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; Compute screen_target and store in target_table[pipe][row] (same as sky body)
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ; byte_x for this pipe
        ld      hl, pipe_state
        ld      a, c
        add     a, a
        add     a, l
        ld      l, a
        ld      a, (hl)
        add     a, 3
        ld      l, a
        ld      h, 0
        add     hl, de
        push    hl                      ; target on stack

        ; Save into target_table[pipe][row]
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_target_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a
        ld      a, b
        add     a, a
        add     a, l
        ld      l, a
        jr      nc, .city_nc3
        inc     h
.city_nc3:
        pop     de                      ; DE = target
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; Emit at IY+5..IY+9: ld sp,nn (with target as imm), push de, push bc
        ld      (iy+5), $31
        ld      (iy+6), e
        ld      (iy+7), d
        ld      (iy+8), $D5
        ld      (iy+9), $C5
        ld      de, 10
        add     iy, de
        jp      .pipe_done
```

- [ ] **Step 3: Call `update_city_cache` from `redraw_pipes_v2` entry**

In `redraw_pipes_v2`, after `update_cap_imm`:

```
        call    update_cap_imm
        call    update_city_cache
        call    PIPE_PROGRAM
```

- [ ] **Step 4: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 5: Run in Fuse**

```bash
make run
```

Expected behavior: pipes now render correctly across the cityscape band, with proper city OR'd L/R cells at the appropriate building heights.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "add city-row emit using city_cache; pipes now correct in city band"
```

---

## Task 8: Wire the new renderer into `frame_update` and `wrap_byte_x`

Switch `frame_update`'s pipe call from `redraw_pipes_linemajor` to `redraw_pipes_v2`. Replace the per-wrap `patch_pipe_smc` (fall-through from `wrap_byte_x`) with `patch_pipe_targets`. On gap_y recycle (inside `wrap_byte_x`), trigger a full `gen_pipe_program` regen (deferred to next frame so it doesn't blow the wrap-frame budget).

**Files:**
- Modify: `src/main.asm` — `frame_update` (line 521), `wrap_byte_x` fall-through (line ~785), add a `pending_regen` flag

- [ ] **Step 1: Swap the call in `frame_update`**

Change line 521:

```
        call    redraw_pipes_linemajor   →   call    redraw_pipes_v2
```

- [ ] **Step 2: Replace the `wrap_byte_x` fall-through to `patch_pipe_smc` with `patch_pipe_targets`**

Find the comment at line ~785 that says "Fall through to patch_pipe_smc". Remove the fall-through (insert a `ret` or `jp patch_pipe_targets` as appropriate).

Locate `.save:` at line 779 and change the end of `wrap_byte_x`:

```
.save:
        ld      (iy+0), a
        inc     iy
        inc     iy
        pop     bc
        djnz    .outer
        jp      patch_pipe_targets      ; tail-call replaces fall-through to patch_pipe_smc
```

- [ ] **Step 3: Handle gap_y recycle by setting a `pending_regen` flag**

Add a flag in the data area:

```
pending_regen: db 0
```

In `wrap_byte_x`'s `.recycle:` block (line 775), set the flag:

```
.recycle:
        call    random_gap_y
        ld      (iy+1), a
        ld      a, 1
        ld      (pending_regen), a
        ld      a, 29
```

- [ ] **Step 4: Check the flag at end of `frame_update` and regen if set**

In `frame_update`, just before the final `ret z` / `jp render_score` block (around line 553), insert:

```
        ld      a, (pending_regen)
        or      a
        jr      z, .no_regen
        xor     a
        ld      (pending_regen), a
        call    gen_pipe_program        ; full regen on next frame
.no_regen:
```

This makes the regen run on the frame AFTER the wrap that recycled — out of the critical wrap-frame path.

- [ ] **Step 5: Remove the now-dead `update_smc` and `update_cap_smc` calls from `frame_update`**

In `frame_update`, lines 539-540 currently say:

```
        call    advance_phase
        call    update_smc              ; REMOVE
        call    update_cap_smc          ; REMOVE
```

Delete the two `update_smc` / `update_cap_smc` lines. `redraw_pipes_v2` handles the per-frame value refresh now (BC/DE preload + `update_cap_imm` + `update_city_cache` inside the call).

Also remove the calls from `init_pipes` (Task 5 already replaced its body; verify the new body is correct and contains only: `xor a / ld (phase), a / call update_city_cache / call gen_pipe_program / call redraw_pipes_v2 / ret`).

- [ ] **Step 6: Assemble**

```bash
make clean && make
```

Expected: PASS.

- [ ] **Step 7: Run in Fuse — full integration test**

```bash
make run
```

Expected behavior:
- Pipes render correctly (sky + city + caps).
- Pipes scroll smoothly (2 px/frame).
- Bird responds to input, lands, scores.
- No tearing in the city band.
- The BLUE/GREEN/WHITE profile bands should be in the upper half of the screen and a large CYAN idle band should be visible — indicating the frame budget has plenty of headroom.

If profile shows CYAN only in the last few scan lines or vanishing, frame budget is exceeded. Investigate.

- [ ] **Step 8: Commit**

```bash
git add src/main.asm
git commit -m "wire redraw_pipes_v2 into frame_update; patch_pipe_targets in wrap path"
```

---

## Task 9: Verify byte parity against the old renderer

We need to confirm the new renderer produces the same screen as the old one (except where we deliberately improved it — per-cell-independent city transitions). The cleanest way: build with a deterministic random seed and capture screen snapshots from both versions.

**Files:**
- Modify: `src/main.asm` temporarily (fix random seed for the test); revert after

- [ ] **Step 1: Force the random seed and gap_y for deterministic comparison**

Find `rand_state: dw $ABCD` (around line 160) and ensure it stays at `$ABCD` (no change). Find `init_pipes`. Verify the initial pipe positions are deterministic (`byte_x` = 14, 21, 28 or whatever the code seeds — confirm by reading `init_pipes`).

If `init_pipes` calls `random_gap_y`, hard-code the gap_y values for this test by temporarily replacing with fixed values:

```
init_pipes:
        xor     a
        ld      (phase), a
        ld      hl, pipe_state
        ld      (hl), 14       ; pipe 0 byte_x
        inc     hl
        ld      (hl), 48       ; pipe 0 gap_y
        ...
```

(Or check whether `init_pipes` currently does this — adapt as needed.)

- [ ] **Step 2: Check out the baseline commit and capture a screen**

```bash
git stash    # save current work
git checkout <baseline-commit-from-task-0>
make clean && make
```

In Fuse:
1. Run `build/main.sna`.
2. Wait 100 frames (~2 seconds; use Fuse's frame counter or HALT-step).
3. Pause.
4. Save a snapshot: `File → Save Snapshot As → baseline.sna`. Or use `Machine → Save State`.
5. Use Fuse's memory-dump feature (or open `Machine → Memory`) to copy bytes $4000..$57FF (screen) and $5800..$5AFF (attrs) into a hex file `baseline_screen.hex`.

- [ ] **Step 3: Switch back to the new renderer and capture**

```bash
git checkout main    # or your branch
git stash pop
make clean && make
```

Repeat in Fuse:
1. Run, wait 100 frames, pause.
2. Dump screen + attrs to `new_screen.hex`.

- [ ] **Step 4: Diff**

```bash
diff baseline_screen.hex new_screen.hex
```

Expected: identical OR differences only in the city band rows where building heights vary abruptly — those are the cases the new renderer fixes (M1/M2 transition independently in the new design where the old one only flipped L/R).

For each differing byte, inspect: is it in the cityscape band (rows 128..159 = screen rows 16..19 char-wise, but pixel rows 128..159 = bytes at screen offsets that depend on the row→addr mapping)? If yes, is the new value the *more correct* one (i.e. matches what the cityscape building should look like with the pipe in front)? Document any deliberate differences.

- [ ] **Step 5: Restore the random `init_pipes`**

Revert the fixed seeds you added in Step 1.

- [ ] **Step 6: Commit verification artifacts (optional)**

If you saved snapshots/hex dumps to keep:

```bash
mkdir -p docs/superpowers/test-artifacts
mv baseline_screen.hex new_screen.hex docs/superpowers/test-artifacts/
git add docs/superpowers/test-artifacts/
git commit -m "byte parity test artifacts for 50Hz codegen verification"
```

---

## Task 10: Verify 50 Hz cadence and tear-free city band

Now that byte parity is confirmed, verify cadence and tearing.

- [ ] **Step 1: Run in Fuse and watch border profile bands**

```bash
make run
```

In Fuse, observe the border colour bands during gameplay:
- BLUE band (bird ops region) should be in the upper-middle of the screen.
- GREEN band (ground) just below.
- WHITE band (end-of-frame state) just below that.
- CYAN band (post-halt idle) should occupy the LARGE bottom portion of the border — at least 30 lines tall (= ~6700 T-states idle = under 90% budget used).

If CYAN is small or missing, frame budget exceeded. Profile each component to find the regression.

- [ ] **Step 2: Run for 30 seconds and frame-count the scroll**

Without flapping the bird (let it fall and stay dead, or just don't press a key), the world scrolls at 2 px/frame. In 30 seconds at 50 Hz: 1500 frames × 2 px = 3000 px of scroll.

Use Fuse's frame counter (`Machine → Debugger → Cycle count`) or count `byte_x` cycles (pipes wrap every 32 frames; visible wraps in 30s = 1500/32 ≈ 46).

Expected: cadence is exactly 50 frames/second, ± 1. If you see 25 Hz cadence (counter advances at half speed), one or more frames are slipping a halt.

- [ ] **Step 3: Visual tear test — 5 minutes**

Run the game for 5 minutes. Watch carefully for:
- Any horizontal seam in the city band (a row where the building changes mid-frame).
- Any pipe partial-draw (top half of pipe one frame, full pipe next frame).
- Any cap flicker.

Expected: zero tearing, zero flicker, zero partial draws.

- [ ] **Step 4: If anything fails Steps 1-3, profile and fix**

Common causes:
- `gen_pipe_program` ran on a critical-path wrap frame instead of deferred → check `pending_regen` flag wiring.
- A per-row template exceeds 224 T-states → measure and inline/optimise.
- City cache update too expensive → measure `update_city_cache` cost.

Commit any fixes:

```bash
git add src/main.asm
git commit -m "fix: <specific issue from Step 1-3>"
```

- [ ] **Step 5: If all pass, commit a verification note**

```bash
git commit --allow-empty -m "verify: 50Hz cadence + tear-free city band over 5 min"
```

---

## Task 11: Delete the old paint and dispatch machinery

With the new renderer verified, remove the now-dead code. Each deletion is a separate commit so any regression can be bisected.

**Files:**
- Modify: `src/main.asm` (deletions)

- [ ] **Step 1: Delete the dispatch_sort + patch_block_* data**

Search for `dispatch_sort:`, `dispatch_sort_sentinel:`, `dispatch_first_row_init:`, `dispatch_first_block_init:`, `dispatch_sort_swapped:`, `dispatch_sentinel_block:`, `patch_block_P1L:`, `patch_block_P1R:`, `patch_block_P2L:`, `patch_block_P2R:`, `patch_block_P3L:`, `patch_block_P3R:` and `NUM_DISPATCH_BLOCKS` EQU. Delete all of them and any inline comments referring to the dispatch mechanism.

- [ ] **Step 2: Assemble**

```bash
make clean && make
```

Expected: assembly errors for any remaining references to the deleted labels. Resolve by also deleting those references.

- [ ] **Step 3: Run in Fuse — confirm game still runs correctly**

```bash
make run
```

Expected: identical to Task 10 behaviour.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "delete dispatch_sort + patch_block_* (obsolete dispatch machinery)"
```

- [ ] **Step 5: Delete `redraw_pipes_linemajor`**

Find `redraw_pipes_linemajor:` and the closing `ret` (or `jp .restore`) of its `.restore` block. Delete the whole routine.

Also delete its local data: `lm_line_addr`, `lm_line_num`, `draw_pipe_body_top`, `draw_pipe_rest`.

- [ ] **Step 6: Assemble + run**

```bash
make clean && make && make run
```

Expected: identical behaviour.

- [ ] **Step 7: Commit**

```bash
git add src/main.asm
git commit -m "delete redraw_pipes_linemajor"
```

- [ ] **Step 8: Delete `paint_LMMR`, `paint_LMMR_city`, … (all body paint variants)**

The complete list of routines to delete (search and remove):
- `paint_LMMR`, `paint_LMMR_city`
- `paint_LMM`, `paint_LMM_city`
- `paint_LM`, `paint_LM_city`
- `paint_L`, `paint_L_city`
- `paint_MMR`, `paint_MMR_city`
- `paint_MR`, `paint_MR_city`
- `paint_R`, `paint_R_city`

For each, delete the routine body (from the label to its `ret`).

- [ ] **Step 9: Assemble + run**

```bash
make clean && make && make run
```

Expected: identical behaviour.

- [ ] **Step 10: Commit**

```bash
git add src/main.asm
git commit -m "delete paint_LMMR/LMM/LM/L/MMR/MR/R (all sky+city body paint variants)"
```

- [ ] **Step 11: Delete the cap paint variants**

Delete:
- `paint_cap_rounded_LMMR`, `paint_cap_rounded_LMMR_city`
- `paint_cap_rounded_LMM`, `paint_cap_rounded_LMM_city`
- `paint_cap_rounded_LM`, `paint_cap_rounded_LM_city`
- `paint_cap_rounded_L`, `paint_cap_rounded_L_city`
- `paint_cap_rounded_MMR`, `paint_cap_rounded_MMR_city`
- `paint_cap_rounded_MR`, `paint_cap_rounded_MR_city`
- `paint_cap_rounded_R`, `paint_cap_rounded_R_city`

- [ ] **Step 12: Assemble + run + commit**

```bash
make clean && make && make run
git add src/main.asm
git commit -m "delete paint_cap_rounded_* (all cap paint variants)"
```

- [ ] **Step 13: Delete `update_smc`, `update_cap_smc`, `patch_pipe_smc`**

The new design uses `update_phase_regs` inline, `update_cap_imm`, `update_city_cache`, `patch_pipe_targets` instead. Delete:
- `update_smc:` (line ~1164)
- `update_cap_smc:` (line ~671)
- `patch_pipe_smc:` (line ~790)
- The 6 city caches: `city_aL_cache`, `city_aR_cache`, `city_bL_cache`, `city_bR_cache`, `city_cL_cache`, `city_cR_cache` (around line 86)

- [ ] **Step 14: Assemble + run + commit**

```bash
make clean && make && make run
git add src/main.asm
git commit -m "delete update_smc/update_cap_smc/patch_pipe_smc + obsolete city caches"
```

- [ ] **Step 15: Sanity-check binary size**

```bash
ls -l build/main.sna
```

Compare against the pre-change size (find the size of the snapshot at the Task 0 baseline commit). New binary may be similar size (we deleted ~1.5 KB of code but added ~1.5 KB of new code + tables that were previously fitted differently). The important thing: assembly succeeds and behavior is correct.

---

## Task 12: Acceptance verification

Run the full acceptance criteria from spec §12.

- [ ] **Step 1: 5-minute tear test**

Run the game for 5 minutes. Hold for the BIRD never to die (or restart on death). Watch for:
- Tearing in city band: none permitted.
- Cap flicker: none permitted.
- Pipe partial-draw: none permitted.

- [ ] **Step 2: 30-second cadence test**

Frame-count over 30 seconds. Expected: 1500 ± 5 frames.

- [ ] **Step 3: Profile band test**

CYAN profile band ≥ 30 lines tall on every frame (visual inspection — pause and check the border).

- [ ] **Step 4: Variable-height building correctness test**

Patch `cityscape_heights` (around line 367) with an aggressive variation, e.g.:

```
cityscape_heights:
        db 0, 0, 0, 0           ; cols 0-3 (buffer)
        db 32, 8, 24, 0         ; cols 4-7
        db 16, 32, 0, 24        ; cols 8-11
        db 8, 32, 24, 16        ; cols 12-15
        db 0, 8, 32, 16         ; cols 16-19
        db 24, 0, 8, 32         ; cols 20-23
        db 16, 24, 0, 8         ; cols 24-27
        db 0, 0, 0, 0           ; cols 28-31 (buffer)
```

Rebuild and run. Watch pipes scroll across these columns. Each pipe should transition cell-by-cell into the city band, NOT all four cells at once. Building edges should be pixel-perfect with no halos at the pipe seams.

If anything looks wrong, fix and re-test. Restore the original `cityscape_heights` before final commit.

- [ ] **Step 5: Commit acceptance**

```bash
git add src/main.asm
git commit --allow-empty -m "acceptance: 50Hz cadence, tear-free, variable city heights verified"
```

- [ ] **Step 6: Tag the release**

```bash
git tag 50hz-flat-codegen-complete
```

---

## Self-Review

### Spec coverage check

| Spec section | Plan task | Notes |
|---|---|---|
| §1 Problem statement | n/a — addressed by goal in header | |
| §2 Approach | n/a — addressed by architecture in header | |
| §3 Memory map | Task 1 | EQUs added |
| §4.1 Empty row | Task 5 | Implicit — no bytes emitted, falls through |
| §4.2 Sky-A body | Task 5 | Even-row template |
| §4.3 Sky-B body | Task 5 | Odd-row + exx wrap |
| §4.4 Cap row | Task 6 | `ld bc,nn / ld de,nn` template + update_cap_imm |
| §4.5 City body row | Task 7 | Uses city_cache, per-cell-resolved |
| §4.6 Function epilogue | Task 5 | Emit RET at end of gen |
| §5.1 Patch path | Task 4 | patch_pipe_targets |
| §5.2 Full regen path | Tasks 5-7 (built incrementally) + Task 8 (`pending_regen` defers it) | |
| §5.3 Pseudocode | Tasks 5-7 (actual implementation) | |
| §6 Per-phase byte values | Task 2 (BC/DE preload), Task 3 (city cache), Task 6 (cap_imm) | |
| §7 Integration | Task 8 | All call-site swaps |
| §8 Cycle budget | Task 10 (verify) | |
| §9.1 Build clean | Each task's assemble step | |
| §9.2 Byte parity | Task 9 | |
| §9.3 Profile bands | Task 10 step 1 | |
| §9.4 Tear test | Task 10 step 3 + Task 12 step 1 | |
| §9.5 Cadence test | Task 10 step 2 + Task 12 step 2 | |
| §9.6 Memory safety | Task 1 (EQUs), implicit | |
| §9.7 Wrap regression | Task 12 step 4 (height variation) | |
| §9.8 Variable height correctness | Task 12 step 4 | |
| §12 Acceptance | Task 12 | |

All spec sections covered.

### Placeholder scan

- Task 4 has a long abandoned draft followed by the clean version. The implementer reads top-to-bottom — they could be confused. Mitigated by the explicit "Stop. The arithmetic above is wrong. Use the clean version below." callouts. Still, the rejected drafts add noise. The implementer should follow the final clean code only.
- Task 5 and 6 use `ld de, hl` which is sjasmplus pseudocode (translates to `ld d,h \ ld e,l`). Noted inline.
- Task 6 Step 3 ends with "Implementer: copy the target-compute and slot-record logic from .emit_body, but emit at IY+6..IY+10". This is the closest the plan gets to a placeholder — the implementer must adapt ~30 lines of existing code. Justified by avoiding double-printing of the same code, and the adaptation is mechanical.
- No "TBD" or "fill in later" remain.

### Type consistency

- `gen_pipe_program`, `patch_pipe_targets`, `update_city_cache`, `update_cap_imm`, `redraw_pipes_v2`: names consistent across tasks.
- `cap_slot_table` introduced in Task 6, used only in Task 6. Consistent.
- `pending_regen`: introduced in Task 8 Step 3, used in Task 8 Step 4. Consistent.
- `pipe_target_base`, `pipe_slot_base`: introduced in Task 4 Step 2, used in Tasks 4, 5, 6, 7. Consistent.

No type inconsistencies found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-13-50hz-flat-codegen-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
