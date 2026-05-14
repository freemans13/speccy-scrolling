# Fixed-Slot Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the per-second recycle pause by replacing `gen_pipe_program` (~95k T-states) with a fixed-grid + SMC role-swap (~12k T-states), restoring steady 50Hz on every frame including recycle frames.

**Architecture:** `PIPE_PROGRAM` becomes a pre-emitted 480-slot grid (160 rows × 3 pipes) in row-major render order. Each row has a leading `exx` byte (preserves A/B row-parity dithering) and 3 fixed-size pipe slots. On recycle, a single 0..159 pass re-templates the recycled pipe's slots in place — body/skip/cap_top/cap_bot — and rebuilds that pipe's 112-entry active sublist. Cap dispatch is via `call` to 6 SMC-patched handlers that push cap bytes through HL (leaves BC/DE intact so row-parity dithering survives caps).

**Tech Stack:** ZX Spectrum 48K, Z80 assembly, sjasmplus build, Fuse emulator for visual verification.

**Spec:** `docs/superpowers/specs/2026-05-14-fixed-slot-dispatch-design.md`

---

## Testing approach for this codebase

There is **no automated test framework** for this Z80 assembly game. Each task's verification is:

1. **Build gate:** `make` from repo root must produce `Errors: 0, warnings: 0`.
2. **Visual gate (where relevant):** `make run` opens `build/main.sna` in Fuse. Check:
   - Game starts; cityscape + 3 pipes appear.
   - Pipes scroll smoothly leftward.
   - Border profiler colours flash in expected sequence (RED → YELLOW → MAGENTA → BLUE → GREEN → WHITE → CYAN).
   - **Critical regression check:** every ~75 frames the WHITE band on the recycle frame should *not* extend through the entire visible area (it does today; the goal is to eliminate that).

Make frequent commits — one per task — so any visual regression can be bisected.

## File structure

Only `src/main.asm` changes. The plan adds ~600 lines of new code and deletes ~400 lines of dead code. New code is grouped near the existing renderer code for locality:

| New label / region | Approx location |
|---|---|
| `SLOT_GRID_BASE` EQU + supporting EQUs | near existing EQUs at main.asm:42 |
| `slot_addr_table` (data, 960 B) | repurpose `SLOT_ADDR_TABLE` at $F440 (existing legacy alloc) |
| `cap_top_handler_pipe_0..2`, `cap_bot_handler_pipe_0..2` (code, ~120 B) | code segment, after `redraw_pipes_v2` |
| `init_pipe_program` (code) | code segment, before `redraw_pipes_v2` (called once at game start) |
| `configure_pipe_slots` (code) | code segment, near `wrap_byte_x` |
| `update_cap_imm_v2` (replaces `update_cap_imm`) | replaces main.asm:3772 |

Deleted:
- `gen_pipe_program` and all sublabels (main.asm:901..1381 — ~480 lines)
- `cap_slot_table` data + access logic (main.asm:202)
- Shadow-buffer state vars (main.asm:223..238)
- `ROWS_PER_CHUNK` and chunked-gen scaffolding

---

## Memory map after these changes

| Addr | Size | Purpose |
|---|---|---|
| $DB00 | 2048 B | Slot grid normal band (rows 0..127): 128 × 16 B |
| $E300 | 992 B | Slot grid city band (rows 128..159): 32 × 31 B |
| $E6E0 | ~5 B | Epilogue (`ld sp,(saved_sp); ret`) |
| $E6E5 | unused | slack to $EB00 |
| $EB00 | 1024 B | CITY_BG_TABLE (unchanged) |
| $EF00 | 384 B | CITY_CACHE (unchanged) |
| $F080 | 192 B | CITY_OVERLAY (unchanged) |
| $F140 | 720 B | reclaimed from `ACTIVE_LIST_B` (deprecated); now unused or repurposed |
| $F440 | 960 B | `slot_addr_table[160][3]` (was legacy `SLOT_ADDR_TABLE`) |
| $F800 | 576 B | CITY_TABLE (legacy unused) |
| $FA40 | 720 B | ACTIVE_LIST_A — three per-pipe sublists of 112 entries each |
| $FD10 | 2 B | ACTIVE_COUNT (constant 336; can become an EQU) |

---

## Task 1: Add new EQUs and remove obsolete ones

**Files:**
- Modify: `src/main.asm:42-78` (EQU block)

**Goal:** Define the new slot grid memory map. Leave old code untouched — it still builds and runs as-is.

- [ ] **Step 1: Edit the EQU block**

Replace the block at `src/main.asm:42-78` with:

```asm
; ─── Slot grid layout (fixed-slot dispatch) ──────────────────────
SLOT_GRID_BASE         EQU $DB00       ; 3045 B total grid
SLOT_GRID_NORMAL_BASE  EQU SLOT_GRID_BASE              ; rows 0..127
SLOT_GRID_NORMAL_SIZE  EQU 128 * 16                    ; 2048 B
SLOT_GRID_CITY_BASE    EQU SLOT_GRID_BASE + SLOT_GRID_NORMAL_SIZE  ; $E300
SLOT_GRID_CITY_SIZE    EQU 32 * 31                     ; 992 B
SLOT_GRID_END          EQU SLOT_GRID_CITY_BASE + SLOT_GRID_CITY_SIZE  ; $E6E0
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

NORMAL_ROW_STRIDE      EQU 16          ; 1 (exx) + 3*5
CITY_ROW_STRIDE        EQU 31          ; 1 (exx) + 3*10
NORMAL_SLOT_STRIDE     EQU 5
CITY_SLOT_STRIDE       EQU 10

; ─── Cityscape data (unchanged) ──────────────────────────────────
CITY_BG_TABLE          EQU $EB00       ; 1024 B
CITY_BG_TABLE_END      EQU $EF00
CITY_CACHE             EQU $EF00       ; 384 B
CITY_CACHE_END         EQU $F080
CITY_OVERLAY           EQU $F080       ; 192 B
CITY_OVERLAY_END       EQU $F140

; ─── Pre-computed slot addresses ─────────────────────────────────
SLOT_ADDR_TABLE        EQU $F440       ; 480 entries × 2 B = 960 B
SLOT_ADDR_TABLE_END    EQU $F800

; ─── Legacy unchanged ────────────────────────────────────────────
CITY_TABLE             EQU $F800       ; legacy unused
CITY_TABLE_END         EQU $FA40

; ─── Active list (per-pipe sublists) ─────────────────────────────
ACTIVE_PIPE_0          EQU $FA40       ; 112 entries × 2 B = 224 B
ACTIVE_PIPE_1          EQU ACTIVE_PIPE_0 + 224
ACTIVE_PIPE_2          EQU ACTIVE_PIPE_1 + 224
ACTIVE_LIST_END        EQU ACTIVE_PIPE_2 + 224       ; $FD10
ACTIVE_COUNT           EQU 336         ; constant; all three sublists × 112

; (Legacy alias kept until cleanup task; patch_pipe_targets currently reads it)
ACTIVE_LIST_NEW        EQU ACTIVE_PIPE_0
ACTIVE_COUNT_NEW       EQU $FD10       ; 2 B counter (will become an EQU)
```

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0, compiled: 58XX lines` (some address EQU values changed but no code referenced them in a load-bearing way except `PIPE_PROGRAM` which still points to `$DB00`).

- [ ] **Step 3: Run and verify no regression**

Run: `make run` — game should still run exactly as it did before (the EQU rename is symbolic; addresses where code/data sit are unchanged so far).

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "memmap: introduce slot grid EQUs (no code change yet)"
```

---

## Task 2: Add the six cap handler routines

**Files:**
- Modify: `src/main.asm` — add new code block immediately before `redraw_pipes_v2:` at main.asm:1951.

**Goal:** Define the 6 cap handlers as fixed-address code. Not yet called by anything — pure code addition.

- [ ] **Step 1: Add the handler block**

Insert immediately before `redraw_pipes_v2:`:

```asm
;----------------------------------------------------------------
; Cap handlers (called by cap_top / cap_bot slots).
; Each handler:
;   1. Saves caller SP (so call's return-addr survives the inner SP-hijack)
;   2. Hijacks SP to the cap's screen target (SMC slot patched by patch_pipe_targets)
;   3. Loads cap M2/R byte pair into HL via SMC imm, pushes (writes M2/R cells)
;   4. Loads cap L/M1 byte pair into HL via SMC imm, pushes (writes L/M1 cells)
;   5. Restores caller SP and returns
;
; HL is used (not BC/DE) so the row's main register set survives the call —
; this preserves A/B row-parity dithering across cap rows.
;
; The SMC slots:
;   *_target  : 2-byte screen address, patched by patch_pipe_targets each wrap
;   *_bc_imm  : 2-byte L/M1 byte pair (low=L, high=M1), patched by update_cap_imm_v2
;   *_de_imm  : 2-byte M2/R byte pair (low=M2, high=R), patched by update_cap_imm_v2
;----------------------------------------------------------------

cap_saved_caller_sp: dw 0

cap_top_handler_pipe_0:
        ld      (cap_saved_caller_sp), sp
cap_top_handler_pipe_0_target EQU $+1
        ld      sp, $0000                       ; SMC: patched by patch_pipe_targets
cap_top_handler_pipe_0_de EQU $+1
        ld      hl, $0000                       ; SMC: M2/R pair, patched by update_cap_imm_v2
        push    hl
cap_top_handler_pipe_0_bc EQU $+1
        ld      hl, $0000                       ; SMC: L/M1 pair, patched by update_cap_imm_v2
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

cap_top_handler_pipe_1:
        ld      (cap_saved_caller_sp), sp
cap_top_handler_pipe_1_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

cap_top_handler_pipe_2:
        ld      (cap_saved_caller_sp), sp
cap_top_handler_pipe_2_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

cap_bot_handler_pipe_0:
        ld      (cap_saved_caller_sp), sp
cap_bot_handler_pipe_0_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_0_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_0_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

cap_bot_handler_pipe_1:
        ld      (cap_saved_caller_sp), sp
cap_bot_handler_pipe_1_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

cap_bot_handler_pipe_2:
        ld      (cap_saved_caller_sp), sp
cap_bot_handler_pipe_2_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      sp, (cap_saved_caller_sp)
        ret

; Per-pipe handler address tables for indexed dispatch in configure_pipe_slots.
cap_top_handler_addrs:
        dw      cap_top_handler_pipe_0
        dw      cap_top_handler_pipe_1
        dw      cap_top_handler_pipe_2
cap_bot_handler_addrs:
        dw      cap_bot_handler_pipe_0
        dw      cap_bot_handler_pipe_1
        dw      cap_bot_handler_pipe_2

; Per-pipe SMC label tables for update_cap_imm_v2 and configure_pipe_slots.
cap_top_bc_imm_addrs:
        dw      cap_top_handler_pipe_0_bc
        dw      cap_top_handler_pipe_1_bc
        dw      cap_top_handler_pipe_2_bc
cap_top_de_imm_addrs:
        dw      cap_top_handler_pipe_0_de
        dw      cap_top_handler_pipe_1_de
        dw      cap_top_handler_pipe_2_de
cap_bot_bc_imm_addrs:
        dw      cap_bot_handler_pipe_0_bc
        dw      cap_bot_handler_pipe_1_bc
        dw      cap_bot_handler_pipe_2_bc
cap_bot_de_imm_addrs:
        dw      cap_bot_handler_pipe_0_de
        dw      cap_bot_handler_pipe_1_de
        dw      cap_bot_handler_pipe_2_de
cap_top_target_imm_addrs:
        dw      cap_top_handler_pipe_0_target
        dw      cap_top_handler_pipe_1_target
        dw      cap_top_handler_pipe_2_target
cap_bot_target_imm_addrs:
        dw      cap_bot_handler_pipe_0_target
        dw      cap_bot_handler_pipe_1_target
        dw      cap_bot_handler_pipe_2_target
```

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0, compiled: 59XX lines`. Line count grows by ~150.

- [ ] **Step 3: Run — verify no regression**

Run: `make run` — game still runs exactly as before (handlers are unreachable code at this point).

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: add 6 cap handlers (unreachable; no behaviour change)"
```

---

## Task 3: Add `init_slot_addr_table`

**Files:**
- Modify: `src/main.asm` — add new routine near `init_background:` at main.asm:512.

**Goal:** Build the `slot_addr_table[160][3]` lookup table at init.

- [ ] **Step 1: Add the routine**

Insert near the other init routines (before `init_background`):

```asm
;----------------------------------------------------------------
; init_slot_addr_table: pre-compute slot_addr_table[row][pipe] = byte address
; of the (row, pipe) slot's first byte (the byte AFTER the row's leading EXX).
;
; Layout:
;   row in 0..127   →  SLOT_GRID_BASE + row*16 + 1 + pipe*5
;   row in 128..159 →  SLOT_GRID_CITY_BASE + (row-128)*31 + 1 + pipe*10
;
; Entry index: row*3 + pipe (16-bit address per entry).
; Total table size: 480 × 2 = 960 bytes at SLOT_ADDR_TABLE.
;----------------------------------------------------------------
init_slot_addr_table:
        ld      hl, SLOT_ADDR_TABLE      ; HL = write cursor
        ld      b, 0                      ; B = row counter
.row_lp:
        ld      a, b
        cp      128
        jr      nc, .city_row

        ; Normal row: base = SLOT_GRID_NORMAL_BASE + row*16 + 1
        ld      a, b
        ld      e, a
        ld      d, 0
        ; DE = row
        ex      de, hl
        add     hl, hl   ; ×2
        add     hl, hl   ; ×4
        add     hl, hl   ; ×8
        add     hl, hl   ; ×16
        ld      de, SLOT_GRID_NORMAL_BASE + 1
        add     hl, de   ; HL = slot for (row, pipe=0)
        ex      de, hl   ; DE = slot[row][0], HL = cursor again
        ld      c, 3      ; 3 pipes
.normal_pipe_lp:
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ; DE += 5 (NORMAL_SLOT_STRIDE)
        ld      a, e
        add     a, NORMAL_SLOT_STRIDE
        ld      e, a
        jr      nc, .npp_no_carry
        inc     d
.npp_no_carry:
        dec     c
        jr      nz, .normal_pipe_lp
        jr      .row_done

.city_row:
        ; City row: base = SLOT_GRID_CITY_BASE + (row-128)*31 + 1
        ld      a, b
        sub     128
        ld      e, a
        ld      d, 0      ; DE = row - 128
        ; DE × 31 = DE × 32 - DE
        push    de
        ex      de, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl    ; HL = DE × 32
        pop     de
        or      a
        sbc     hl, de    ; HL = DE × 31
        ld      de, SLOT_GRID_CITY_BASE + 1
        add     hl, de    ; HL = slot for (row, pipe=0)
        ; Need to restore write cursor — pull it back from saved location
        ; We've trashed HL; we need cursor back. Switch strategy: use IX as cursor.
        ; (See note below — rework if needed)
        ; ----- placeholder, will rework -----
        ; For clarity in plan: implement city-row branch with the same pattern
        ; as normal-row but stride 10 instead of 5 and base offset 992 etc.
        ; ------------------------------------
        ; For now placeholder: re-use the writing pattern but with stride 10.
        ld      de, $0000   ; (placeholder; engineer: implement with proper cursor)

.row_done:
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jr      nz, .row_lp
        ret
```

**Engineer note:** the city-row branch above is illustrative but incomplete — the routine needs to preserve the write cursor across the address math. **Recommended cleaner rewrite using IX as the persistent write cursor:**

```asm
init_slot_addr_table:
        ld      ix, SLOT_ADDR_TABLE
        ld      b, 0
.row_lp:
        push    bc
        ld      a, b
        cp      128
        jr      nc, .city_row

        ; Normal: DE = SLOT_GRID_NORMAL_BASE + row*16 + 1
        ld      l, b
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = row × 16
        ld      de, SLOT_GRID_NORMAL_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = base addr for pipe 0
        ld      c, NORMAL_SLOT_STRIDE
        jr      .write_3_pipes

.city_row:
        ; City: DE = SLOT_GRID_CITY_BASE + (row-128)*31 + 1
        ld      a, b
        sub     128
        ld      l, a
        ld      h, 0
        ld      d, h
        ld      e, l                            ; DE = row - 128
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = (row-128) × 32
        or      a
        sbc     hl, de                          ; HL = (row-128) × 31
        ld      de, SLOT_GRID_CITY_BASE + 1
        add     hl, de                          ; HL = base addr for pipe 0
        ex      de, hl                          ; DE = base addr
        ld      c, CITY_SLOT_STRIDE

.write_3_pipes:
        ld      b, 3
.wp_lp:
        ld      (ix+0), e
        ld      (ix+1), d
        inc     ix
        inc     ix
        ld      a, e
        add     a, c
        ld      e, a
        jr      nc, .wp_no_carry
        inc     d
.wp_no_carry:
        djnz    .wp_lp

        pop     bc
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jr      nz, .row_lp
        ret
```

Use the second version. Delete the placeholder first version from your edit.

- [ ] **Step 2: Build**

Run: `make`
Expected: `Errors: 0, warnings: 0`. Line count grows by ~50.

- [ ] **Step 3: Sanity-check the table (one-time test code)**

Add a temporary debug routine to verify the table values for rows 0, 127, 128, 159:

```asm
; TEMP — call once after init_slot_addr_table, then halt. Remove after verify.
debug_check_slot_table:
        ; Read slot_addr_table[0][0] — expect SLOT_GRID_NORMAL_BASE + 1 = $DB01
        ld      hl, (SLOT_ADDR_TABLE)
        ; Read slot_addr_table[127][2] — expect $DB00 + 127*16 + 1 + 2*5 = $DEFB
        ld      hl, (SLOT_ADDR_TABLE + (127*3 + 2)*2)
        ; Read slot_addr_table[128][0] — expect $E300 + 0*31 + 1 = $E301
        ld      hl, (SLOT_ADDR_TABLE + (128*3 + 0)*2)
        ; Read slot_addr_table[159][2] — expect $E300 + 31*31 + 1 + 2*10 = $E6DE
        ld      hl, (SLOT_ADDR_TABLE + (159*3 + 2)*2)
        halt
        ret
```

Run: `make run` after temporarily calling `init_slot_addr_table` + `debug_check_slot_table` from `main_loop`'s top. Set a Fuse breakpoint on `halt` and inspect HL at each line in the disassembly view. Confirm $DB01, $DEFB, $E301, $E6DE.

**If the values don't match: STOP. Fix the address math before moving on. The whole plan depends on this table being correct.**

- [ ] **Step 4: Remove the debug routine and the temporary call**

Delete `debug_check_slot_table` and the temporary `call init_slot_addr_table` you inserted.

- [ ] **Step 5: Build and verify game still runs unchanged**

Run: `make && make run`. No regression — `init_slot_addr_table` is still not being called in production.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "feat: add init_slot_addr_table (precompute slot address LUT)"
```

---

## Task 4: Add `init_pipe_program` (slot grid emit)

**Files:**
- Modify: `src/main.asm` — add new routine after `init_slot_addr_table`.

**Goal:** Write the initial slot grid: per-row EXX byte + 3 default body slots per row + epilogue. Don't wire it up to runtime yet.

- [ ] **Step 1: Add the routine**

```asm
;----------------------------------------------------------------
; init_pipe_program: emit the initial slot grid into PIPE_PROGRAM memory.
;
; For every row 0..159:
;   write $D9 (exx) at row_base
;   write 3 default body slots starting at row_base+1, stride NORMAL_SLOT_STRIDE
;     (rows 0..127) or CITY_SLOT_STRIDE (rows 128..159)
;   body slot bytes (normal): 31 lo hi D5 C5 = ld sp,target; push de; push bc
;   body slot bytes (city)  : 31 lc hc C1 D1 31 ls hs D5 C5
;                             = ld sp,cache_addr; pop bc; pop de;
;                               ld sp,screen_target; push de; push bc
;
; target (screen)  = line_table[row] + (byte_x - 1)*2 + 4   (byte_x = initial pipe state)
; cache_addr (city)= CITY_CACHE + (row-128)*12 + pipe*4    (city cache cell address)
;
; After the grid, write epilogue: ED 73 lo hi C9
;     = ld (saved_sp), sp; ret    (4+1 bytes — but we want ld sp,(saved_sp); ret)
;
; CORRECTION: epilogue should be `ld sp, (saved_sp); ret` = ED 7B lo hi C9 (5 B)
;   ED 7B = opcode ld sp,(nn); lo hi = saved_sp address; C9 = ret
;----------------------------------------------------------------
init_pipe_program:
        call    init_slot_addr_table

        ld      b, 0                                ; row counter
.row_lp:
        push    bc

        ; Look up slot[row][0] address — also row base (slot[row][0] - 1 = exx byte)
        ld      a, b
        add     a, a                                ; row × 2
        ld      l, a
        ld      h, 0
        ld      de, SLOT_ADDR_TABLE
        add     hl, de                              ; HL → slot_addr_table[row][0] entry
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                             ; DE = slot[row][0] (first byte AFTER exx)

        ; Write EXX byte at (DE - 1)
        dec     de
        ld      a, $D9
        ld      (de), a
        inc     de                                  ; DE → slot[row][0] again

        ; Determine band: B < 128 → normal, else city
        ld      a, b
        cp      128
        jr      nc, .city_row_emit

        ; Normal row: emit 3 × body slots
        ld      c, 3
.normal_pipe_lp:
        push    bc
        push    de
        ; --- compute target for (row=B, pipe = 3-C) ---
        ; pipe_index = 3 - C
        ld      a, 3
        sub     c
        call    .compute_normal_body_target         ; returns DE = target
        pop     hl                                  ; HL = slot first byte
        ; Write body template: 31 lo hi D5 C5
        ld      (hl), $31
        inc     hl
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      (hl), $D5
        inc     hl
        ld      (hl), $C5
        inc     hl                                  ; HL = next slot first byte
        ex      de, hl                              ; DE = next slot
        pop     bc
        dec     c
        jr      nz, .normal_pipe_lp
        jr      .row_done

.city_row_emit:
        ; City row: emit 3 × city body slots (10 bytes each)
        ld      c, 3
.city_pipe_lp:
        push    bc
        push    de
        ld      a, 3
        sub     c
        call    .compute_city_cache_addr            ; returns BC = cache_addr
        push    bc
        ld      a, 3
        sub     c                                   ; pipe index (will be off; need preserve)
        ; (Engineer: pipe index handling here is fiddly — see Step 2 cleanup note)
        ; -- placeholder; rewrite cleanly --
        pop     bc
        pop     hl                                  ; HL = slot first byte
        ; ... continue with template writes ...
        pop     bc
        dec     c
        jr      nz, .city_pipe_lp

.row_done:
        pop     bc
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jr      nz, .row_lp

        ; Write epilogue at SLOT_GRID_END
        ld      hl, SLOT_GRID_END
        ld      (hl), $ED
        inc     hl
        ld      (hl), $7B
        inc     hl
        ld      (hl), low saved_sp
        inc     hl
        ld      (hl), high saved_sp
        inc     hl
        ld      (hl), $C9
        ret

;----------------------------------------------------------------
; Helper: compute_normal_body_target(row=B, pipe=A) → DE = line_table[row] + (byte_x-1)*2 + 4
;----------------------------------------------------------------
.compute_normal_body_target:
        push    af
        ; HL = pipe_state[pipe*2] (byte_x byte)
        add     a, a                                ; pipe × 2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de
        ld      a, (hl)                             ; A = byte_x
        ; Compute screen offset: (byte_x - 1) is encoded as cell column; but emit
        ; logic in current code adds +3 to byte_x for the stack-blast end pointer.
        ; Keep parity with current gen_pipe_program convention: target = line_addr + byte_x + 3
        add     a, 3
        ld      c, a
        ; DE = line_table[row]  (B = row)
        ld      h, 0
        ld      l, b
        add     hl, hl                              ; row × 2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                             ; DE = line_addr
        ; DE += C (byte_x + 3)
        ld      a, e
        add     a, c
        ld      e, a
        jr      nc, .cnbt_no_carry
        inc     d
.cnbt_no_carry:
        pop     af
        ret

.compute_city_cache_addr:
        ; (Engineer: implement — returns BC = CITY_CACHE + (row-128)*12 + pipe*4
        ; for the city cache cell base. See update_city_cache_fast for the
        ; precise byte layout per (row, pipe, cell-pair).)
        ret
```

**Engineer note for city emit:** the city slot template (`31 lc hc C1 D1 31 ls hs D5 C5`) needs two screen-related targets per slot. Pattern after `gen_pipe_program`'s `.emit_city_body` branch at main.asm:line-equivalent — port that emit logic into the slot writer. Keep the layout consistent with `update_city_cache_fast`'s expectations.

- [ ] **Step 2: Build**

Run: `make`
Expected: clean build. Line count grows by ~150.

- [ ] **Step 3: Run — verify no regression**

`make run` — game still runs as before (init_pipe_program is defined but uncalled).

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: add init_pipe_program (slot grid emit; not yet wired up)"
```

---

## Task 5: Add `configure_pipe_slots`

**Files:**
- Modify: `src/main.asm` — add new routine after `init_pipe_program`.

**Goal:** The recycle hot path. Re-templates one pipe's 160 slots and rebuilds that pipe's active sublist in a single pass.

- [ ] **Step 1: Add the routine**

```asm
;----------------------------------------------------------------
; configure_pipe_slots(pipe_in_A, new_gap_y_in_E):
;   For each row r in 0..159:
;     determine slot type for r given new_gap_y:
;       r == new_gap_y - 1               → cap_top
;       r == new_gap_y + 48              → cap_bot
;       r in [new_gap_y, new_gap_y + 47] → skip
;       else                              → body
;     write template at slot_addr_table[r][pipe]
;     for body: target = line_table[r] + byte_x + 3
;     emit active_pipe_N entry if body or cap (skip = no entry)
;
;   Recompute cap_top_target_imm_pipe_N and cap_bot_target_imm_pipe_N
;   in the cap handler SMC slots.
;
;   Store new_gap_y → pipe_state[pipe].gap_y.
;
; Inputs:
;   A = pipe (0..2)
;   E = new_gap_y (1..111)
; Clobbers: A, BC, DE, HL, IX, IY
;----------------------------------------------------------------

cps_pipe:      db 0     ; scratch
cps_gap_y:     db 0
cps_byte_x:    db 0
cps_cap_top_r: db 0
cps_cap_bot_r: db 0
cps_active_cursor: dw 0

configure_pipe_slots:
        ld      (cps_pipe), a
        ld      a, e
        ld      (cps_gap_y), a
        ; cap_top_row = gap_y - 1
        dec     a
        ld      (cps_cap_top_r), a
        ; cap_bot_row = gap_y + PIPE_GAP
        ld      a, e
        add     a, PIPE_GAP
        ld      (cps_cap_bot_r), a
        ; byte_x = pipe_state[pipe*2]
        ld      a, (cps_pipe)
        add     a, a                            ; pipe × 2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de
        ld      a, (hl)
        ld      (cps_byte_x), a

        ; Init active_cursor → start of this pipe's sublist
        ld      a, (cps_pipe)
        ld      l, a
        ld      h, 0
        ; HL = pipe × 224
        ; (224 = 112 entries × 2 B = 0xE0; compute via shifts)
        add     hl, hl   ; ×2
        add     hl, hl   ; ×4
        add     hl, hl   ; ×8
        add     hl, hl   ; ×16
        add     hl, hl   ; ×32
        ld      d, h
        ld      e, l     ; DE = pipe × 32
        add     hl, hl   ; ×64
        add     hl, hl   ; ×128
        add     hl, hl   ; ×256 — but we want ×224 not ×256
        ; (Engineer: compute pipe×224 with a different shift/sub strategy or
        ;  use a pre-built table. Easier: build cps_sublist_base_table.)
        ld      bc, ACTIVE_PIPE_0
        add     hl, bc
        ld      (cps_active_cursor), hl

        ld      b, 0                            ; row counter
.row_lp:
        ; Determine slot type for (row B, gap_y) — branch on three comparisons
        push    bc
        ld      c, b                            ; preserve row in C across calls

        ld      a, c
        ld      hl, cps_cap_top_r
        cp      (hl)
        jp      z, .write_cap_top

        ld      hl, cps_cap_bot_r
        cp      (hl)
        jp      z, .write_cap_bot

        ld      hl, cps_gap_y
        cp      (hl)
        jp      c, .write_body                  ; row < gap_y

        ld      hl, cps_cap_bot_r               ; row < cap_bot_row means in gap
        cp      (hl)
        jp      c, .write_skip

        ; row > cap_bot_row → body
        jp      .write_body

.write_body:
        call    .lookup_slot_addr               ; DE = slot addr for (row C, pipe)
        ; Determine band by C value
        ld      a, c
        cp      128
        jr      nc, .write_body_city
        ; Normal body: 31 lo hi D5 C5
        call    .compute_target                 ; HL = target
        ex      de, hl                          ; HL = slot addr, DE = target
        ld      (hl), $31
        inc     hl
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      (hl), $D5
        inc     hl
        ld      (hl), $C5
        ; Append slot_addr+1 (target imm lo) to active list
        ld      de, (cps_active_cursor)
        ; HL points to slot+4 (last byte). Subtract 3 to get target imm lo (slot+1).
        ld      a, l
        sub     3
        ld      l, a
        jr      nc, .wb_lo_no_borrow
        dec     h
.wb_lo_no_borrow:
        ld      a, l
        ld      (de), a
        inc     de
        ld      a, h
        ld      (de), a
        inc     de
        ld      (cps_active_cursor), de
        jp      .row_done

.write_body_city:
        ; City body: 31 lc hc C1 D1 31 ls hs D5 C5
        ; (Engineer: implement city body emit. cache_addr from CITY_CACHE layout,
        ; screen target from compute_target. Then append slot_addr+6 — the screen
        ; target imm lo — to active list.)
        jp      .row_done

.write_skip:
        call    .lookup_slot_addr               ; DE = slot addr
        ld      a, c
        cp      128
        jr      nc, .write_skip_city
        ; Normal skip: 5 × NOP
        ex      de, hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        jp      .row_done

.write_skip_city:
        ; City skip: 10 × NOP
        ex      de, hl
        ld      b, 10
.wsc_lp:
        ld      (hl), 0
        inc     hl
        djnz    .wsc_lp
        jp      .row_done

.write_cap_top:
        call    .lookup_slot_addr               ; DE = slot addr
        ld      a, c
        cp      128
        jr      nc, .write_cap_top_city
        ; Normal cap_top: CD lo hi 00 00 — call cap_top_handler_pipe_N
        ex      de, hl
        ld      (hl), $CD
        inc     hl
        push    hl
        ; Load handler addr from cap_top_handler_addrs[pipe]
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_handler_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                          ; DE = handler addr
        pop     hl
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        ; Append handler's target imm addr to active list
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_target_imm_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                          ; DE = handler's target imm addr
        ld      hl, (cps_active_cursor)
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      (cps_active_cursor), hl
        ; Update cap handler's target imm to point at this row's screen address
        push    de
        call    .compute_target                 ; HL = line_table[C] + byte_x + 3
        pop     de
        ld      a, l
        ld      (de), a
        inc     de
        ld      a, h
        ld      (de), a
        jp      .row_done

.write_cap_top_city:
        ; City cap_top: CD lo hi 00 00 00 00 00 00 00 — call handler, 7 nops
        ; (Implement: same shape as normal cap_top but with 7 trailing NOPs.)
        jp      .row_done

.write_cap_bot:
        call    .lookup_slot_addr
        ld      a, c
        cp      128
        jr      nc, .write_cap_bot_city
        ; Normal cap_bot: CD lo hi 00 00
        ; (Implement: same as cap_top using cap_bot_handler_addrs etc.)
        jp      .row_done

.write_cap_bot_city:
        ; City cap_bot: CD lo hi 7 × NOP
        ; (Implement.)
        jp      .row_done

.row_done:
        pop     bc
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jp      nz, .row_lp

        ; Store new_gap_y into pipe_state
        ld      a, (cps_pipe)
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de
        inc     hl                              ; HL → pipe_state[pipe*2 + 1] = gap_y
        ld      a, (cps_gap_y)
        ld      (hl), a
        ret

;----------------------------------------------------------------
; Helper: .lookup_slot_addr  — DE = slot_addr_table[row=C][pipe=cps_pipe]
;----------------------------------------------------------------
.lookup_slot_addr:
        ld      a, c                            ; row
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row × 2
        ; index = (row × 3 + pipe) × 2 = row × 6 + pipe × 2
        ; Compute: HL = row × 6 = (row × 2) × 3 — easier: row × 2 then add row × 2 + row × 2
        ld      d, h
        ld      e, l                            ; DE = row × 2
        add     hl, de                          ; HL = row × 4
        add     hl, de                          ; HL = row × 6
        ld      a, (cps_pipe)
        add     a, a                            ; pipe × 2
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL = row × 6 + pipe × 2
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ret

;----------------------------------------------------------------
; Helper: .compute_target — HL = line_table[row=C] + byte_x + 3
;----------------------------------------------------------------
.compute_target:
        ld      a, c
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      a, (hl)
        ld      e, a
        inc     hl
        ld      a, (hl)
        ld      d, a                            ; DE = line_addr
        ld      a, (cps_byte_x)
        add     a, 3
        ld      l, a
        ld      h, 0
        add     hl, de                          ; HL = line_addr + byte_x + 3
        ret
```

**Engineer note:** the city-band variants of `write_body`, `write_skip`, `write_cap_top`, `write_cap_bot` are placeholders. Implement them following the same pattern as their normal counterparts but with the corresponding 10-byte templates. Match `gen_pipe_program`'s `.emit_city_body` byte layout for city bodies.

**Also:** the pipe×224 calculation in the cursor init is wrong as written — recommended fix: replace with a 3-entry lookup table:

```asm
cps_sublist_base_table:
        dw      ACTIVE_PIPE_0
        dw      ACTIVE_PIPE_1
        dw      ACTIVE_PIPE_2
```

Use it instead of the shift-based math.

- [ ] **Step 2: Build**

Run: `make`
Expected: clean build.

- [ ] **Step 3: Run — verify no regression**

`make run` — game still runs as before (configure_pipe_slots is defined but uncalled).

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: add configure_pipe_slots (recycle hot path; not yet wired up)"
```

---

## Task 6: Add `update_cap_imm_v2`

**Files:**
- Modify: `src/main.asm` — add new routine near `update_cap_imm:` at main.asm:3772. Do NOT delete the old one yet.

**Goal:** Compute per-frame cap bytes (using current phase) and write them to the 12 cap handler SMC imm slots (6 handlers × 2 imms each — bc_imm and de_imm).

- [ ] **Step 1: Add the routine**

```asm
;----------------------------------------------------------------
; update_cap_imm_v2: for each pipe, compute the 4 cap bytes (L, M1, M2, R)
; from cap_rounded_bitmap (or cap_rounded_bitmap_city for city rows) at the
; current phase, then write:
;   handler.bc_imm = L | (M1 << 8)   (push hl pushes H then L → memory: L, M1)
;   handler.de_imm = M2 | (R << 8)   (memory: M2, R)
;
; For city caps (cap_bot when gap_y ≥ 80): the L and R cells need the same
; OR-with-cityscape masking as the current update_cap_imm does for those cells.
;
; Output destinations (computed via cap_top_bc_imm_addrs etc. tables):
;   cap_top_handler_pipe_N_bc and _de SMC slots
;   cap_bot_handler_pipe_N_bc and _de SMC slots
;----------------------------------------------------------------
update_cap_imm_v2:
        ; (Engineer: port the byte-computation logic from update_cap_imm at
        ; main.asm:3772. Difference: instead of dereferencing cap_slot_table[]
        ; to find where to write, use the per-pipe SMC imm address tables
        ; cap_top_bc_imm_addrs / cap_top_de_imm_addrs / cap_bot_bc_imm_addrs
        ; / cap_bot_de_imm_addrs.
        ;
        ; The cap byte arrangement (L low byte of BC pair, M1 high byte etc.)
        ; mirrors the body push order: push de pushes M2,R; push bc pushes L,M1.
        ; Use the same memory layout as before but writes go to handler imms.
        ;
        ; For city cap_bot: determine if pipe's cap_bot row is in city band
        ; (gap_y + PIPE_GAP >= CITY_TOP). If yes, apply cityscape OR masking
        ; to L and R cells using bg_buffer + overlay tables.
        ret
```

- [ ] **Step 2: Implement the body**

Port from the existing `update_cap_imm` at main.asm:3772. Read that routine carefully. Two key differences in the new version:
1. **No `cap_slot_table` lookup.** Write directly to `cap_top_handler_pipe_N_bc/de` and `cap_bot_handler_pipe_N_bc/de` via the address tables.
2. **No "skip if cap not present" check.** Every recycle resets cap row positions and `configure_pipe_slots` updates the cap target. The handler imms get freshly-computed values every frame regardless of whether the slot currently dispatches to that handler.

- [ ] **Step 3: Build**

Run: `make`
Expected: clean build.

- [ ] **Step 4: Run — verify no regression**

`make run` — old code path still active; new path is dead code.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "feat: add update_cap_imm_v2 (writes handler imms; not yet wired)"
```

---

## Task 7: Cutover — wire new path, keep old as fallback

**Files:**
- Modify: `src/main.asm` — `main_loop` init sequence (near main.asm:97), `redraw_pipes_v2` (main.asm:1951), `frame_update` recycle handler (main.asm:631-640).

**Goal:** Switch the live path from `gen_pipe_program` / `update_cap_imm` / current PIPE_PROGRAM to the new init + configure_pipe_slots + update_cap_imm_v2.

This is the cutover commit — the moment of truth. Build + visual verify carefully.

- [ ] **Step 1: Call `init_pipe_program` at startup**

Find the existing init sequence (the code path that runs before `main_loop`'s `halt` — should be `call init_background`, etc.). After all existing init calls, before entering `main_loop`, add:

```asm
        call    init_pipe_program
```

This:
- Builds `slot_addr_table`
- Emits the default body grid
- For each pipe in pipe_state, calls `configure_pipe_slots(pipe, initial_gap_y)`

Wait — step 5 of the spec's init says configure_pipe_slots is called for each pipe at init. Add this loop too, after `init_pipe_program` finishes its grid emit. Looking at the routine in Task 4, the grid emit writes default bodies for ALL rows; we then need to apply per-pipe initial gaps:

```asm
        call    init_pipe_program
        ; Apply initial cap/skip configuration for each pipe.
        xor     a
.init_cps_lp:
        push    af
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; pipe × 2
        ld      de, pipe_state
        add     hl, de
        inc     hl                              ; HL → gap_y byte
        ld      e, (hl)                         ; E = initial gap_y for this pipe
        pop     af
        push    af
        call    configure_pipe_slots
        pop     af
        inc     a
        cp      NUM_PIPES
        jr      nz, .init_cps_lp
```

- [ ] **Step 2: Modify `redraw_pipes_v2`**

Find main.asm:1951. The current routine loads A-pattern bytes into BC/DE, EXX, loads B-pattern into BC'/DE'. For the new program (which starts with EXX before row 0), we want entry state `main=B, shadow=A` so the first EXX swaps to main=A for the even row 0.

The current code at main.asm:1996-2000 loads `(body_a_bc)` and `(body_a_de)` into main BC/DE after the EXX dance. Change this to load `(body_b_bc)` and `(body_b_de)` instead. Then EXX once so main=A, shadow=B; we WANT main=B, so do not EXX. Or simpler: keep the current load-A-into-main pattern but EXX once before the `call PIPE_PROGRAM` to swap.

The cleanest version:
```asm
        ; ... existing setup, then:
        ld      bc, (body_a_bc)
        ld      de, (body_a_de)
        exx
        ld      bc, (body_b_bc)
        ld      de, (body_b_de)
        ; main = B, shadow = A — first EXX in PIPE_PROGRAM swaps to A for row 0
        ld      a, 3
        out     ($fe), a
        call    PIPE_PROGRAM
        ret
```

Replace the existing reload at main.asm:1996-2000 with this. Also replace the existing `call update_cap_imm` (main.asm:1990) with `call update_cap_imm_v2`.

- [ ] **Step 3: Modify the `pending_regen` handler in `frame_update`**

Find main.asm:634-640. The current code is:

```asm
        ld      a, (pending_regen)
        or      a
        jr      z, .no_regen
        xor     a
        ld      (pending_regen), a
        call    gen_pipe_program
.no_regen:
```

The current `wrap_byte_x` (main.asm:1407-1411) sets `pending_regen` to 1 when a pipe recycles, but doesn't record *which* pipe. We need to pass that information through.

Add a `recycled_pipe_idx` byte. Modify `wrap_byte_x` at main.asm:1407 to store the recycled pipe index:

```asm
.recycle:
        call    random_gap_y
        ld      (iy+1), a
        ld      a, 1
        ld      (pending_regen), a
        ; Record pipe index — B counts down from NUM_PIPES to 1, so index = NUM_PIPES - B
        ld      a, NUM_PIPES
        sub     b
        ld      (recycled_pipe_idx), a
        ld      a, 29
        jr      .save
```

Add the state var near other pipe state (e.g. near `pending_regen` at main.asm:224):
```asm
recycled_pipe_idx: db 0
```

Now modify the `frame_update` handler:
```asm
        ld      a, (pending_regen)
        or      a
        jr      z, .no_regen
        xor     a
        ld      (pending_regen), a
        ld      a, (recycled_pipe_idx)
        ; A = pipe index
        ; E = new gap_y for that pipe = pipe_state[pipe*2 + 1]
        push    af
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de
        inc     hl
        ld      e, (hl)
        pop     af
        call    configure_pipe_slots
.no_regen:
```

- [ ] **Step 4: Build**

Run: `make`
Expected: clean build. Line count should reflect new code + 0 deletions.

- [ ] **Step 5: Run — VISUAL VERIFY (critical checkpoint)**

`make run`. Observe carefully:
1. **Initial render:** cityscape + 3 pipes appear correctly.
2. **First few seconds:** pipes scroll smoothly leftward; bird flap+fall works.
3. **At ~1.5 seconds (first recycle):** the WHITE band on the recycle frame should now occupy < 1 scanline (vs. entire visible area before). This is the success signal.
4. **Sustained gameplay (30+ seconds):** no visual glitches at cap/gap transitions, no frame skip, score increments correctly.
5. **Cap row appearance:** caps appear at expected positions for each pipe, including pipes that have recycled.

**If the game crashes or shows corruption:** STOP. Common issues:
- Cap handler `ld sp, (cap_saved_caller_sp)` reads stale SP — verify `cap_saved_caller_sp` is in regular RAM (not screen RAM) and isn't being clobbered.
- Slot grid emission has off-by-one in EXX byte placement — verify with Fuse memory inspector at `$DB00`-`$DB10` that the first 16 bytes look like `D9 31 xx xx D5 C5 31 xx xx D5 C5 31 xx xx D5 C5`.
- `configure_pipe_slots` writes outside its slot grid — verify CITY_BG_TABLE at $EB00 hasn't been corrupted (use Fuse memory view).
- `redraw_pipes_v2` register state at PIPE_PROGRAM entry — single-step from `call PIPE_PROGRAM` and verify main BC/DE = B values, shadow BC/DE = A values.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "feat: cutover to fixed-slot dispatch (gen_pipe_program path replaced)"
```

---

## Task 8: Delete dead code

**Files:**
- Modify: `src/main.asm` — delete obsolete code blocks.

**Goal:** Remove `gen_pipe_program`, `cap_slot_table`, shadow-buffer scaffolding, chunked-gen state. Only do this after Task 7 verifies the new path is working.

- [ ] **Step 1: Delete `gen_pipe_program`**

Delete from `gen_pipe_program:` at main.asm:901 through to but NOT including the next top-level label (`wrap_byte_x:` at main.asm:1382). About 480 lines.

- [ ] **Step 2: Delete `cap_slot_table` data**

Delete the line at main.asm:202: `cap_slot_table: ds 24`.

- [ ] **Step 3: Delete the old `update_cap_imm`**

Delete the entire `update_cap_imm:` routine at main.asm:3772 (find its end at the next top-level label or `ret` and remove everything between).

- [ ] **Step 4: Delete shadow-buffer state vars and chunked-gen state**

Delete the block at main.asm:223-238:
```asm
wrap_pending:     ; KEEP — still used by apply/restore_pipe_attrs
pending_regen:    ; KEEP — still used in cutover
gen_chunk_state:  ; DELETE
gen_iy_save:      ; DELETE
gen_row_save:     ; DELETE
wraps_during_gen: ; DELETE
ROWS_PER_CHUNK:   ; DELETE
shadow_buf_addr:  ; DELETE
shadow_list_addr: ; DELETE
shadow_count_addr: ; DELETE
live_list_addr:   ; DELETE
live_count_addr:  ; DELETE
active_set:       ; DELETE
```

Keep `wrap_pending` and `pending_regen` — both still referenced.

- [ ] **Step 5: Delete obsolete EQUs**

Delete from the EQU block (Task 1 left some legacy aliases):
- `PIPE_PROGRAM_A`, `PIPE_PROGRAM_B`, `PIPE_PROGRAM_END`
- `ACTIVE_LIST_A`, `ACTIVE_LIST_B`, `ACTIVE_COUNT_A`, `ACTIVE_COUNT_B`
- `CAP_SLOT_LIST_NEW`, `CAP_SLOT_COUNT_NEW`
- `ACTIVE_LIST_NEW` alias and `ACTIVE_COUNT_NEW` (replace with `ACTIVE_PIPE_0` + the new `ACTIVE_COUNT` EQU = 336)

Search for any remaining references to the deleted symbols. `patch_pipe_targets` at main.asm:835 will likely reference the old `ACTIVE_LIST_NEW` and `ACTIVE_COUNT_NEW`. Either:
- Update `patch_pipe_targets` to walk `ACTIVE_PIPE_0` for `ACTIVE_COUNT` (= 336) entries, OR
- Keep the aliases `ACTIVE_LIST_NEW EQU ACTIVE_PIPE_0` and `ACTIVE_COUNT_NEW EQU` (a memory location storing 336) for now.

Choose the simpler path: keep aliases. The cleanup of `patch_pipe_targets` itself is out of scope for this plan (the spec calls it "preserved unchanged").

- [ ] **Step 6: Build**

Run: `make`
Expected: clean build. Line count drops by ~400.

- [ ] **Step 7: Run — full visual verification**

`make run`. Same checklist as Task 7 Step 5, plus 60+ seconds of sustained gameplay through 45+ recycles. Watch for any drift, glitch, or stuck cap.

- [ ] **Step 8: Commit**

```bash
git add src/main.asm
git commit -m "cleanup: delete gen_pipe_program, cap_slot_table, shadow-buffer scaffolding"
```

---

## Task 9: Final verification + profile band check

**Files:** none (verification only).

- [ ] **Step 1: 60-second gameplay test**

`make run`. Play for 60+ seconds without dying. Watch for:
- Recycle frames produce no visible pause (white band < 1 scanline).
- Pipe positions correct after each recycle (cap and body both at the right row).
- A/B row-parity dithering on pipe edges still visible (look closely at non-city pipe rows — should see fine checker pattern on the pipe's right edge that wasn't there before this work? It existed before; verify it still does.).

- [ ] **Step 2: Profiler band confirmation**

In Fuse, observe the border colours during a recycle frame. Sequence should be:
- RED (very brief) → BLUE → GREEN → WHITE (very brief, < 1 scanline) → CYAN (idle, most of the frame).

If WHITE extends through visible area: the configure_pipe_slots cost overran. Profile in Fuse's T-state debugger.

- [ ] **Step 3: Edge case — extreme gap_y values**

Temporarily hardcode `pipe_state[0].gap_y = 80` and rebuild. Run and verify city cap_bot renders correctly (cap_bot row = 128, in city band).

Restore original `pipe_state` values, rebuild.

- [ ] **Step 4: Commit any final fixes (if needed)**

```bash
git add src/main.asm
git commit -m "fix: <description>"
```

---

## Self-review checklist (run before considering plan done)

**Spec coverage:**
- §3 fixed grid + SMC role-swap → Tasks 2, 3, 4 ✓
- §4.1 slot grid layout → Task 1 EQUs + Task 4 init ✓
- §4.2 slot templates → Task 4 init + Task 5 configure ✓
- §4.3 cap handlers (HL-only) → Task 2 ✓
- §4.4 per-pipe sparse active list → Task 1 EQUs + Task 5 sublist build ✓
- §5.1 configure_pipe_slots → Task 5 ✓
- §5.2 patch_pipe_targets unchanged → Task 8 step 5 note ✓
- §5.3 update_cap_imm simplified → Task 6 ✓
- §6 init flow → Task 7 step 1 ✓
- §7 deletions → Task 8 ✓
- §9 risks (cap handler SP, mixed slot sizes, city cap_bot, active list order, per-row EXX, cap handler register usage) → addressed in Task 2 (handler shape), Task 3 (debug check), Task 7 step 5 (cutover verify), Task 9 step 3 (extreme gap_y test) ✓
- §10 test plan → Task 9 ✓

**Placeholder scan:**
- Task 4 has "Engineer: implement city emit logic" — flagged as engineer note with reference to gen_pipe_program's .emit_city_body. Engineer fills in following the explicit byte template.
- Task 5 has "Engineer: implement" notes for city variants of body/skip/cap_top/cap_bot — same pattern, explicit references.
- Task 5 pipe×224 math — flagged for replacement with lookup table; the corrected code is given.
- No other vague "TBD" or "implement later" remains.

**Type / symbol consistency:**
- Cap handler label naming: `cap_top_handler_pipe_N`, `cap_top_handler_pipe_N_target`, `cap_top_handler_pipe_N_bc`, `cap_top_handler_pipe_N_de` consistently used in Tasks 2, 5, 6.
- SMC label tables: `cap_top_handler_addrs`, `cap_top_target_imm_addrs`, `cap_top_bc_imm_addrs`, `cap_top_de_imm_addrs` (and `cap_bot_*` equivalents) defined in Task 2, used in Tasks 5 and 6.
- `configure_pipe_slots` signature consistent: A=pipe, E=new_gap_y across Tasks 5 and 7.
- EQUs `SLOT_GRID_BASE`, `SLOT_GRID_NORMAL_BASE`, `SLOT_GRID_CITY_BASE`, `NORMAL_ROW_STRIDE`, `CITY_ROW_STRIDE`, `NORMAL_SLOT_STRIDE`, `CITY_SLOT_STRIDE` defined Task 1, used Tasks 3, 4, 5.
