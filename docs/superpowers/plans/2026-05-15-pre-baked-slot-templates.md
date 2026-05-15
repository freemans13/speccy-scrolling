# Pre-Baked Slot Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `configure_pipe_slots` with a pre-baked-template approach that drops the recycle-frame cost from ~44 k T-states to ~30 k T-states, eliminating the periodic 25 Hz jerk visible during gameplay.

**Architecture:** At boot, populate a 1098-byte template store at `$C000` containing (a) one all-body slot template for `byte_x = 29`, (b) one shared cap+skip overlay block (cap_top + 48 skip + cap_bot, identical for all `gap_y`), and (c) a 12-entry `cap_target_table` of pre-computed cap target imms keyed by `gap_y`. At recycle time, the new `configure_pipe_slots` stamps the body template, overlays the cap block at the gap_y-dependent row offset, patches pipe-specific cap-handler refs, and rebuilds the per-pipe active sublist.

**Tech Stack:** Z80 assembly, sjasmplus toolchain, `make` build, Fuse emulator for empirical verification.

---

## Deviation From Spec

The spec describes 12 cap_blocks (one per gap_y value). Inspection shows the block content is identical for all gap_y values — only the row offset where the block gets stamped depends on gap_y. The plan uses a **single shared `cap_block` of 250 bytes** rather than 12 × 250 bytes. Total template store is **1098 bytes** instead of 3848. Semantically identical, simpler, ~3 KB more RAM headroom.

---

## File Structure

All work is in `src/main.asm`. No new files; no new build targets.

| What | Where |
|------|-------|
| New EQUs (template addresses) | Insert into the EQU block at the top of `src/main.asm`, near `SLOT_ADDR_TABLE` declarations (~line 45–55) |
| New `build_slot_templates` routine | Insert after `init_screen_target_table` (currently at line 1046), before `init_pipes` (line 1065) |
| `call build_slot_templates` | Insert in `start` routine, after `call backup_base_attrs`, before `call init_pipes` |
| Replaced `configure_pipe_slots` body | Replace lines 500..894 (entire current routine including post_loop + cps_emit_body subroutine) |
| Deleted scratch vars (`cps_row_start`, `cps_row_end`, `cps_active_save`) | In the cps_* scratch block (currently ~line 955–1015) |

---

## Task 1: Add template-store EQUs

**Files:**
- Modify: `src/main.asm` near line 45 (slot-grid layout EQU block)

- [ ] **Step 1: Read current EQU block to find insertion point**

Run: `grep -n 'SLOT_ADDR_TABLE' src/main.asm | head -3`

Expected output around: `45:SLOT_ADDR_TABLE        EQU $F440`

- [ ] **Step 2: Add the template-store EQUs**

Insert this block immediately BEFORE the `; ─── Pre-computed slot addresses ───` comment (which precedes `SLOT_ADDR_TABLE`):

```asm
; ─── Slot-grid template store (init-time, then read-only) ─────────
; Single cap_block content is identical for every gap_y (only the
; stamp offset varies), so we share one 250-byte block. Total store:
;   BODY_TEMPLATE       800 bytes  (160 rows × 5 bytes, byte_x=29 body slots)
;   CAP_BLOCK           250 bytes  (50 rows × 5 bytes: cap_top + 48 skip + cap_bot)
;   CAP_TARGET_TABLE     48 bytes  (12 gap_y entries × 4 bytes:
;                                    word(cap_top_target), word(cap_bot_target))
TEMPLATE_BASE          EQU $C000
BODY_TEMPLATE          EQU TEMPLATE_BASE                  ; $C000..$C31F
CAP_BLOCK              EQU BODY_TEMPLATE + 800            ; $C320..$C419
CAP_TARGET_TABLE       EQU CAP_BLOCK + 250                ; $C41A..$C449
TEMPLATE_END           EQU CAP_TARGET_TABLE + 48          ; $C44A
```

- [ ] **Step 3: Build and verify clean assembly**

Run: `make`

Expected output ending with: `Errors: 0, warnings: 0, compiled: N lines, work time: ...`

If there are errors, the EQU expressions are wrong — fix and re-run.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
add: template-store EQUs for pre-baked slot grid

TEMPLATE_BASE..TEMPLATE_END at $C000..$C44A reserves 1098 bytes
in the freed BG_BUFFER region for body/cap/cap_target_table.
Constants only — no runtime change yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `build_slot_templates`

**Files:**
- Modify: `src/main.asm` between `init_screen_target_table` (line 1046) and `init_pipes` (line 1065)

- [ ] **Step 1: Locate insertion point**

Run: `grep -n '^init_screen_target_table:\|^init_pipes:' src/main.asm`

Expected output:
```
1046:init_screen_target_table:
1065:init_pipes:
```

The routine should be inserted between the end of `init_screen_target_table` (its `ret`) and the comment block before `init_pipes`.

- [ ] **Step 2: Find exact end of `init_screen_target_table`**

Run: `awk 'NR>=1046 && NR<=1066' src/main.asm`

Confirm the `ret` line, then find the blank/comment lines before `init_pipes`. The new routine inserts after the `ret` of `init_screen_target_table` and before the `;------` separator above `init_pipes`.

- [ ] **Step 3: Insert `build_slot_templates`**

Insert this routine (full body) at the identified insertion point:

```asm
;----------------------------------------------------------------
; build_slot_templates — one-shot init builder for the template store.
; Walks line_table to populate:
;   BODY_TEMPLATE:    160 rows × ($31, lo+32, hi, $D5, $C5) for byte_x=29
;   CAP_BLOCK:         50 rows: cap_top stub, 48 skip rows, cap_bot stub
;   CAP_TARGET_TABLE:  12 (gap_y) entries × (cap_top_target, cap_bot_target)
;
; Called once at boot, BEFORE init_pipes. Cost ~80k T-states, run-once.
; Clobbers AF, BC, DE, HL, IX.
;----------------------------------------------------------------
build_slot_templates:
        ; ─── Fill BODY_TEMPLATE: 160 rows × 5 bytes ─────────────────
        ld      hl, line_table
        ld      de, BODY_TEMPLATE
        ld      b, GROUND_TOP                   ; B = row counter (160)
.bst_body_lp:
        ld      a, $31                          ; opcode: ld sp, nn
        ld      (de), a
        inc     de
        ld      a, (hl)                         ; line_table[R].lo
        add     a, 32                           ; +32 for byte_x=29 (29+3 offset)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)                         ; line_table[R].hi
        adc     a, 0                            ; carry from +32
        ld      (de), a
        inc     de
        inc     hl
        ld      a, $D5                          ; opcode: push de
        ld      (de), a
        inc     de
        ld      a, $C5                          ; opcode: push bc
        ld      (de), a
        inc     de
        djnz    .bst_body_lp

        ; ─── Fill CAP_BLOCK: 50 rows × 5 bytes ───────────────────
        ; Row 0 (cap_top): $C3, 0, 0, 0, 0  (JP nn ; nop ; nop — handler addr patched at recycle)
        ; Rows 1..48 (skip): 0, 0, 0, 0, 0  (5 NOPs)
        ; Row 49 (cap_bot): $C3, 0, 0, 0, 0
        ld      hl, CAP_BLOCK
        ld      (hl), $C3                       ; cap_top stub
        inc     hl
        ld      b, 4                            ; remaining cap_top bytes (0, 0, 0, 0)
.bst_cap_top_zero:
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_top_zero
        ; 48 skip rows × 5 bytes = 240 zero bytes
        ld      b, 240
.bst_cap_skip_lp:
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_skip_lp
        ; cap_bot stub
        ld      (hl), $C3
        inc     hl
        ld      b, 4
.bst_cap_bot_zero:
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_bot_zero

        ; ─── Fill CAP_TARGET_TABLE: 12 entries × 4 bytes ──────────
        ; For each gap_y in {8, 16, 24, ..., 96}:
        ;   word(line_table[gap_y - 1] + 32)   = cap_top_target
        ;   word(line_table[gap_y + 48] + 32)  = cap_bot_target
        ld      ix, CAP_TARGET_TABLE
        ld      b, 1                            ; B = gap_y index 1..12
.bst_ctt_lp:
        push    bc                              ; preserve B (outer counter)

        ; Compute gap_y = B * 8
        ld      a, b
        rlca
        rlca
        rlca                                    ; A = B * 8 (B is in 1..12, so A in 8..96)

        ; cap_top_target: read line_table[gap_y - 1], add 32
        dec     a                               ; A = gap_y - 1
        push    af                              ; save (we'll need gap_y - 1 if reused; actually no, just for re-use)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = line_addr
        ld      a, e
        add     a, 32
        ld      (ix+0), a
        ld      a, d
        adc     a, 0
        ld      (ix+1), a
        pop     af                              ; (not actually needed for cap_bot — recompute)

        ; cap_bot_target: read line_table[gap_y + 48] = line_table[(gap_y - 1) + 49]
        pop     bc                              ; restore B
        push    bc
        ld      a, b
        rlca
        rlca
        rlca                                    ; A = B * 8 = gap_y
        add     a, 48                           ; A = gap_y + 48 (= cap_bot_row)
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      a, e
        add     a, 32
        ld      (ix+2), a
        ld      a, d
        adc     a, 0
        ld      (ix+3), a

        ; Advance IX by 4 to next entry
        ld      de, 4
        add     ix, de

        pop     bc                              ; restore B
        inc     b
        ld      a, b
        cp      13                              ; loop while B in 1..12
        jr      nz, .bst_ctt_lp

        ret
```

- [ ] **Step 4: Build and verify clean assembly**

Run: `make`

Expected: `Errors: 0, warnings: 0, ...`

Game behavior unchanged — `build_slot_templates` is not called yet.

- [ ] **Step 5: Smoke-test that the game still runs**

Run: `make run`

Expected: game launches, scrolls, the existing scroll-jerk behavior is unchanged. Quit Fuse.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
add: build_slot_templates routine (init-time template builder)

Populates BODY_TEMPLATE (800 B), CAP_BLOCK (250 B), and
CAP_TARGET_TABLE (48 B) at boot. Not called yet — wiring follows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `build_slot_templates` into `start`

**Files:**
- Modify: `src/main.asm` `start` routine (currently around line 90–110)

- [ ] **Step 1: Locate `start` and find the insertion point**

Run: `grep -n 'call.*backup_base_attrs\|call.*init_pipes' src/main.asm | head -4`

Expected output around:
```
N:        call    backup_base_attrs
M:        call    init_pipes
```

The new call inserts between these two lines.

- [ ] **Step 2: Insert `call build_slot_templates`**

Edit `src/main.asm`: find the existing two lines
```asm
        call    backup_base_attrs       ; snapshot ATTRS → BACKUP_ATTRS (no pipes)
        call    init_pipes              ; draws pipes (pixels) — attrs still base
```

Insert one line between them:

```asm
        call    backup_base_attrs       ; snapshot ATTRS → BACKUP_ATTRS (no pipes)
        call    build_slot_templates    ; populate template store at $C000
        call    init_pipes              ; draws pipes (pixels) — attrs still base
```

- [ ] **Step 3: Build and verify**

Run: `make`

Expected: clean build.

- [ ] **Step 4: Visual smoke-test that the game still runs**

Run: `make run`

Expected: the game still runs identically to before. `build_slot_templates` now runs at boot but the templates aren't consumed yet (existing `configure_pipe_slots` is still in use). Confirm no boot crash, pipes render, scroll works.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
wire: call build_slot_templates from start

Runs the template builder once at boot, before init_pipes.
Templates are populated but not yet consumed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replace `configure_pipe_slots` body with template-based version

This is the substantive change. It replaces the band-loop body of `configure_pipe_slots` (lines 500–894, including `cps_emit_body`) with template stamp + cap-block overlay + cap-handler patches + active-list rebuild.

**Files:**
- Modify: `src/main.asm` lines 500..894 (entire `configure_pipe_slots` body up to and including `cps_emit_body`)

- [ ] **Step 1: Locate exact range to replace**

Run: `grep -n '^configure_pipe_slots:\|^cps_emit_body:\|^compute_next_slot:' src/main.asm`

Expected output around:
```
500:configure_pipe_slots:
896:cps_emit_body:
950:compute_next_slot:
```

Range to replace: from line 500 (`configure_pipe_slots:` label) up to but NOT including line 950 (`compute_next_slot:`). The `compute_next_slot` helper is still needed.

- [ ] **Step 2: Find the last `ret` of `cps_emit_body`**

Run: `awk 'NR>=940 && NR<=950 {print NR": "$0}' src/main.asm`

Note the line number of the `ret` ending `cps_emit_body`. The blank line + `;------` separator after it is the boundary; `compute_next_slot:` starts after.

- [ ] **Step 3: Replace lines 500..(last cps_emit_body ret + blank line) with the new routine**

Replace the entire range (configure_pipe_slots prologue + bands + post_loop + cps_emit_body) with the following single new routine:

```asm
;----------------------------------------------------------------
; configure_pipe_slots — template-based recycle/init configure.
; Stamps BODY_TEMPLATE then overlays CAP_BLOCK at the gap_y offset,
; patches pipe-specific cap-handler refs and imms, and rebuilds the
; pipe's active sublist.
;
; In:  A = pipe (0..2)
;      E = gap_y (multiple of 8 in 8..96)
;     B, C = ignored (kept for caller-compat with prior signature)
; Clobbers: AF, BC, DE, HL, IX, IY.
;
; Recycle cost: ~30k T-states (down from ~44k pre-template).
;----------------------------------------------------------------
configure_pipe_slots:
        ld      (cps_pipe), a
        ld      a, e
        ld      (cps_gap_y), a

        ; cap_top_row = gap_y - 1; cap_bot_row = gap_y + PIPE_GAP
        dec     a
        ld      (cps_cap_top_row), a
        ld      a, e
        add     a, PIPE_GAP
        ld      (cps_cap_bot_row), a

        ; byte_x = pipe_state[pipe*2]
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, pipe_state
        add     a, l
        ld      l, a
        jr      nc, .cps_bx_nc
        inc     h
.cps_bx_nc:
        ld      a, (hl)
        ld      (cps_byte_x), a

        ; ─── Step 1: stamp BODY_TEMPLATE → slot column for this pipe ─
        ; DE = slot[0][pipe] = SLOT_GRID_BASE + 1 + pipe*5
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e                            ; A = pipe*5
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = slot[0][pipe]
        ld      hl, BODY_TEMPLATE
        ld      b, GROUND_TOP                   ; 160 rows
.cps_body_stamp_lp:
        ; Copy 5 bytes from (HL) to (DE)
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ; Advance DE by SLOT_ROW_STRIDE - 5 = 11 to next row's same pipe slot
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 5
        add     hl, de
        ex      de, hl
        pop     hl
        djnz    .cps_body_stamp_lp

        ; ─── Step 2: stamp CAP_BLOCK at slot[cap_top_row][pipe] ─────
        ; DE = slot[cap_top_row][pipe] = SLOT_GRID_BASE + 1 + cap_top_row*16 + pipe*5
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = cap_top_row * 16
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e                            ; A = pipe*5
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = slot[cap_top_row][pipe]
        ld      hl, CAP_BLOCK
        ld      b, 50                           ; 50 rows in cap block
.cps_cap_stamp_lp:
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 5
        add     hl, de
        ex      de, hl
        pop     hl
        djnz    .cps_cap_stamp_lp

        ; ─── Step 3: patch cap-slot handler addresses (pipe-specific) ─
        ; slot[cap_top_row][pipe] +1..+2 := cap_top_handler_pipe_<pipe>
        ; slot[cap_bot_row][pipe] +1..+2 := cap_bot_handler_pipe_<pipe>

        ; cap_top: HL = slot[cap_top_row][pipe] + 1
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e                            ; A = pipe*5
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 2          ; +1 ($31 byte) + 1 (we want target byte)
        add     hl, de                          ; HL = slot[cap_top_row][pipe] + 1
        ; Look up cap_top_handler_pipe_<pipe> from cap_top_handler_addrs[pipe]
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_top_handler_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_ctp_nc
        inc     d
.cps_ctp_nc:
        ld      a, (de)
        ld      (hl), a                         ; write handler.lo
        inc     hl
        inc     de
        ld      a, (de)
        ld      (hl), a                         ; write handler.hi

        ; cap_bot: HL = slot[cap_bot_row][pipe] + 1
        ld      a, (cps_cap_bot_row)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 2
        add     hl, de
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_bot_handler_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_cbp_nc
        inc     d
.cps_cbp_nc:
        ld      a, (de)
        ld      (hl), a
        inc     hl
        inc     de
        ld      a, (de)
        ld      (hl), a

        ; ─── Step 4: patch cap-handler target imms from CAP_TARGET_TABLE ─
        ; Entry index = gap_y/8 - 1. Each entry is 4 bytes:
        ;   [+0..+1] cap_top_target, [+2..+3] cap_bot_target
        ld      a, (cps_gap_y)
        rrca
        rrca
        rrca                                    ; A = gap_y / 8
        and     $0F                             ; mask off rotated bits
        dec     a                               ; A = index (0..11)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl                          ; index * 4
        ld      de, CAP_TARGET_TABLE
        add     hl, de                          ; HL → entry

        ; Patch cap_top_handler_pipe_<pipe>_target
        ; (= contents of cap_top_target_imm_addrs[pipe])
        ld      a, (cps_pipe)
        add     a, a
        push    hl                              ; save entry pointer
        ld      de, cap_top_target_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_cttgt_nc
        inc     d
.cps_cttgt_nc:
        ld      a, (de)
        ld      c, a
        inc     de
        ld      a, (de)
        ld      b, a                            ; BC = address of cap_top_handler_pipe_<pipe>_target imm
        pop     hl                              ; restore entry pointer
        ld      a, (hl)
        ld      (bc), a                         ; write lo
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a                         ; write hi
        inc     hl                              ; HL now points at entry+2 (cap_bot)

        ; Patch cap_bot_handler_pipe_<pipe>_target
        ld      a, (cps_pipe)
        add     a, a
        push    hl
        ld      de, cap_bot_target_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_cbtgt_nc
        inc     d
.cps_cbtgt_nc:
        ld      a, (de)
        ld      c, a
        inc     de
        ld      a, (de)
        ld      b, a
        pop     hl
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; ─── Step 5: patch cap-handler _next imms via compute_next_slot ─
        ld      a, (cps_cap_top_row)
        call    compute_next_slot               ; HL = next slot address
        push    hl
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_top_next_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_ctn_nc
        inc     d
.cps_ctn_nc:
        ld      a, (de)
        ld      c, a
        inc     de
        ld      a, (de)
        ld      b, a
        pop     hl
        ld      a, l
        ld      (bc), a
        inc     bc
        ld      a, h
        ld      (bc), a

        ld      a, (cps_cap_bot_row)
        call    compute_next_slot
        push    hl
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_bot_next_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_cbn_nc
        inc     d
.cps_cbn_nc:
        ld      a, (de)
        ld      c, a
        inc     de
        ld      a, (de)
        ld      b, a
        pop     hl
        ld      a, l
        ld      (bc), a
        inc     bc
        ld      a, h
        ld      (bc), a

        ; ─── Step 6: rebuild active sublist for this pipe ─────────
        ; IX = sublist start (ACTIVE_PIPE_<pipe>)
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cps_sublist_base_table
        add     a, l
        ld      l, a
        jr      nc, .cps_sl_nc
        inc     h
.cps_sl_nc:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        push    de
        pop     ix                              ; IX = ACTIVE_PIPE_<pipe>

        ; IY = slot[0][pipe], to scan slot first-bytes
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        push    hl
        pop     iy                              ; IY = slot[0][pipe]

        ld      b, 0                            ; B = row counter
.cps_act_lp:
        ld      a, (iy+0)
        or      a
        jr      z, .cps_act_skip                ; zero = skip slot, no entry
        cp      $C3
        jr      z, .cps_act_cap

        ; Body slot: write slot+1 (= iy+1) to (ix), advance ix by 2.
        push    iy
        pop     hl
        inc     hl
        ld      (ix+0), l
        ld      (ix+1), h
        inc     ix
        inc     ix
        jr      .cps_act_advance

.cps_act_cap:
        ; Cap slot: is this cap_top or cap_bot?
        ld      a, b
        ld      hl, cps_cap_top_row
        cp      (hl)
        jr      z, .cps_act_cap_top
        ; cap_bot: write cap_bot_target_imm_addrs[pipe]
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_bot_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_act_cb_nc
        inc     h
.cps_act_cb_nc:
        ld      a, (hl)
        ld      (ix+0), a
        inc     hl
        ld      a, (hl)
        ld      (ix+1), a
        inc     ix
        inc     ix
        jr      .cps_act_advance

.cps_act_cap_top:
        ; cap_top: write cap_top_target_imm_addrs[pipe]
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_top_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_act_ct_nc
        inc     h
.cps_act_ct_nc:
        ld      a, (hl)
        ld      (ix+0), a
        inc     hl
        ld      a, (hl)
        ld      (ix+1), a
        inc     ix
        inc     ix

.cps_act_advance:
.cps_act_skip:
        ld      de, SLOT_ROW_STRIDE
        add     iy, de
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jp      nz, .cps_act_lp

        ; ─── Step 7: store new gap_y back to pipe_state[pipe*2 + 1] ─
        ld      a, (cps_pipe)
        add     a, a
        inc     a                               ; pipe*2 + 1
        ld      hl, pipe_state
        add     a, l
        ld      l, a
        jr      nc, .cps_gap_nc
        inc     h
.cps_gap_nc:
        ld      a, (cps_gap_y)
        ld      (hl), a

        ret
```

- [ ] **Step 4: Build and verify clean assembly**

Run: `make`

Expected: `Errors: 0, warnings: 0, ...`

If errors mention undefined labels (`cps_sublist_base_table`, `cap_*_handler_addrs`, `cap_*_target_imm_addrs`, `cap_*_next_imm_addrs`, `compute_next_slot`, `cps_pipe`, `cps_gap_y`, `cps_byte_x`, `cps_cap_top_row`, `cps_cap_bot_row`, `pipe_state`), those are pre-existing names — verify they weren't accidentally deleted alongside the old `configure_pipe_slots` body.

- [ ] **Step 5: Run and visually verify gameplay**

Run: `make run`

Expected: game launches, pipes render correctly, recycles produce no magenta freeze. Play for ~30 seconds (≥ several recycles, score ≥ 10).

**Specifically check:**
- Pipes look correct (rounded rim caps at top/bottom of gap, body extending above/below).
- Scrolling is visibly smoother than before, especially around when a new pipe enters from the right.
- No frozen-magenta crash.
- Border on recycle frames is no longer dominated by a wide RED band.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
replace: configure_pipe_slots with template-based recycle

Drops recycle cost from ~44 k T-states to ~30 k T-states by stamping
the pre-baked BODY_TEMPLATE + CAP_BLOCK overlay and only patching
pipe-specific cap-handler refs/imms and the active sublist.

Behavior identical; the only observable change is the recycle frame
no longer dominates the border with RED.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Remove dead scratch vars

The new `configure_pipe_slots` does NOT use `cps_row_start`, `cps_row_end`, or `cps_active_save` (these were artifacts of the abandoned split-configure design). Remove them.

**Files:**
- Modify: `src/main.asm` cps_* scratch block (search for the labels)

- [ ] **Step 1: Locate the scratch block**

Run: `grep -n '^cps_row_start:\|^cps_row_end:\|^cps_active_save:' src/main.asm`

Expected output (line numbers may have shifted from earlier tasks):
```
N:cps_row_start:          db 0
M:cps_row_end:            db 0
P:cps_active_save:        dw 0
```

- [ ] **Step 2: Remove the three declarations**

Edit `src/main.asm`: delete the three lines (and any trailing comment line about `cps_active_save` for the split halves).

Specifically, in the cps_* scratch block, the three lines to remove (look for adjacent context):

```asm
cps_row_start:          db 0
cps_row_end:            db 0
```

and:

```asm
; Active-list cursor saved between split halves of configure_pipe_slots.
cps_active_save:        dw 0
```

(Remove the comment too if present.)

- [ ] **Step 3: Build and verify**

Run: `make`

Expected: clean build. If any error mentions `cps_row_start`, `cps_row_end`, or `cps_active_save`, the new `configure_pipe_slots` still references them — go back and remove those refs in Task 4's code.

- [ ] **Step 4: Visual smoke-test**

Run: `make run`

Expected: identical behavior to end of Task 4.

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "$(cat <<'EOF'
cleanup: drop dead cps_row_start/end/active_save vars

These were only used by the abandoned split-configure design. The
template-based configure_pipe_slots does not need them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Empirical verification — score soak

This is the final gate. Confirms the change really does fix the jerk.

- [ ] **Step 1: Run the game and play for sustained play**

Run: `make run`

Play until score ≥ 30 (~5 recycles per pipe × 3 pipes). Keep an eye on:
- **Scrolling smoothness:** the periodic ~25 Hz jerk that motivated this work should be gone. Scrolling should feel uniform.
- **No magenta freeze:** game never locks up on a magenta border.
- **Border pattern on recycle frames:** the wide RED band that used to dominate recycle frames should be gone or much narrower. Recycle frames should look like normal frames.

- [ ] **Step 2: Compare against baseline (optional but recommended)**

If desired, use `git stash` to temporarily restore the pre-task-4 state, run `make run`, observe the old jerky behavior, then restore changes with `git stash pop`. This makes the improvement objectively obvious.

- [ ] **Step 3: Document any remaining concerns**

If scrolling still feels jerky despite the recycle frame being fixed, the bottleneck is elsewhere (e.g., a different frame type overruns). Note observations and we can iterate.

If the visual is satisfactory, no commit needed — the implementation is complete.

---

## Spec-Coverage Self-Review

- ✅ **12 distinct slot-grid layouts pre-computed:** Implemented as 1 shared `cap_block` + 12-entry `cap_target_table` (the only per-gap_y differences). Documented in deviation section.
- ✅ **Memory layout at $C000..$C44A:** Task 1.
- ✅ **body_template (800 B), cap_block (250 B), cap_target_table (48 B):** Task 2's `build_slot_templates` populates all three.
- ✅ **Boot sequence change (build_slot_templates before init_pipes):** Task 3.
- ✅ **New configure_pipe_slots: stamp + cap overlay + handler patches + imm patches + active rebuild:** Task 4, steps 1–6 in the routine body.
- ✅ **Active list invariant of 112 entries:** Step 6 of new routine produces deterministic 112 via gap_y arithmetic.
- ✅ **Cap-handler race avoided:** new routine runs to completion on a single frame; no mid-state PIPE_PROGRAM call between halves.
- ✅ **init_pipes behavior preserved:** new routine handles the init call exactly like a recycle call (init_pipes' existing loop is untouched).
- ✅ **Empirical testing:** Task 6.
