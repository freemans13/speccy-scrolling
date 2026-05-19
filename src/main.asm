        DEVICE  ZXSPECTRUM48

;----------------------------------------------------------------
; Speccy Flappy Bird — sky/pipes/ground/scoreboard rendering at 50Hz.
;
; Per frame: PIPE_PROGRAM (SMC slot grid at $DB00) emits all 160 pipe-band
; scan lines via stack-blast pushes, then bird + ground + scoreboard.
; Pipes scroll by 2 px per frame; on each phase wrap, byte_x decrements
; and per-pipe slot templates are reconfigured.
;----------------------------------------------------------------

NUM_PIPES   EQU 4
; Phase 3: only 3 pipes are "active" (rendered + scrolled). Pipe 3 is the
; "preparing" pipe — its slot column is dormant (all-NOPs) until Phase 5 swap.
; Routines that iterate active pipes use ACTIVE_PIPES, not NUM_PIPES.
ACTIVE_PIPES EQU 3
PIPE_GAP    EQU 48

BIRD_X      EQU 8                       ; fixed col (= 64 px from left)
BIRD_LINES  EQU 16
GRAVITY     EQU 64                      ; vy += GRAVITY per frame (16-bit fixed-point)
FLAP_VY     EQU $FD80                   ; signed -640 — single flap rises ~14 px

ATTRS           EQU $5800
BG_BUFFER       EQU $C000
BACKUP_ATTRS    EQU $D800               ; mirror of ATTRS without pipe overlay (768 B)

ATTR_SKY        EQU $28                 ; paper cyan + ink black
ATTR_GROUND     EQU $20                 ; paper green + ink black (ground band, row 20)
ATTR_SCOREBOARD EQU $07                 ; paper black + ink white (rows 21..23)
ATTR_PIPE       EQU $20                 ; paper green + ink black (dynamic, inner pipe cells)
ATTR_BIRD       EQU $70                 ; bright yellow paper + black ink (col 8 only, centred under sprite)
ATTR_BUFFER     EQU $2D                 ; paper cyan + ink cyan — invisible buffer cols (0-3, 28-31)
GROUND_TOP      EQU 160                 ; first scan line of ground band — pipes stop here
SCORE_TOP       EQU 168                 ; first scan line of scoreboard band (= ground+8)

; ─── Slot grid layout (fixed-slot dispatch) ──────────────────────
; Phase 1: 6-byte normal slot template:
;   ld sp,target ; push hl ; push de ; push bc  (HL=0 → trailing-zero pair)
; The epilogue sits immediately after row 159's last slot so PIPE_PROGRAM
; falls straight through into `ld sp,(saved_sp) ; ret` with no NOP slide.
SLOT_GRID_BASE         EQU $DB00
SLOT_GRID_END          EQU SLOT_GRID_BASE + 160 * SLOT_ROW_STRIDE   ; Phase 3: $DB00 + 160*32 = $EF00
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

; Phase 3: 1 EXX + 4*6-byte slots = 25 bytes/row; pad to 32 for fast row << 5 indexing.
; Slot format: $31 lo hi $E5 $D5 $C5  =  ld sp,target ; push hl ; push de ; push bc
; HL is set to $0000 once at PIPE_PROGRAM entry; the extra push HL writes the
; trailing-zero pair that replaces the old deferred-clear mechanism.
SLOT_ROW_STRIDE        EQU 32          ; 1 (exx) + 4*6 + 7 pad (= power-of-2-ish for row*32 = row << 5)
SLOT_STRIDE            EQU 6

; ─── Slot-grid template store (init-time, then read-only) ─────────
; Single cap_block content is identical for every gap_y (only the
; stamp offset varies), so we share one 300-byte block. Total store:
;   BODY_TEMPLATE       960 bytes  (160 rows × 6 bytes, byte_x=29 body slots)
;   CAP_BLOCK           300 bytes  (50 rows × 6 bytes: cap_top + 48 skip + cap_bot)
;   CAP_TARGET_TABLE     48 bytes  (12 gap_y entries × 4 bytes:
;                                    word(cap_top_target), word(cap_bot_target))
TEMPLATE_BASE          EQU $C000
BODY_TEMPLATE          EQU TEMPLATE_BASE                  ; $C000..$C3BF (Phase 1: 160*6=960 bytes)
CAP_BLOCK              EQU BODY_TEMPLATE + 960            ; Phase 1: body=160*6=960 bytes → cap_block starts here
CAP_TARGET_TABLE       EQU CAP_BLOCK + 300                ; Phase 1: 50 rows × 6 bytes/slot
TEMPLATE_END           EQU CAP_TARGET_TABLE + 48

; ─── Pre-computed slot addresses ─────────────────────────────────
SLOT_ADDR_TABLE        EQU $F440       ; Phase 3: 640 entries × 2 B = 1280 B = $500
SLOT_ADDR_TABLE_END    EQU $F940

; ─── Active list (per-pipe sublists) ─────────────────────────────
; Phase 3: 4 pipes × 112 entries × 2 B = 896 B total.
ACTIVE_PIPE_0          EQU $F940       ; (moved up to clear $FC80+ for stack growth)
ACTIVE_PIPE_1          EQU ACTIVE_PIPE_0 + 224
ACTIVE_PIPE_2          EQU ACTIVE_PIPE_1 + 224
ACTIVE_PIPE_3          EQU ACTIVE_PIPE_2 + 224       ; Phase 3: NEW
ACTIVE_LIST_END        EQU ACTIVE_PIPE_3 + 224       ; = $FCC0
ACTIVE_COUNT           EQU 448         ; 4 × 112

ACTIVE_LIST_NEW        EQU ACTIVE_PIPE_0
ACTIVE_COUNT_NEW       EQU $FCC0       ; 2 B counter (moved with ACTIVE_LIST_END)

        ORG $8000

start:
        di
        ld      sp, $8000
        ld      a, 5
        out     ($fe), a
        call    paint_attrs
        call    init_background
        call    refill_base_attrs
        call    backup_base_attrs       ; snapshot ATTRS → BACKUP_ATTRS (no pipes)
        call    build_slot_templates    ; populate template store at $C000
        call    init_pipes              ; draws pipes (pixels) — attrs still base
        call    init_bird
        call    apply_pipe_attrs        ; overlay ATTR_PIPE at initial pipe positions
        im      1
        ei

main_loop:
        halt
        di
        ld      a, 2                    ; PROFILE: RED = top blanking
        out     ($fe), a
        ; Phase 2: bird ops run BEFORE PIPE_PROGRAM in top blanking.
        ; All bird writes complete before raster reaches row 0, so the
        ; bird is visible same-frame at every Y with no flicker.
        ; PIPE_PROGRAM still has ~8 k T head start over the raster.
        call    restore_bird_bg
        call    restore_bird_attrs
        call    read_input
        call    update_bird
        call    advance_bird_anim
        call    draw_bird
        call    paint_bird_attrs
        ld      a, 3                    ; PROFILE: MAGENTA = PIPE_PROGRAM
        out     ($fe), a
        call    frame_update
        ld      a, 7                    ; PROFILE: WHITE = state prep
        out     ($fe), a
        call    do_white_work
        ld      a, 5                    ; PROFILE: CYAN = update_cap_imm_v2
        out     ($fe), a
        call    update_cap_imm_v2
        ld      a, 6                    ; PROFILE: YELLOW = prep_step
        out     ($fe), a
        ; Skip prep_step on swap frame to free ~2k T budget; do_swap already
        ; reset prep state, so missing one frame just delays prep by 1 frame
        ; (still well under the 28-frame swap interval at 10 rows/frame).
        ld      a, (do_swap_fired)
        or      a
        jr      nz, .skip_prep_step
        call    prep_step
        jr      .post_prep_step
.skip_prep_step:
        xor     a
        ld      (do_swap_fired), a
.post_prep_step:
        ld      a, 0                    ; PROFILE: BLACK = idle before halt
        out     ($fe), a
        ei
        jr      main_loop

;----------------------------------------------------------------
; do_white_work: state-prep work that used to be in frame_update's WHITE
; band. advance_phase × 2 + (wrap_byte_x — now WITHOUT clear) + restore_trailing.
;----------------------------------------------------------------
do_white_work:
        call    advance_phase
        call    advance_phase
        ld      a, (wrap_pending)
        or      a
        ret     z
        xor     a
        ld      (wrap_pending), a
        jp      restore_trailing_pipe_attrs

;----------------------------------------------------------------
phase:      db 0
saved_sp:   dw 0
saved_sp_inner: dw 0                    ; second save slot — inner CALL inside
                                        ; the SP-hijacked line loop swaps SP
                                        ; back to caller stack so the return
                                        ; address doesn't overwrite line_table.
ground_iy_save: dw 0

pipe_state:
        ; Phase 3: 4 pipes. 3 active + 1 preparing.
        ; Initial spacing: 29, 22, 15, 8 (every 7 byte_x). Last entry starts as
        ; the "preparing" slot — see prep_pipe_idx.
        db 29, 64                       ; pipe 0: just entering from right buffer
        db 22, 40                       ; pipe 1
        db 15, 88                       ; pipe 2
        db  8, 24                       ; pipe 3 (Phase 3 starts inert)

; Scratch words for cap_bot's BC/DE restore. Populated by redraw_pipes_v2 at frame entry.
body_a_bc:      dw 0
body_a_de:      dw 0
body_b_bc:      dw 0
body_b_de:      dw 0

; Scratch bytes for update_cap_imm_v2's phase-shifted cap values
cap_L_temp:     db 0
cap_M1_temp:    db 0
cap_M2_temp:    db 0
cap_R_temp:     db 0

; Score state: +1 each time a pipe's right edge clears the bird's left edge.
; pipe_scored is 1 once the bird has passed that pipe this cycle; reset when
; the pipe wraps back to the right of the screen so it can score again.
score:        dw 0
score_last:   dw $FFFF                  ; force first render
pipe_scored:  db 0, 0, 0, 0            ; one byte per pipe (NUM_PIPES=4)
scroll_extra: db 0                      ; mod-5 counter for 1.2 px/frame avg
wrap_pending:  db 0                      ; set when a wrap happened this frame
; Phase 5: pending_regen, recycled_pipe_idx and patch_pending removed.
prep_pipe_idx:   db 3                  ; Phase 3: pipe 3 starts as the preparing column
; Bug 2 fix: do_swap fallback defers prep_pipe_idx update until after wrap_byte_x loop.
; 0 = no pending swap; N+1 = update prep_pipe_idx to N after loop exits.
prep_pipe_swap_pending: db 0
; Phase 4: incremental-prepare state machine variables.
; prep_phase 0..6 = which configure sub-step we are on; 7 = done.
; prep_row  0..N  = current row within the current phase (phases 0, 2 use rows;
;                   phases 1 uses rows into cap range; phase 6 uses entry index).
; prep_gap_y      = gap_y for pipe 3 (set at game start from pipe_state[3*2+1]).
prep_phase:      db 0
prep_row:        db 0
prep_gap_y:      db 8

; 16-bit Galois LFSR for randomising gap_y on each pipe wrap. Period 65535.
rand_state:   dw $ABCD

; Body bitmap A — 24-px wide. Pattern $EA $00 $57 pre-shifted to 4 bytes/phase.
;   Used for EVEN scan lines.
;     px  0..1   = 2-px outline (1 1)
;     px  2..7   = 6-px dither A (1 0 1 0 1 0)
;     px  8..15  = 8-px clear middle (paper green shows through)
;     px 16..21  = 6-px dither A (0 1 0 1 0 1)
;     px 22..23  = 2-px outline (1 1)
pipe_bitmap:
        db $00, $EA, $00, $57           ; phase 0
        db $01, $D4, $00, $AE           ; phase 1
        db $03, $A8, $01, $5C           ; phase 2
        db $07, $50, $02, $B8           ; phase 3
        db $0E, $A0, $05, $70           ; phase 4
        db $1D, $40, $0A, $E0           ; phase 5
        db $3A, $80, $15, $C0           ; phase 6
        db $75, $00, $0B, $80           ; phase 7

; Body bitmap B — pattern $EA $00 $AB pre-shifted. Alternates with A on
; byte 2 AND byte 3 → 1-row checker dither on the pipe's right side.
pipe_bitmap_b:
        db $00, $EA, $00, $AB           ; phase 0
        db $01, $D4, $01, $56           ; phase 1
        db $03, $A8, $02, $AC           ; phase 2
        db $07, $50, $05, $58           ; phase 3
        db $0E, $A0, $0A, $B0           ; phase 4
        db $1D, $40, $15, $60           ; phase 5
        db $3A, $80, $2A, $C0           ; phase 6
        db $75, $00, $55, $80           ; phase 7

; Cap design: body pattern for most rows + 1 rim line at the gap-facing edge.
; The rim is pattern $7F $FF $FE — 24-px solid black bar with 1-px chamfered
; corners. Chamfer at byte_x bit 7 (= left corner) + byte_x+2 bit 0 (= right
; corner) gives "rounded" look.
cap_rounded_bitmap:
        db $00, $7F, $FF, $FE           ; phase 0
        db $00, $FF, $FF, $FC           ; phase 1
        db $01, $FF, $FF, $F8           ; phase 2
        db $03, $FF, $FF, $F0           ; phase 3
        db $07, $FF, $FF, $E0           ; phase 4
        db $0F, $FF, $FF, $C0           ; phase 5
        db $1F, $FF, $FF, $80           ; phase 6
        db $3F, $FF, $FF, $00           ; phase 7

; Bird state
bird_y:             dw $5000            ; 16-bit Y, high = pixel, low = fraction (start ~80)
bird_vy:            dw $0000            ; 16-bit signed velocity
bird_old_y:         db 0
bird_old_y_valid:   db 0
; Per-bird-line pipe coverage mask. Bit 0 = col 8 covered by some pipe
; pixel at this row; bit 1 = col 9 covered. Filled in by compute_bird_overlap
; each frame so the (now post-pipe) restore_bird_bg skips cells where a
; pipe pixel sits — keeps pipe pixels intact instead of stamping bg over them.
bird_overlap:       ds BIRD_LINES, 0

; Yellow-paper attr cell — 1 char cell at col 8 only, snapped to the screen
; char row containing the bird's vertical centre. Col 9 stays cyan so the
; beak silhouette reads as solid black against the sky. Pipe-cap technique:
; sprite rows on the cyan char rows above/below the yellow cell are forced
; ink (sprite=1) inside the silhouette, masking the cyan paper.
bird_attr_y:        db 0
bird_attr_valid:    db 0
bird_attr_save:     db 0                ; single yellow cell (col 8)

; Bird wing animation — 4 frames cycling 0→1→2→3→0, one phase step every
; BIRD_ANIM_RATE frames. bird_sprite_ptr always points at the current
; frame's data; draw_bird reads it instead of a fixed label.
BIRD_ANIM_RATE      EQU 4
BIRD_FRAME_BYTES    EQU 96              ; 16 rows × 6 bytes/row (3 cells × 2)
bird_anim_tick:     db 0
bird_anim_phase:    db 0
bird_sprite_ptr:    dw bird_sprite_f0

; Bird sprite — black ink drawing, exported from Piskel.
; Pre-shifted 4 px LEFT so the 16-px-wide sprite spans 3 char cells (cols 7,8,9)
; instead of 2. The yellow paper attr cell at col 8 then sits centred under the
; sprite (4 px of sprite to its left in col 7, 4 px to its right in col 9), so
; the colour-clash boundary is the same on both sides → reads as deliberate.
;
; Stored as 6 bytes/row: mask_c7, sprite_c7, mask_c8, sprite_c8, mask_c9, sprite_c9.
; draw_bird does  screen = (screen AND inv_mask) OR sprite.
; inv_mask = 0 inside the row's silhouette (clear bg, then OR sprite ink),
; inv_mask = 1 outside (keep bg = sky / pipe pixels show through).

bird_sprite_f0:
        db $FF, $00, $00, $FF, $FF, $00     ; row  0 ....########....
        db $FC, $03, $00, $FF, $7F, $80     ; row  1 ..###########...
        db $F8, $07, $00, $EE, $3F, $C0     ; row  2 .######.###.##..
        db $F0, $0F, $00, $D4, $3F, $40     ; row  3 ######.#.#...#..
        db $F0, $0C, $00, $6C, $1F, $A0     ; row  4 ##...##.##..#.#.
        db $F0, $08, $00, $24, $1F, $A0     ; row  5 #.....#..#..#.#.
        db $F0, $08, $00, $24, $1F, $20     ; row  6 #.....#..#....#.
        db $F0, $08, $00, $A2, $1F, $20     ; row  7 #...#.#...#...#.
        db $F0, $08, $00, $A1, $0F, $F0     ; row  8 #...#.#....#####
        db $F0, $09, $00, $22, $0F, $10     ; row  9 #..#..#...#....#
        db $F0, $08, $00, $25, $0F, $F0     ; row 10 #.....#..#.#####
        db $F0, $0C, $00, $54, $0F, $10     ; row 11 ##...#.#.#.....#
        db $F8, $07, $00, $EA, $0F, $B0     ; row 12 .######.#.#.#.##
        db $FC, $03, $00, $D5, $1F, $E0     ; row 13 ..####.#.#.####.
        db $FE, $01, $00, $FF, $FF, $00     ; row 14 ...#########....
        db $FF, $00, $01, $FE, $FF, $00     ; row 15 ....#######.....

bird_sprite_f1:
        db $FF, $00, $00, $FF, $FF, $00     ; row  0 ....########....
        db $FC, $03, $00, $FF, $7F, $80     ; row  1 ..###########...
        db $F8, $07, $00, $EE, $3F, $C0     ; row  2 .######.###.##..
        db $F0, $0F, $00, $D4, $3F, $40     ; row  3 ######.#.#...#..
        db $F0, $0C, $00, $6C, $1F, $A0     ; row  4 ##...##.##..#.#.
        db $F0, $08, $00, $24, $1F, $A0     ; row  5 #.....#..#..#.#.
        db $F0, $08, $00, $A4, $1F, $20     ; row  6 #...#.#..#....#.
        db $F0, $09, $00, $22, $1F, $20     ; row  7 #..#..#...#...#.
        db $F0, $08, $00, $21, $0F, $F0     ; row  8 #.....#....#####
        db $F0, $0C, $00, $42, $0F, $10     ; row  9 ##...#....#....#
        db $F0, $0B, $00, $85, $0F, $F0     ; row 10 #.###....#.#####
        db $F0, $0D, $00, $54, $0F, $10     ; row 11 ##.#.#.#.#.....#
        db $F8, $06, $00, $AA, $0F, $B0     ; row 12 .##.#.#.#.#.#.##
        db $FC, $03, $00, $D5, $1F, $E0     ; row 13 ..####.#.#.####.
        db $FE, $01, $00, $FF, $FF, $00     ; row 14 ...#########....
        db $FF, $00, $01, $FE, $FF, $00     ; row 15 ....#######.....

bird_sprite_f2:
        db $FF, $00, $00, $FF, $FF, $00     ; row  0 ....########....
        db $FC, $03, $00, $FF, $7F, $80     ; row  1 ..###########...
        db $F8, $07, $00, $EE, $3F, $C0     ; row  2 .######.###.##..
        db $F0, $0F, $00, $D4, $3F, $40     ; row  3 ######.#.#...#..
        db $F0, $0C, $00, $6C, $1F, $A0     ; row  4 ##...##.##..#.#.
        db $F0, $08, $00, $A4, $1F, $A0     ; row  5 #...#.#..#..#.#.
        db $F0, $0B, $00, $24, $1F, $20     ; row  6 #.##..#..#....#.
        db $F0, $0C, $00, $42, $1F, $20     ; row  7 ##...#....#...#.
        db $F0, $0B, $00, $81, $0F, $F0     ; row  8 #.###......#####
        db $F0, $08, $00, $02, $0F, $10     ; row  9 #.........#....#
        db $F0, $0A, $00, $05, $0F, $F0     ; row 10 #.#......#.#####
        db $F0, $0D, $00, $54, $0F, $10     ; row 11 ##.#.#.#.#.....#
        db $F8, $06, $00, $AA, $0F, $B0     ; row 12 .##.#.#.#.#.#.##
        db $FC, $03, $00, $D5, $1F, $E0     ; row 13 ..####.#.#.####.
        db $FE, $01, $00, $FF, $FF, $00     ; row 14 ...#########....
        db $FF, $00, $01, $FE, $FF, $00     ; row 15 ....#######.....

bird_sprite_f3:
        db $FF, $00, $00, $FF, $FF, $00     ; row  0 ....########....
        db $FC, $03, $00, $FF, $7F, $80     ; row  1 ..###########...
        db $F8, $07, $00, $EE, $3F, $C0     ; row  2 .######.###.##..
        db $F0, $0F, $00, $D4, $3F, $40     ; row  3 ######.#.#...#..
        db $F0, $0C, $00, $6C, $1F, $A0     ; row  4 ##...##.##..#.#.
        db $F0, $08, $00, $A4, $1F, $A0     ; row  5 #...#.#..#..#.#.
        db $F0, $0F, $00, $C4, $1F, $20     ; row  6 ######...#....#.
        db $F0, $08, $00, $02, $1F, $20     ; row  7 #.........#...#.
        db $F0, $08, $00, $01, $0F, $F0     ; row  8 #..........#####
        db $F0, $08, $00, $02, $0F, $10     ; row  9 #.........#....#
        db $F0, $0A, $00, $05, $0F, $F0     ; row 10 #.#......#.#####
        db $F0, $0D, $00, $54, $0F, $10     ; row 11 ##.#.#.#.#.....#
        db $F8, $06, $00, $AA, $0F, $B0     ; row 12 .##.#.#.#.#.#.##
        db $FC, $03, $00, $D5, $1F, $E0     ; row 13 ..####.#.#.####.
        db $FE, $01, $00, $FF, $FF, $00     ; row 14 ...#########....
        db $FF, $00, $01, $FE, $FF, $00     ; row 15 ....#######.....

; Ground tiles — 8x8 pattern, 8 phases of horizontal scroll.
;   Row 0:    $FF — solid black top edge.
;   Rows 1..6: "/" diagonal, period 8 (one diagonal slash per tile).
;   Row 7:    $AA / $55 — dotted bottom edge (period 2 horizontally).
; Each phase shifts the diagonal left by 1 px; bits falling off the left
; wrap to bit 0 (since adjacent tiles share the same byte pattern).
ground_tiles:
        db $FF, $01, $02, $04, $08, $10, $20, $AA   ; phase 0
        db $FF, $02, $04, $08, $10, $20, $40, $55   ; phase 1
        db $FF, $04, $08, $10, $20, $40, $80, $AA   ; phase 2
        db $FF, $08, $10, $20, $40, $80, $01, $55   ; phase 3
        db $FF, $10, $20, $40, $80, $01, $02, $AA   ; phase 4
        db $FF, $20, $40, $80, $01, $02, $04, $55   ; phase 5
        db $FF, $40, $80, $01, $02, $04, $08, $AA   ; phase 6
        db $FF, $80, $01, $02, $04, $08, $10, $55   ; phase 7

;----------------------------------------------------------------
paint_attrs:
        ld      hl, ATTRS
        ld      de, ATTRS + 1
        ld      (hl), ATTR_SKY
        ld      bc, 20 * 32 - 1         ; 20 char rows of sky (rows 0..19)
        ldir
        inc     hl
        ld      (hl), ATTR_GROUND
        ld      d, h
        ld      e, l
        inc     de
        ld      bc, 1 * 32 - 1          ; 1 char row of ground (row 20)
        ldir
        inc     hl
        ld      (hl), ATTR_SCOREBOARD
        ld      d, h
        ld      e, l
        inc     de
        ld      bc, 3 * 32 - 1          ; 3 char rows of scoreboard (rows 21..23)
        ldir
        ret

;----------------------------------------------------------------
; init_slot_addr_table: pre-compute slot_addr_table[row][pipe] = byte address
; of the (row, pipe) slot's first byte (the byte AFTER the row's leading EXX).
;
; Layout: SLOT_GRID_BASE + row*32 + 1 + pipe*6 for all 160 rows.  Phase 3
;
; Entry index: row*4 + pipe (16-bit address per entry).  Phase 3: 4 pipes
; Total table size: 640 × 2 = 1280 bytes at SLOT_ADDR_TABLE.
;----------------------------------------------------------------
init_slot_addr_table:
        ld      ix, SLOT_ADDR_TABLE
        ld      b, 0
.row_lp:
        push    bc
        ld      l, b
        ld      h, 0
        add     hl, hl                          ; row*2
        add     hl, hl                          ; row*4
        add     hl, hl                          ; row*8
        add     hl, hl                          ; row*16
        add     hl, hl                          ; row*32 (Phase 3: row << 5)
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = base addr for pipe 0
        ld      c, SLOT_STRIDE

.write_4_pipes:
        ld      b, NUM_PIPES                    ; Phase 3: 4 pipes
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

;----------------------------------------------------------------
; init_pipe_program: emit the initial slot grid into PIPE_PROGRAM
; memory ($DB00+).  Caller must call init_slot_addr_table first
; (this routine assumes the table is already populated).
;
; Walks rows 0..159.  For each row:
;   - Reads slot[row][0] address from SLOT_ADDR_TABLE (entry index
;     row*4, 2-byte little-endian address).   Phase 3: 4 pipes
;   - Writes $D9 (EXX) at (slot[row][0] - 1).
;   - Writes 4 × 6-byte body templates for pipes 0-3.  Phase 3: 4 pipes
;
; After the loop writes the 5-byte epilogue at SLOT_GRID_END:
;   ED 7B lo hi C9  =  ld sp,(saved_sp) ; ret
;
; Scratch: ipp_byte_x (4 bytes) caches byte_x for each pipe so we
; don't touch pipe_state during the inner loop.  Phase 3: 4 bytes
;
; Register usage (outer loop):
;   B  = row (0..159)
;   IY = write cursor (slot[row][0] for each row, advances per pipe)
;   HL = address scratch
;   DE = address scratch / cache_addr
;   C  = pipe index (0..3) in inner loops  Phase 3
;----------------------------------------------------------------
init_pipe_program:
        ; Cache byte_x (first byte of each pipe_state entry).
        ; pipe_state layout: db byte_x, gap_y  for each pipe.
        ld      a, (pipe_state + 0)
        ld      (ipp_byte_x + 0), a
        ld      a, (pipe_state + 2)
        ld      (ipp_byte_x + 1), a
        ld      a, (pipe_state + 4)
        ld      (ipp_byte_x + 2), a
        ld      a, (pipe_state + 6)     ; Phase 3: cache pipe 3 byte_x
        ld      (ipp_byte_x + 3), a

        ld      b, 0                    ; row counter 0..159
.ipp_row_lp:
        push    bc                      ; save B=row

        ; ── Look up slot[row][0] address from SLOT_ADDR_TABLE ─────
        ; Table entry index = row*4 + pipe (pipe=0 here).
        ; Each entry is 2 bytes → byte offset = (row*4)*2 = row*8.
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        add     hl, hl                  ; row*4
        add     hl, hl                  ; row*8
        ld      de, SLOT_ADDR_TABLE
        add     hl, de                  ; HL → table[row*4]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = slot[row][0] address

        ; ── Write EXX ($D9) at (slot_addr - 1) ───────────────────
        dec     de
        ld      a, $D9
        ld      (de), a
        inc     de                      ; DE back to slot[row][0]

        ; Transfer slot cursor to IY
        push    de
        pop     iy                      ; IY = write cursor at slot[row][0]

        ; All 160 rows: 4 × 6-byte body template (Phase 3: 4 pipes)
        ;   $31 lo hi $E5 $D5 $C5  =  ld sp,target ; push hl ; push de ; push bc
        ld      c, 0                    ; pipe index
.ipp_pipe_lp:
        ; Compute screen_target = line_table[B] + byte_x[C] + 5
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de                  ; HL → line_table[row]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr

        ld      hl, ipp_byte_x
        ld      a, c
        add     a, l
        ld      l, a
        jr      nc, .ipp_np_nc
        inc     h
.ipp_np_nc:
        ld      a, (hl)                 ; A = byte_x[C]
        add     a, 5                    ; +5 for stack-blast offset (4 body + 2 trail bytes)
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = screen_target

        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $E5             ; push hl  (Phase 1: NEW — HL=0 trailing zero)
        ld      (iy+4), $D5             ; push de
        ld      (iy+5), $C5             ; push bc
        ld      de, SLOT_STRIDE
        add     iy, de

        inc     c
        ld      a, c
        cp      NUM_PIPES
        jr      nz, .ipp_pipe_lp

.ipp_row_done:
        pop     bc                      ; restore B=row
        inc     b
        ld      a, b
        cp      GROUND_TOP              ; 160
        jp      nz, .ipp_row_lp

        ; ── Epilogue at SLOT_GRID_END: ld sp,(saved_sp) ; ret ────
        ; Encoding: ED 7B lo hi C9
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

ipp_byte_x:     ds 4, 0                 ; scratch: byte_x per pipe (Phase 3: 4 bytes)
init_pipe_bx_tmp: db 0                 ; scratch: byte_x for the pipe being configured at init

;----------------------------------------------------------------
; configure_pipe_slots(A=pipe 0..2, E=new_gap_y 1..111)
;
; Re-templates all 160 slots for one pipe based on new_gap_y:
;   row == new_gap_y - 1                  → cap_top  template
;   row == new_gap_y + PIPE_GAP           → cap_bot  template
;   new_gap_y <= row < new_gap_y+PIPE_GAP → skip     template
;   otherwise                             → body     template
;
; Also rebuilds that pipe's active sublist (ACTIVE_PIPE_N).
; After the row loop, patches cap_top/cap_bot handler target imms.
; Finally stores new_gap_y → pipe_state[pipe*2 + 1].
;
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

        ; Defensive: refresh cap_*_target_imm_addrs in case anything has
        ; corrupted them at runtime. Snapshot analysis on 2026-05-18 showed
        ; cap_top_target_imm_addrs[0] high byte being flipped from $8A to
        ; $AA (one bit), causing pipe 0's cap-top imm to be written into
        ; $AAEB instead of $8AEB — pipe 0's cap_top then stuck on a bogus
        ; screen target across recycles ("shortest top pipe missing cap"
        ; bug). Source of corruption not yet identified; this self-repairs
        ; the table every configure so the patch lands in the right place.
        ld      hl, cap_top_handler_pipe_0_target
        ld      (cap_top_target_imm_addrs), hl
        ld      hl, cap_top_handler_pipe_1_target
        ld      (cap_top_target_imm_addrs + 2), hl
        ld      hl, cap_top_handler_pipe_2_target
        ld      (cap_top_target_imm_addrs + 4), hl
        ld      hl, cap_top_handler_pipe_3_target   ; Phase 3
        ld      (cap_top_target_imm_addrs + 6), hl
        ld      hl, cap_bot_handler_pipe_0_target
        ld      (cap_bot_target_imm_addrs), hl
        ld      hl, cap_bot_handler_pipe_1_target
        ld      (cap_bot_target_imm_addrs + 2), hl
        ld      hl, cap_bot_handler_pipe_2_target
        ld      (cap_bot_target_imm_addrs + 4), hl
        ld      hl, cap_bot_handler_pipe_3_target   ; Phase 3
        ld      (cap_bot_target_imm_addrs + 6), hl

        ; ─── Step 1: stamp BODY_TEMPLATE → body rows only (skip cap range) ─
        ; Region A: rows [0, cap_top_row-1]    (count = cap_top_row)
        ; Region B: rows [cap_bot_row+1, 159]  (count = 159 - cap_bot_row)
        ; Cap region [cap_top_row..cap_bot_row] is overwritten by Step 2.
        ; Saves 50 rows × 146T = 7300T vs stamping all 160 rows.

        ; --- Region A: stamp rows [0, cap_top_row-1] ---
        ld      a, (cps_cap_top_row)
        or      a
        jr      z, .cps_body_a_done             ; skip if cap_top_row == 0
        ld      iyl, a                          ; counter = cap_top_row

        ; DE = slot[0][pipe] = SLOT_GRID_BASE + 1 + pipe*6
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, e                            ; A = pipe*3
        add     a, e                            ; A = pipe*4
        add     a, e                            ; A = pipe*5
        add     a, e                            ; A = pipe*6
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = slot[0][pipe]
        ld      hl, BODY_TEMPLATE
.cps_body_a_lp:
        ldi
        ldi
        ldi
        ldi
        ldi
        ldi
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 6
        add     hl, de
        ex      de, hl
        pop     hl
        dec     iyl
        jr      nz, .cps_body_a_lp
.cps_body_a_done:

        ; --- Region B: stamp rows [cap_bot_row+1, 159] ---
        ld      a, (cps_cap_bot_row)
        cpl                                     ; A = ~cap_bot_row = 255 - cap_bot_row
        sub     255 - 159                       ; A = 159 - cap_bot_row
        jr      z, .cps_body_b_done             ; skip if count == 0
        jr      c, .cps_body_b_done             ; safety: cap_bot_row > 159
        ld      iyl, a                          ; counter

        ; HL = BODY_TEMPLATE + (cap_bot_row+1) * 6
        ld      a, (cps_cap_bot_row)
        inc     a                               ; A = cap_bot_row + 1
        ld      l, a
        ld      h, 0
        ld      d, h
        ld      e, l                            ; DE = (cap_bot_row+1)
        add     hl, hl                          ; HL = (cap_bot_row+1) * 2
        add     hl, hl                          ; HL = (cap_bot_row+1) * 4
        add     hl, de                          ; HL = (cap_bot_row+1) * 5
        add     hl, de                          ; HL = (cap_bot_row+1) * 6
        ld      de, BODY_TEMPLATE
        add     hl, de                          ; HL = BODY_TEMPLATE + (cap_bot_row+1)*6
        push    hl                              ; save template src
        ; DE = slot[cap_bot_row+1][pipe] = SLOT_GRID_BASE + 1 + (cap_bot_row+1)*32 + pipe*6
        ld      a, (cps_cap_bot_row)
        inc     a
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; (cap_bot_row+1)*2
        add     hl, hl                          ; (cap_bot_row+1)*4
        add     hl, hl                          ; (cap_bot_row+1)*8
        add     hl, hl                          ; (cap_bot_row+1)*16
        add     hl, hl                          ; (cap_bot_row+1)*32  (Phase 3)
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, e                            ; A = pipe*3
        add     a, e                            ; A = pipe*4
        add     a, e                            ; A = pipe*5
        add     a, e                            ; A = pipe*6
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL += pipe*6
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[cap_bot_row+1][pipe]
        ex      de, hl                          ; DE = dest slot
        pop     hl                              ; HL = template src
.cps_body_b_lp:
        ldi
        ldi
        ldi
        ldi
        ldi
        ldi
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 6
        add     hl, de
        ex      de, hl
        pop     hl
        dec     iyl
        jr      nz, .cps_body_b_lp
.cps_body_b_done:

        ; ─── Step 2: stamp CAP_BLOCK at slot[cap_top_row][pipe] ─────
        ; DE = slot[cap_top_row][pipe] = SLOT_GRID_BASE + 1 + cap_top_row*32 + pipe*6
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; cap_top_row*2
        add     hl, hl                          ; cap_top_row*4
        add     hl, hl                          ; cap_top_row*8
        add     hl, hl                          ; cap_top_row*16
        add     hl, hl                          ; cap_top_row*32  (Phase 3)
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, e                            ; A = pipe*3
        add     a, e                            ; A = pipe*4
        add     a, e                            ; A = pipe*5
        add     a, e                            ; A = pipe*6
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = slot[cap_top_row][pipe]
        ld      hl, CAP_BLOCK
        ld      iyl, 50                         ; 50 rows in cap block
.cps_cap_stamp_lp:
        ldi
        ldi
        ldi
        ldi
        ldi
        ldi
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 6
        add     hl, de
        ex      de, hl
        pop     hl
        dec     iyl
        jr      nz, .cps_cap_stamp_lp

        ; ─── Step 3: patch cap-slot handler addresses (pipe-specific) ─
        ; slot[cap_top_row][pipe] +1..+2 := cap_top_handler_pipe_<pipe>
        ; slot[cap_bot_row][pipe] +1..+2 := cap_bot_handler_pipe_<pipe>

        ; cap_top: HL = slot[cap_top_row][pipe] + 1
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; cap_top_row*2
        add     hl, hl                          ; cap_top_row*4
        add     hl, hl                          ; cap_top_row*8
        add     hl, hl                          ; cap_top_row*16
        add     hl, hl                          ; cap_top_row*32  (Phase 3)
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, e                            ; A = pipe*3
        add     a, e                            ; A = pipe*4
        add     a, e                            ; A = pipe*5
        add     a, e                            ; A = pipe*6
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 2          ; +1 (EXX byte) + 1 (skip $C3 JP opcode)
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
        add     hl, hl                          ; cap_bot_row*2
        add     hl, hl                          ; cap_bot_row*4
        add     hl, hl                          ; cap_bot_row*8
        add     hl, hl                          ; cap_bot_row*16
        add     hl, hl                          ; cap_bot_row*32  (Phase 3)
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, e                            ; A = pipe*3
        add     a, e                            ; A = pipe*4
        add     a, e                            ; A = pipe*5
        add     a, e                            ; A = pipe*6
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

        ; ─── Step 6: build active sublist via SP-hijack push (FAST) ─
        ; Active list layout = 112 entries × 2 bytes per pipe:
        ;   [0..N-1]   band1 body entries  (rows 0..cap_top_row-1)
        ;   [N]        cap_top entry
        ;   [N+1]      cap_bot entry
        ;   [N+2..111] band2 body entries  (rows cap_bot_row+1..159)
        ;
        ; SP starts at ACTIVE_BASE+224 (end of list) and decreases through
        ; all four regions in REVERSE order (band2 → cap_bot → cap_top → band1).
        ; Total entries pushed = M + 1 + 1 + N = 112 always, so SP lands
        ; exactly at ACTIVE_BASE after the final band1 push.
        ;
        ; Per body row: 35T (add hl,de; push hl; djnz) vs old 92T.
        ; Total ~4.2k T worst case (was ~10.5k T) — saves ~6.3k T per pipe.

        ld      (cps_saved_sp), sp              ; save real SP

        ; --- Load ACTIVE_BASE for this pipe into HL ---
        ld      a, (cps_pipe)
        add     a, a                            ; A = pipe*2
        ld      hl, cps_sublist_base_table
        add     a, l
        ld      l, a
        jr      nc, .cps_act_sl_nc
        inc     h
.cps_act_sl_nc:
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                            ; HL = ACTIVE_BASE

        ; SP = ACTIVE_BASE + 224 (end of active list)
        ld      bc, 224
        add     hl, bc
        ld      sp, hl                          ; SP ready for band2 pushes

        ld      de, $FFE0                       ; DE = -32, for HL advance per row  (Phase 3)

        ; --- Band 2: rows [cap_bot_row+1, 159], pushed in reverse ---
        ld      a, (cps_cap_bot_row)
        cpl
        sub     255 - 159                       ; A = 159 - cap_bot_row = M
        jr      z, .cps_act_b2_done
        jr      c, .cps_act_b2_done             ; safety: cap_bot_row > 159

        ; HL = slot[160][pipe]+1 (one past last body row;
        ;       loop subtracts 32 first to give slot[159][pipe]+1 first push)
        ;    = SLOT_GRID_BASE + 2 + 160*32 + pipe*6
        ;    (+1 for EXX byte at row start, +1 to skip $31 opcode → target imm lo addr)
        push    af                              ; save M
        ld      a, (cps_pipe)
        ld      c, a
        add     a, a
        add     a, c                            ; A = pipe*3
        add     a, c                            ; A = pipe*4
        add     a, c                            ; A = pipe*5
        add     a, c                            ; A = pipe*6
        ld      l, a
        ld      h, 0                            ; HL = pipe*6
        ld      bc, SLOT_GRID_BASE + 2 + 160*32 ; Phase 3: stride 32
        add     hl, bc                          ; HL = slot[160][pipe]+1
        pop     af                              ; A = M again
        ld      b, a                            ; B = counter
.cps_act_b2_lp:
        add     hl, de                          ; HL -= 32  (Phase 3)
        push    hl                              ; write entry, SP -= 2
        djnz    .cps_act_b2_lp
.cps_act_b2_done:

        ; --- cap_bot entry: push cap_bot_target_imm_addrs[pipe] ---
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_bot_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_act_cb_nc
        inc     h
.cps_act_cb_nc:
        ld      a, (hl)
        ld      c, a
        inc     hl
        ld      a, (hl)
        ld      b, a                            ; BC = cap_bot_addr
        push    bc                              ; write entry, SP -= 2

        ; --- cap_top entry: push cap_top_target_imm_addrs[pipe] ---
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_top_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_act_ct_nc
        inc     h
.cps_act_ct_nc:
        ld      a, (hl)
        ld      c, a
        inc     hl
        ld      a, (hl)
        ld      b, a                            ; BC = cap_top_addr
        push    bc                              ; write entry, SP -= 2

        ; --- Band 1: rows [0, cap_top_row-1], pushed in reverse ---
        ld      a, (cps_cap_top_row)
        or      a
        jr      z, .cps_act_b1_done
        push    af                              ; save N

        ; HL = slot[cap_top_row][pipe]+1 = SLOT_GRID_BASE + 1 + N*32 + pipe*6
        ;       (loop subtracts 32 first → slot[N-1][pipe]+1 first push)  Phase 3
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; N*2
        add     hl, hl                          ; N*4
        add     hl, hl                          ; N*8
        add     hl, hl                          ; N*16
        add     hl, hl                          ; N*32  (Phase 3)
        ld      a, (cps_pipe)
        ld      c, a
        add     a, a
        add     a, c                            ; A = pipe*3
        add     a, c                            ; A = pipe*4
        add     a, c                            ; A = pipe*5
        add     a, c                            ; A = pipe*6
        add     a, l
        ld      l, a
        jr      nc, .cps_act_b1_nc
        inc     h
.cps_act_b1_nc:
        ld      bc, SLOT_GRID_BASE + 2          ; +1 EXX + 1 skip $31 → target imm lo addr
        add     hl, bc                          ; HL = slot[N][pipe]+1

        pop     af                              ; A = N
        ld      b, a                            ; B = counter
.cps_act_b1_lp:
        add     hl, de                          ; HL -= 32  (Phase 3)
        push    hl                              ; write entry, SP -= 2
        djnz    .cps_act_b1_lp
.cps_act_b1_done:

        ; --- Restore real SP ---
        ld      sp, (cps_saved_sp)

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

;----------------------------------------------------------------
; compute_next_slot: given a cap row and the current pipe, return the address
; of the next slot to execute after the cap handler finishes.
;
; Input:  A = cap_row (0..159), cps_pipe = pipe index (0..2)
; Output: HL = address of next slot
; Clobbers: A, B, D, E
;----------------------------------------------------------------
compute_next_slot:
        ld      b, a                    ; B = row
        ld      a, (cps_pipe)
        cp      NUM_PIPES - 1           ; Phase 3: pipe == 3 → go to next row
        jr      z, .cns_next_row
        ; pipe 0..2: next pipe in same row = SLOT_ADDR_TABLE[(row*4 + pipe+1)*2]
        inc     a                       ; A = pipe + 1
        ; index = row*8 + (pipe+1)*2  (Phase 3: 4 pipes × 2 bytes = 8 bytes/row)
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        add     hl, hl                  ; row*4
        add     hl, hl                  ; row*8  (Phase 3)
        add     a, a                    ; (pipe+1)*2
        ld      e, a
        ld      d, 0
        add     hl, de                  ; row*8 + (pipe+1)*2
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl                  ; HL = slot[row][pipe+1]
        ret
.cns_next_row:
        ; pipe == NUM_PIPES-1: next = slot_addr_table[row+1][0] - 1 (the EXX byte before it)
        ld      a, b
        inc     a                       ; A = row + 1
        cp      GROUND_TOP              ; 160 = end of grid
        jr      z, .cns_end_of_grid
        ; index = (row+1)*8  (Phase 3: 4 pipes × 2 bytes)
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; (row+1)*2
        add     hl, hl                  ; (row+1)*4
        add     hl, hl                  ; (row+1)*8  (Phase 3)
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl                  ; HL = slot[row+1][0]
        dec     hl                      ; HL = EXX byte before slot[row+1][0]
        ret
.cns_end_of_grid:
        ld      hl, SLOT_GRID_END
        ret

;----------------------------------------------------------------
; shift_pipe_targets — decrement all of one pipe's active sublist
; entries' target lo-bytes by C, with borrow propagation into the hi byte.
;
; Used at init only: BODY_TEMPLATE bakes byte_x=29 into slot targets,
; but the initial pipe_state may set byte_x < 29 for some pipes (to
; stagger them across the screen). This routine shifts those pipes'
; slot targets down to match.
;
; In:  A = pipe (0..2)
;      C = delta (0..28)  ; 0 = no-op
; Clobbers: AF, BC, DE, HL, IX.
;----------------------------------------------------------------
shift_pipe_targets:
        ; IX = sublist cursor (ACTIVE_PIPE_<pipe>)
        add     a, a
        ld      hl, cps_sublist_base_table
        add     a, l
        ld      l, a
        jr      nc, .spt_sb_nc
        inc     h
.spt_sb_nc:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        push    de
        pop     ix                              ; IX = sublist cursor
        ld      b, 112                          ; 112 entries per pipe
.spt_lp:
        ld      l, (ix+0)
        ld      h, (ix+1)                       ; HL = target imm addr
        ld      a, (hl)
        sub     c                               ; (HL) -= C
        ld      (hl), a
        jr      nc, .spt_no_borrow
        inc     hl
        dec     (hl)                            ; borrow into hi byte
.spt_no_borrow:
        inc     ix
        inc     ix
        djnz    .spt_lp
        ret

; ── Scratch variables for configure_pipe_slots ───────────────────
cps_pipe:               db 0
cps_gap_y:              db 0
cps_cap_top_row:        db 0
cps_cap_bot_row:        db 0
cps_saved_sp:           dw 0    ; real SP saved across SP-hijack push loops

; ── Per-pipe active sublist base table ───────────────────────────
cps_sublist_base_table:
        dw      ACTIVE_PIPE_0
        dw      ACTIVE_PIPE_1
        dw      ACTIVE_PIPE_2
        dw      ACTIVE_PIPE_3           ; Phase 3: prep pipe sublist base

; Precomputed screen targets for byte_x=29 baseline (recycle byte_x).
; targets[row] = line_table[row] + 34 (= byte_x=29 + 5). Populated at init.
; Used by configure_pipe_slots body emit to skip the line_table+byte_x add.
screen_target_table_29: ds 320, 0       ; 160 entries × 2 bytes

;----------------------------------------------------------------
; init_background: zero bg_buffer (all-sky) then blit to screen pixels.
;----------------------------------------------------------------
init_background:
        ld      hl, BG_BUFFER
        ld      de, BG_BUFFER + 1
        ld      (hl), 0
        ld      bc, $17FF
        ldir
        ld      hl, BG_BUFFER
        ld      de, $4000
        ld      bc, $1800
        ldir
        ret

;----------------------------------------------------------------
; init_screen_target_table: populate screen_target_table_29 with
;   targets[row] = line_table[row] + 34 (= byte_x=29 + 5).
; Configure_pipe_slots reads this on every body emit instead of recomputing.
;----------------------------------------------------------------
init_screen_target_table:
        ld      hl, line_table
        ld      de, screen_target_table_29
        ld      b, 160
.istt_lp:
        ld      a, (hl)
        add     a, 34                           ; Phase 1: +34 = byte_x=29 + 5 (was +32)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        adc     a, 0
        ld      (de), a
        inc     hl
        inc     de
        djnz    .istt_lp
        ret

;----------------------------------------------------------------
; build_slot_templates — one-shot init builder for the template store.
; Walks line_table to populate:
;   BODY_TEMPLATE:    160 rows × ($31, lo+34, hi, $E5, $D5, $C5) for byte_x=29
;   CAP_BLOCK:         50 rows: cap_top stub, 48 skip rows, cap_bot stub
;   CAP_TARGET_TABLE:  12 (gap_y) entries × (cap_top_target, cap_bot_target)
;
; Called once at boot, BEFORE init_pipes. Cost ~80k T-states, run-once.
; Clobbers AF, BC, DE, HL, IX.
;----------------------------------------------------------------
build_slot_templates:
        ; ─── Fill BODY_TEMPLATE: 160 rows × 6 bytes ─────────────────
        ld      hl, line_table
        ld      de, BODY_TEMPLATE
        ld      b, GROUND_TOP                   ; B = row counter (160)
.bst_body_lp:
        ld      a, $31                          ; opcode: ld sp, nn
        ld      (de), a
        inc     de
        ld      a, (hl)                         ; line_table[R].lo
        add     a, 34                           ; Phase 1: +34 = byte_x=29 + 5 offset (was +32)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)                         ; line_table[R].hi
        adc     a, 0                            ; carry from +34
        ld      (de), a
        inc     de
        inc     hl
        ld      a, $E5                          ; opcode: push hl  (Phase 1: NEW — HL=0 trailing zero)
        ld      (de), a
        inc     de
        ld      a, $D5                          ; opcode: push de
        ld      (de), a
        inc     de
        ld      a, $C5                          ; opcode: push bc
        ld      (de), a
        inc     de
        djnz    .bst_body_lp

        ; ─── Fill CAP_BLOCK: 50 rows × 6 bytes ───────────────────
        ; Row 0 (cap_top): $C3, 0, 0, 0, 0, 0  (JP nn + 3 pad — handler addr patched at recycle)
        ; Rows 1..48 (skip): 0, 0, 0, 0, 0, 0  (6 NOPs)
        ; Row 49 (cap_bot): $C3, 0, 0, 0, 0, 0
        ld      hl, CAP_BLOCK
        ld      (hl), $C3                       ; cap_top stub: jp nn opcode
        inc     hl
        ld      b, 5                            ; remaining cap_top bytes (now 5: jp target lo, hi, then 3 pad)
.bst_cap_top_zero:
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_top_zero
        ; 48 skip rows × 6 bytes = 288 zero bytes
        ld      bc, 288
.bst_cap_skip_lp:
        ld      (hl), 0
        inc     hl
        dec     bc
        ld      a, b
        or      c
        jr      nz, .bst_cap_skip_lp
        ; cap_bot stub
        ld      (hl), $C3
        inc     hl
        ld      b, 5
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

        ; cap_top_target: read line_table[gap_y - 1], add 34
        ld      a, b
        rlca
        rlca
        rlca                                    ; A = B * 8 = gap_y (8..96)
        dec     a                               ; A = gap_y - 1
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = line_addr
        ld      a, e
        add     a, 34                           ; Phase 1: +34 = byte_x=29 + 5 (was +32)
        ld      (ix+0), a
        ld      a, d
        adc     a, 0
        ld      (ix+1), a

        ; cap_bot_target: read line_table[gap_y + 48], add 34
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
        add     a, 34                           ; Phase 1: +34 = byte_x=29 + 5 (was +32)
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

;----------------------------------------------------------------
init_pipes:
        xor     a
        ld      (phase), a
        call    init_slot_addr_table        ; precompute slot_addr_table[160][4]  Phase 3
        call    init_screen_target_table    ; precompute screen_target_table_29[160]
        call    init_pipe_program           ; emit fixed slot grid (reads slot_addr_table)
        ; For each of the 3 ACTIVE pipes, apply initial cap/skip configuration (full pass).
        ; Phase 3: pipe 3 is the "preparing" pipe — its column gets NOP-fill below.
        xor     a                            ; pipe index 0
.init_cps_lp:
        push    af
        ld      l, a
        ld      h, 0
        add     hl, hl                       ; pipe * 2
        ld      de, pipe_state
        add     hl, de                       ; HL → byte_x byte for this pipe
        push    hl                           ; save pipe_state_ptr (points at byte_x)
        inc     hl                           ; HL → gap_y byte
        ld      e, (hl)                      ; E = initial gap_y
        pop     hl                           ; restore HL → byte_x
        ld      a, (hl)                      ; A = initial byte_x
        ld      (init_pipe_bx_tmp), a        ; save byte_x for shift step
        pop     af
        push    af
        ld      b, 0                         ; row_start = 0
        ld      c, GROUND_TOP                ; row_end = 160 (full pass)
        call    configure_pipe_slots
        ; If byte_x < 29, shift this pipe's slot targets by (29 - byte_x).
        ld      a, (init_pipe_bx_tmp)
        cp      29
        jr      z, .init_no_shift
        ld      b, a                         ; B = byte_x temporarily
        ld      a, 29
        sub     b                            ; A = 29 - byte_x
        ld      c, a                         ; C = delta
        pop     af                           ; restore pipe index
        push    af
        call    shift_pipe_targets
.init_no_shift:
        pop     af
        inc     a
        cp      3                            ; Phase 3: configure only pipes 0..2 (not pipe 3)
        jr      nz, .init_cps_lp

        ; Phase 3: pipe 3 is the "preparing" slot column. Init it to all-NOPs.
        ; Slot column 3 at row R is at SLOT_GRID_BASE + 1 + row*32 + 3*6
        ;   = SLOT_GRID_BASE + 1 + 18 = SLOT_GRID_BASE + 19 for row 0.
        ; 6 bytes × 160 rows = 960 NOP bytes to write.
        ld      hl, SLOT_GRID_BASE + 1 + 3*SLOT_STRIDE  ; first byte of pipe-3 slot at row 0
        ld      b, 160
.init_pipe3_lp:
        push    bc
        xor     a                            ; A = $00 (NOP opcode)
        ld      b, SLOT_STRIDE               ; 6 bytes per slot
.init_pipe3_byte_lp:
        ld      (hl), a
        inc     hl
        djnz    .init_pipe3_byte_lp
        ; Advance HL to pipe-3 slot of next row: HL += (SLOT_ROW_STRIDE - SLOT_STRIDE) = 32 - 6 = 26
        ld      bc, SLOT_ROW_STRIDE - SLOT_STRIDE
        add     hl, bc
        pop     bc
        djnz    .init_pipe3_lp

        ; Defensive: zero-fill ACTIVE_PIPE_3 (224 bytes) so that if do_swap's
        ; fallback path ever triggers patch_pipe_targets before phase 6 runs,
        ; any stray decrements hit $0000 in ROM (silent, no corruption).
        ld      hl, ACTIVE_PIPE_3
        ld      de, ACTIVE_PIPE_3 + 1
        ld      (hl), 0
        ld      bc, 223
        ldir

        ; ACTIVE_COUNT_NEW = 3 * 112 = 336 (patch_pipe_targets walks only the 3 active
        ; pipes at ACTIVE_PIPE_0..PIPE_2; pipe 3 is skipped — its column is all-NOPs
        ; and decrementing NOP bytes would produce $FF = RST $38, disastrous during
        ; PIPE_PROGRAM execution. Phase 4/5 will activate pipe 3 properly.)
        ld      hl, 336
        ld      (ACTIVE_COUNT_NEW), hl

        ; Phase 4: initialise prep state machine. prep_step will prepare pipe 3's
        ; slot column incrementally over the next ~112 frames, starting from phase 0.
        ; prep_gap_y is taken from pipe_state[3*2+1] (gap_y of pipe 3 at init).
        xor     a
        ld      (prep_phase), a
        ld      (prep_row), a
        ld      a, (pipe_state + 3*2 + 1)
        ld      (prep_gap_y), a
        ; Also initialise ps_cap_top_row/ps_cap_bot_row so phase 5 can use them
        ; (they're set during phase 3, but init them to valid values for safety).
        ld      a, (prep_gap_y)
        dec     a
        ld      (ps_cap_top_row), a
        ld      a, (prep_gap_y)
        add     a, PIPE_GAP
        ld      (ps_cap_bot_row), a

        call    update_cap_imm_v2       ; init cap imms for phase 0 (first render)
        call    redraw_pipes_v2
        ret

; Phase 5: deferred_configure deleted. Recycle is now O(1) via do_swap in
; wrap_byte_x. No more 30 k T configure spike on recycle frames.

;----------------------------------------------------------------
; ps_slot_addr_for_row — compute slot[row][prep_pipe_idx] address.
; In:  A = row (0..159)
; Out: HL = slot[row][prep_pipe_idx] = SLOT_GRID_BASE + 1 + row*32 + prep_pipe_idx*6
; Clobbers: DE, HL. BC preserved.
;----------------------------------------------------------------
ps_slot_addr_for_row:
        ; Compute prep_pipe_idx * 6 into E; use only DE to avoid clobbering BC.
        push    af                              ; save row
        ld      a, (prep_pipe_idx)
        ld      e, a
        add     a, a                            ; *2
        add     a, e                            ; *3
        add     a, e                            ; *4
        add     a, e                            ; *5
        add     a, e                            ; *6
        ld      e, a                            ; E = prep_pipe_idx * 6
        ld      d, 0
        pop     af                              ; restore row
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2
        add     hl, hl                          ; row*4
        add     hl, hl                          ; row*8
        add     hl, hl                          ; row*16
        add     hl, hl                          ; row*32
        add     hl, de                          ; HL = row*32 + prep_pipe_idx*6
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[row][prep_pipe_idx]
        ret

;----------------------------------------------------------------
; prep_step — Phase 4 incremental-prepare state machine.
;
; Called from main_loop's CYAN region each frame. Each call does a
; small slice of work (~200-300 T) that together amounts to one full
; configure_pipe_slots invocation for pipe 3. Spread across ~112
; frames → ~270 T/frame overhead, eliminating the ~30 k T recycle spike.
;
; State bytes: prep_phase (0..7), prep_row (row cursor),
;              prep_gap_y (gap_y for pipe 3).
;
; Phase 0: stamp body (target=line_addr+34) at rows [0..cap_top_row-1]. 5 rows/call.
; Phase 1: stamp all-NOP at cap range rows [cap_top_row..cap_bot_row]. 5 rows/call.
; Phase 2: stamp body (target=line_addr+34) at rows [cap_bot_row+1..159]. 5 rows/call.
; Phase 3: one-shot — patch $C3+handler addr into cap_top and cap_bot slots.
; Phase 4: one-shot — patch cap handler target imms from CAP_TARGET_TABLE.
; Phase 5: one-shot — patch cap handler _next imms via compute_next_slot.
; Phase 6: one-shot — build ACTIVE_PIPE sublist via SP-hijack (~4.2k T).
; Phase 7: done — immediate return.
;
; Body slots use target=line_addr+34 (= byte_x=29 right-buffer cols, invisible).
; Writes via ld sp,line_addr+34; push land in buffer cols 29-31 (hidden by
; ATTR_BUFFER) → silent. Prep pipe is NOT in patch_pipe_targets' walk list,
; so targets stay at line_addr+34 throughout prep.
; After do_swap, the newly-active pipe's body slots ALREADY have correct
; byte_x=29 targets — no body-target-write needed at swap time.
;
; Cap slots stay all-NOP until phase 3, so no accidental JP until fully armed.
;
; Clobbers: AF, BC, DE, HL.
; ps_saved_sp saves real SP across SP-hijack in phase 6.
;----------------------------------------------------------------
prep_step:
        ld      a, (prep_phase)
        or      a
        jp      z, ps_phase0
        cp      1
        jp      z, ps_phase1
        cp      2
        jp      z, ps_phase2
        cp      3
        jp      z, ps_phase3
        cp      4
        jp      z, ps_phase4
        cp      5
        jp      z, ps_phase5
        cp      6
        jp      z, ps_phase6
        ; phase 7 = done
        ret

; ─── Phase 0: body rows [0 .. cap_top_row-1], 10 rows/call ───────────────────
; Target = line_table[row]+34 (= byte_x=29 buffer col, invisible writes).
; After swap, active pipe's body slots already point at byte_x=29 → no
; body-target-write needed in do_swap.
ps_phase0:
        ; cap_top_row = prep_gap_y - 1
        ld      a, (prep_gap_y)
        dec     a                               ; A = cap_top_row
        ld      b, a                            ; B = cap_top_row
        ld      a, (prep_row)
        ld      c, a                            ; C = current prep_row
        ld      a, b
        sub     c                               ; A = rows remaining
        jr      z, .p0_advance
        jr      c, .p0_advance                  ; safety: overshot
        cp      10
        jr      c, .p0_rows_set
        ld      a, 10
.p0_rows_set:
        ld      (ps_count), a                   ; save count for prep_row update
        ld      b, a                            ; B = loop counter
        ld      a, c                            ; A = actual row = prep_row (band1 starts at 0)
        call    ps_slot_addr_for_row            ; HL = slot[prep_row][prep_pipe_idx]; A = row
        ex      de, hl                          ; DE = slot addr
        ; HL = screen_target_table_29 + prep_row*2 (C = prep_row still valid)
        push    bc                              ; save B=loop_count, C=prep_row
        ld      l, c
        ld      h, 0
        add     hl, hl                          ; HL = prep_row * 2
        ld      bc, screen_target_table_29
        add     hl, bc                          ; HL = screen_target_table_29 + prep_row*2
        pop     bc                              ; restore B=loop_count, C=prep_row
.p0_lp:
        ; Write: $31 lo hi $E5 $D5 $C5  (ld sp,line_addr+34; push hl; push de; push bc)
        ld      a, $31
        ld      (de), a
        inc     de
        ld      a, (hl)
        ld      (de), a                         ; target.lo = line_table[row]+34
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a                         ; target.hi
        inc     de
        inc     hl                              ; HL now points at next table entry
        ld      a, $E5
        ld      (de), a                         ; push hl
        inc     de
        ld      a, $D5
        ld      (de), a                         ; push de
        inc     de
        ld      a, $C5
        ld      (de), a                         ; push bc
        inc     de
        ; advance DE to next row's slot: +(SLOT_ROW_STRIDE - SLOT_STRIDE) = +26
        ld      a, e
        add     a, SLOT_ROW_STRIDE - SLOT_STRIDE
        ld      e, a
        jr      nc, .p0_nc
        inc     d
.p0_nc:
        djnz    .p0_lp
        ; prep_row += count
        ld      a, (prep_row)
        ld      b, a
        ld      a, (ps_count)
        add     a, b
        ld      (prep_row), a
        ret
.p0_advance:
        xor     a
        ld      (prep_row), a
        ld      a, 1
        ld      (prep_phase), a
        ret

; ─── Phase 1: NOP-fill cap range [cap_top_row..cap_bot_row], 10 rows/call ────
; prep_row = 0..49 (offset within 50-row cap block)
ps_phase1:
        ld      a, (prep_row)
        ld      c, a                            ; C = prep_row (offset in cap block)
        ld      a, 50
        sub     c                               ; A = remaining rows in cap block
        jr      z, .p1_advance
        jr      c, .p1_advance
        cp      10
        jr      c, .p1_rows_set
        ld      a, 10
.p1_rows_set:
        ld      (ps_count), a
        ld      b, a                            ; B = loop counter
        ; actual row = cap_top_row + prep_row = (prep_gap_y - 1) + C
        ld      a, (prep_gap_y)
        dec     a                               ; A = cap_top_row
        add     a, c                            ; A = cap_top_row + prep_row
        call    ps_slot_addr_for_row            ; HL = slot[actual_row][3]
        ex      de, hl
.p1_lp:
        xor     a
        ld      (de), a                         ; NOP byte 0
        inc     de
        ld      (de), a                         ; NOP byte 1
        inc     de
        ld      (de), a                         ; NOP byte 2
        inc     de
        ld      (de), a                         ; NOP byte 3
        inc     de
        ld      (de), a                         ; NOP byte 4
        inc     de
        ld      (de), a                         ; NOP byte 5
        inc     de
        ld      hl, SLOT_ROW_STRIDE - SLOT_STRIDE
        add     hl, de
        ex      de, hl
        djnz    .p1_lp
        ld      a, (prep_row)
        ld      b, a
        ld      a, (ps_count)
        add     a, b
        ld      (prep_row), a
        ret
.p1_advance:
        xor     a
        ld      (prep_row), a
        ld      a, 2
        ld      (prep_phase), a
        ret

; ─── Phase 2: body rows [cap_bot_row+1..159], 10 rows/call ───────────────────
; prep_row = 0..M-1 where M = 111 - prep_gap_y
; Target = line_table[actual_row]+34 (= byte_x=29 buffer col, invisible).
ps_phase2:
        ; total M = 111 - prep_gap_y
        ld      a, (prep_gap_y)
        ld      c, a
        ld      a, 111
        sub     c                               ; A = M (total rows in band2)
        ld      b, a                            ; B = M
        ld      a, (prep_row)
        ld      c, a                            ; C = prep_row
        ld      a, b
        sub     c                               ; A = remaining rows
        jr      z, .p2_advance
        jr      c, .p2_advance                  ; safety
        cp      10
        jr      c, .p2_rows_set
        ld      a, 10
.p2_rows_set:
        ld      (ps_count), a
        ld      b, a                            ; B = loop counter
        ; actual row = cap_bot_row + 1 + prep_row = (prep_gap_y + PIPE_GAP + 1) + C
        ld      a, (prep_gap_y)
        add     a, PIPE_GAP + 1                 ; A = cap_bot_row + 1
        add     a, c                            ; A += prep_row; A = actual_row
        call    ps_slot_addr_for_row            ; HL = slot[actual_row][prep_pipe_idx]; A = actual_row
        ex      de, hl                          ; DE = slot addr
        ; HL = screen_target_table_29 + actual_row*2  (A = actual_row restored by ps_slot_addr_for_row)
        push    bc                              ; save B=loop_count, C=prep_row
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; HL = actual_row * 2
        ld      bc, screen_target_table_29
        add     hl, bc                          ; HL = screen_target_table_29 + actual_row*2
        pop     bc                              ; restore B=loop_count, C=prep_row
.p2_lp:
        ; Write: $31 lo hi $E5 $D5 $C5  (ld sp,line_addr+34; push hl; push de; push bc)
        ld      a, $31
        ld      (de), a
        inc     de
        ld      a, (hl)
        ld      (de), a                         ; target.lo = line_table[row]+34
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a                         ; target.hi
        inc     de
        inc     hl                              ; HL now points at next table entry
        ld      a, $E5
        ld      (de), a
        inc     de
        ld      a, $D5
        ld      (de), a
        inc     de
        ld      a, $C5
        ld      (de), a
        inc     de
        ; advance DE to next row's slot: +(SLOT_ROW_STRIDE - SLOT_STRIDE) = +26
        ld      a, e
        add     a, SLOT_ROW_STRIDE - SLOT_STRIDE
        ld      e, a
        jr      nc, .p2_nc
        inc     d
.p2_nc:
        djnz    .p2_lp
        ld      a, (prep_row)
        ld      b, a
        ld      a, (ps_count)
        add     a, b
        ld      (prep_row), a
        ret
.p2_advance:
        xor     a
        ld      (prep_row), a
        ld      a, 3
        ld      (prep_phase), a
        ret

; ─── Phase 3: one-shot — compute cap_top_row, cap_bot_row; store in scratch ──
; NOTE: Phase 3 does NOT write $C3 into the cap slots. Cap slots remain all-NOP
; (safe, no JP fires) throughout Phase 4. Phase 5 (implementation) swap will
; atomically write $C3 + handler + target + _next when activating pipe 3.
; This prevents cap handler execution with uninitialized _target/$0000 SP, which
; would corrupt the top of RAM stack area.
ps_phase3:
        ; ps_cap_top_row = prep_gap_y - 1
        ld      a, (prep_gap_y)
        dec     a
        ld      (ps_cap_top_row), a
        ; ps_cap_bot_row = prep_gap_y + PIPE_GAP
        ld      a, (prep_gap_y)
        add     a, PIPE_GAP
        ld      (ps_cap_bot_row), a

        ld      a, 4
        ld      (prep_phase), a
        ret

; ─── Phase 4: one-shot — pre-compute cap target imms (stored in ps_*) ────────
; Phase 4 does NOT write the real screen addresses into the cap handlers yet,
; because that would cause cap handlers to fire and write outside-screen bytes
; every PIPE_PROGRAM frame until Phase 5 swap. Instead, store the computed
; targets in scratch bytes; Phase 5 swap will use them when activating pipe 3.
; Cap handler targets remain at $0000 (ROM, silent writes) until Phase 5.
ps_phase4:
        ; Entry index = prep_gap_y/8 - 1; each entry is 4 bytes
        ld      a, (prep_gap_y)
        rrca
        rrca
        rrca                                    ; A = prep_gap_y / 8
        and     $0F
        dec     a                               ; A = index (0..11)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl                          ; index * 4
        ld      de, CAP_TARGET_TABLE
        add     hl, de                          ; HL → entry[0]

        ; Read cap_top_target (entry[0..1]) into ps_cap_top_target scratch
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        inc     hl
        ld      a, e
        ld      (ps_cap_top_target), a
        ld      a, d
        ld      (ps_cap_top_target + 1), a

        ; Read cap_bot_target (entry[2..3]) into ps_cap_bot_target scratch
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      a, e
        ld      (ps_cap_bot_target), a
        ld      a, d
        ld      (ps_cap_bot_target + 1), a

        ; Cap handler targets remain $0000 (ROM) — Phase 5 swap will set them.
        ; Targets at $0000 mean cap writes go to ROM = silent, no screen corruption.

        ld      a, 5
        ld      (prep_phase), a
        ret

; ─── Phase 5: one-shot — pre-compute cap _next values; stored in scratch ─────
; Like phase 4, does NOT write to handlers yet. Cap slots remain all-NOP.
; ps_cap_top_next / ps_cap_bot_next hold the computed values; Phase 5
; (implementation) swap will write them to handlers when activating pipe 3.
ps_phase5:
        ; compute_next_slot reads cps_pipe — set to prep_pipe_idx (Phase 5: dynamic)
        ld      a, (prep_pipe_idx)
        ld      (cps_pipe), a

        ld      a, (ps_cap_top_row)
        call    compute_next_slot               ; HL = next slot addr
        ld      a, l
        ld      (ps_cap_top_next), a
        ld      a, h
        ld      (ps_cap_top_next + 1), a

        ld      a, (ps_cap_bot_row)
        call    compute_next_slot
        ld      a, l
        ld      (ps_cap_bot_next), a
        ld      a, h
        ld      (ps_cap_bot_next + 1), a

        ld      a, 6
        ld      (prep_phase), a
        ret

; ─── Phase 6: one-shot — build ACTIVE sublist for prep_pipe_idx (~4.2k T) ────
; Phase 5: generalised from pipe-3-only to use prep_pipe_idx. Covers any pipe.
ps_phase6:
        ld      (ps_saved_sp), sp

        ; Compute prep_pipe_idx * 6 into (ps_p6_pipe6) for slot address arithmetic.
        ld      a, (prep_pipe_idx)
        ld      e, a
        add     a, a                            ; *2
        add     a, e                            ; *3
        add     a, e                            ; *4
        add     a, e                            ; *5
        add     a, e                            ; *6
        ld      (ps_p6_pipe6), a                ; save prep_pipe_idx*6

        ; Compute SP = ACTIVE_PIPE_<prep_pipe_idx> + 224 (end of sublist).
        ld      a, (prep_pipe_idx)
        add     a, a                            ; * 2 (each table entry is 2 bytes)
        ld      l, a
        ld      h, 0
        ld      de, cps_sublist_base_table
        add     hl, de                          ; HL = &cps_sublist_base_table[prep_pipe_idx]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = ACTIVE_PIPE_<prep_pipe_idx> base
        ld      hl, 224
        add     hl, de                          ; HL = ACTIVE_PIPE_<prep> + 224
        ld      sp, hl                          ; SP = end of sublist

        ld      de, $FFE0                       ; DE = -32 (backward one row in PIPE_PROGRAM)

        ; ── Band 2: M = 111 - prep_gap_y entries (rows cap_bot_row+1..159, reversed)
        ld      a, (prep_gap_y)
        ld      c, a
        ld      a, 111
        sub     c                               ; A = M
        jr      z, .act_b2_done
        jr      c, .act_b2_done
        ld      b, a                            ; B = M counter
        ; Start address: slot[160][prep_pipe_idx]+1 = SLOT_GRID_BASE+2 + 160*32 + pipe*6.
        ; We then add -32 per iteration (going backward).
        ld      a, (ps_p6_pipe6)
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 2 + 160*SLOT_ROW_STRIDE
        add     hl, de                          ; HL = slot[160][prep]+1  (one past end of grid)
        ld      de, $FFE0                       ; DE = -32
.act_b2_lp:
        add     hl, de                          ; HL -= 32 (walk backward through rows 159..cap_bot+1)
        push    hl
        djnz    .act_b2_lp
.act_b2_done:

        ; ── Cap_bot entry: address of cap_bot_handler_pipe_<prep>_target
        ld      a, (prep_pipe_idx)
        add     a, a                            ; *2
        ld      l, a
        ld      h, 0
        ld      de, cap_bot_target_imm_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = cap_bot_handler_pipe_<prep>_target addr
        push    de

        ; ── Cap_top entry: address of cap_top_handler_pipe_<prep>_target
        ld      a, (prep_pipe_idx)
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, cap_top_target_imm_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = cap_top_handler_pipe_<prep>_target addr
        push    de

        ; ── Band 1: N = cap_top_row = prep_gap_y - 1 entries (rows 0..cap_top_row-1, reversed)
        ld      a, (prep_gap_y)
        dec     a                               ; A = N = cap_top_row
        jr      z, .act_b1_done
        ld      b, a
        ; Start address: slot[N][prep_pipe_idx]+1
        ; = SLOT_GRID_BASE + 2 + N*32 + prep_pipe_idx*6
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; N * 32
        ld      a, (ps_p6_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL += prep_pipe_idx * 6
        ld      de, SLOT_GRID_BASE + 2
        add     hl, de                          ; HL = slot[N][prep]+1
        ld      de, $FFE0                       ; DE = -32
.act_b1_lp:
        add     hl, de
        push    hl
        djnz    .act_b1_lp
.act_b1_done:

        ld      sp, (ps_saved_sp)
        ld      a, 7
        ld      (prep_phase), a
        ret

ps_p6_pipe6: db 0                              ; prep_pipe_idx * 6 scratch for phase 6

; ── Scratch for prep_step ────────────────────────────────────────
ps_cap_top_row:    db 0
ps_cap_bot_row:    db 0
ps_saved_sp:       dw 0
ps_count:          db 0                ; row count saved across djnz for prep_row update
; Pre-computed cap targets (from prep_step phase 4) and _next addrs (phase 5).
; Phase 5 (implementation) swap writes these to the cap handlers when activating
; pipe 3. Until then, cap handlers have $0000 targets (ROM writes = silent).
ps_cap_top_target: dw 0
ps_cap_bot_target: dw 0
ps_cap_top_next:   dw 0
ps_cap_bot_next:   dw 0

;----------------------------------------------------------------
frame_update:
        ; PIPE_PROGRAM runs FIRST (after the bird ops in main_loop's RED
        ; top-blanking region). Bird writes already landed before the raster
        ; reached row 0 → uniform 0-frame lag at every bird Y, no flicker.
        ; PIPE_PROGRAM starts at T~5.6k with ~8k T head start over the raster.
        call    redraw_pipes_v2
        ld      a, 1                    ; PROFILE: BLUE = ground/score region
        out     ($fe), a
        call    update_score
        ld      a, 4                    ; PROFILE: GREEN = ground
        out     ($fe), a
        call    draw_ground
        ; State prep (advance_phase × 2 with wrap-byte_x, restore_trailing)
        ; was here in the WHITE band. Moved to main_loop's CYAN region.
.no_regen:
        ; Skip render_score if score unchanged — saves ~1.5k T-states most frames.
        ld      hl, (score)
        ld      de, (score_last)
        or      a
        sbc     hl, de
        ret     z
        ld      hl, (score)
        ld      (score_last), hl
        jp      render_score

;----------------------------------------------------------------
; advance_phase: increment phase by 1. On wrap (phase 7→0), do wrap_byte_x
; (cheap: byte_x dec + trailing col clear) and apply_pipe_attrs (paint green
; at NEW positions BEFORE pipe redraw). Set wrap_pending so the matching
; restore_pipe_attrs (un-green OLD positions) runs at end of frame — that
; restore only affects NEXT frame's display, so keeping it OUT of the pre-
; pipe path means pipe writes start sooner = less raster tearing.
;----------------------------------------------------------------
advance_phase:
        ld      a, (phase)
        inc     a
        and     7
        ld      (phase), a
        ret     nz
.wrap:
        call    wrap_byte_x
        call    apply_pipe_attrs_wrap   ; paints only NEW M1 (NEW M2 = OLD M1, already pipe-attr)
        ld      a, 1
        ld      (wrap_pending), a
        ret

;----------------------------------------------------------------
; draw_ground: fill lines 160..191 with diagonal-stripe pattern, phase-shifted
; for scroll. Uses push-BC stack-fill (12 pushes = 24 bytes per line, cols 4-27).
;----------------------------------------------------------------
draw_ground:
        ld      (saved_sp), sp
        ; IY = ground_tiles + (phase mod 8) * 8
        ld      a, (phase)
        and     7
        add     a, a
        add     a, a
        add     a, a                    ; A = phase * 8
        ld      iy, ground_tiles
        ld      c, a
        ld      b, 0
        add     iy, bc
        ld      (ground_iy_save), iy    ; cache IY base — avoid push iy in loop
        ld      d, GROUND_TOP           ; D = current Y
.line_lp:
        ; CRITICAL: reset SP to caller stack BEFORE any push. After the SP
        ; hijack in iter N, SP sits in screen RAM at line_addr_N; an unsafe
        ; push iy/push bc would write into screen pixel memory.
        ld      sp, (saved_sp)
        ; Tile byte for line D = (IY + (D mod 8))
        ld      a, d
        and     7
        ld      c, a
        ld      b, 0
        ld      hl, (ground_iy_save)
        add     hl, bc
        ld      a, (hl)
        ld      b, a
        ld      c, a                    ; BC = fill byte (both halves)
        ; Compute HL = line_table[D] + 28 (= end of col 27 = last visible col).
        ; Ground fills cols 4-27 (24 bytes); buffer cols 0-3 and 28-31 hidden
        ; by buffer attr ($2D), so we skip writing them entirely → fewer pushes.
        ld      a, d
        ld      h, 0
        ld      l, a
        add     hl, hl                  ; HL = D*2
        push    bc                      ; safe: SP at caller stack
        ld      bc, line_table
        add     hl, bc
        ld      c, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, c                    ; HL = line addr
        ld      bc, 28
        add     hl, bc                  ; HL = line addr + 28
        pop     bc
        ld      sp, hl
        ; Push BC 12 times = fill 24 bytes (cols 4..27)
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        push    bc
        inc     d
        ld      a, d
        cp      SCORE_TOP               ; only 8 lines (160..167); 168+ = scoreboard
        jr      c, .line_lp
        ld      sp, (saved_sp)
        ret

;----------------------------------------------------------------
patch_pipe_targets:
        ; SP-hijack 4-way unrolled walker. Reads entry addresses via pop hl
        ; (10T) which is faster than ld e,(hl); inc hl; ld d,(hl); inc hl (26T).
        ; Each entry's 16-bit target decrement uses the borrow-check fast path
        ; (~33T avg per entry vs 88T basic version).
        ;
        ; Phase 5: always uses the 4-pipe skip path (always skips prep_pipe_idx).
        ; 4 pipes × 112 entries each. Active = 3 pipes × 112 = 336 entries total.
        ; Each pipe block: 28 djnz iters × 4 entries = 112 entries.
        ld      (saved_sp_inner), sp
        ld      a, (prep_pipe_idx)              ; Phase 5: skip prep pipe, not recycled pipe

        ; Pipe 0
        or      a                               ; prep_pipe_idx == 0?
        jr      z, .pt_done_p0
        ld      sp, ACTIVE_PIPE_0
        ld      b, 28                           ; 112 / 4
.pt_lp_p0:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p0_nc1
        inc     hl
        dec     (hl)
.pt_p0_nc1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p0_nc2
        inc     hl
        dec     (hl)
.pt_p0_nc2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p0_nc3
        inc     hl
        dec     (hl)
.pt_p0_nc3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p0_nc4
        inc     hl
        dec     (hl)
.pt_p0_nc4:
        djnz    .pt_lp_p0
.pt_done_p0:

        ; Pipe 1
        ld      a, (prep_pipe_idx)
        cp      1                               ; prep_pipe_idx == 1?
        jr      z, .pt_done_p1
        ld      sp, ACTIVE_PIPE_1
        ld      b, 28
.pt_lp_p1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p1_nc1
        inc     hl
        dec     (hl)
.pt_p1_nc1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p1_nc2
        inc     hl
        dec     (hl)
.pt_p1_nc2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p1_nc3
        inc     hl
        dec     (hl)
.pt_p1_nc3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p1_nc4
        inc     hl
        dec     (hl)
.pt_p1_nc4:
        djnz    .pt_lp_p1
.pt_done_p1:

        ; Pipe 2
        ld      a, (prep_pipe_idx)
        cp      2                               ; prep_pipe_idx == 2?
        jr      z, .pt_done_p2
        ld      sp, ACTIVE_PIPE_2
        ld      b, 28
.pt_lp_p2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p2_nc1
        inc     hl
        dec     (hl)
.pt_p2_nc1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p2_nc2
        inc     hl
        dec     (hl)
.pt_p2_nc2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p2_nc3
        inc     hl
        dec     (hl)
.pt_p2_nc3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p2_nc4
        inc     hl
        dec     (hl)
.pt_p2_nc4:
        djnz    .pt_lp_p2
.pt_done_p2:

        ; Pipe 3 (Phase 5: newly active after swap; skipped when prep_pipe_idx == 3)
        ld      a, (prep_pipe_idx)
        cp      3                               ; prep_pipe_idx == 3?
        jr      z, .pt_done_p3
        ld      sp, ACTIVE_PIPE_3
        ld      b, 28
.pt_lp_p3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p3_nc1
        inc     hl
        dec     (hl)
.pt_p3_nc1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p3_nc2
        inc     hl
        dec     (hl)
.pt_p3_nc2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p3_nc3
        inc     hl
        dec     (hl)
.pt_p3_nc3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_p3_nc4
        inc     hl
        dec     (hl)
.pt_p3_nc4:
        djnz    .pt_lp_p3
.pt_done_p3:

        ld      sp, (saved_sp_inner)
        ret

;----------------------------------------------------------------
; wrap_byte_x: scroll all active (non-prep) pipes left by one byte (8 px).
;   Phase 5: iterate all 4 pipes, skip prep_pipe_idx.
;   When byte_x == 1: call do_swap to exchange with the prepared pipe.
;     If prep not ready (prep_phase != 7): fast fallback (byte_x=29, new gap_y, no configure).
; Tail-call patch_pipe_targets to decrement every active body slot's screen
; target by ROW_OFFSET (= 1) so they walk to the next column.
;
; Column clearing is handled by the trailing-zero pair in every pipe stamp.
;----------------------------------------------------------------
wrap_byte_x:
        ld      iy, pipe_state
        ld      b, NUM_PIPES                    ; Phase 5: iterate all 4 pipes, skip prep
.outer:
        ; pipe_idx = NUM_PIPES - B  (B counts down 4→1, so idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .wbx_skip                   ; skip the preparing pipe
        ; active pipe: check byte_x
        ld      a, (iy+0)
        cp      1
        jr      z, .swap_with_prep
        dec     a
        jr      .wbx_save
.swap_with_prep:
        ; Phase 5: pipe reached byte_x=1. Swap with the prep pipe.
        push    bc
        push    iy
        ld      a, c                            ; A = departing pipe index
        call    do_swap                         ; O(1) swap — no configure spike
        pop     iy
        pop     bc
        jr      .wbx_skip                       ; do_swap wrote pipe_state directly; skip (iy+0) write
.wbx_save:
        ld      (iy+0), a
.wbx_skip:
        inc     iy
        inc     iy
        djnz    .outer
.wbx_apply_pending:
        ; Bug 2 fix: apply deferred prep_pipe_idx update from fallback path.
        ; prep_pipe_swap_pending == dep+1 if the fallback ran; 0 otherwise.
        ld      a, (prep_pipe_swap_pending)
        or      a
        jr      z, .wbx_no_pending
        dec     a                               ; recover dep
        ld      (prep_pipe_idx), a
        xor     a
        ld      (prep_pipe_swap_pending), a     ; clear pending flag
.wbx_no_pending:
        ; Run patch_pipe_targets so NEXT frame's PIPE_PROGRAM renders at NEW byte_x.
        call    patch_pipe_targets
        ret

;----------------------------------------------------------------
; do_swap: called when pipe A (departing) has reached byte_x=1.
;
; If prep_phase == 7 (prep ready): full swap (~14 k T total).
;   - Arm incoming pipe's cap slots ($C3 + handler addr written into PIPE_PROGRAM).
;   - Write ps_cap_*_target and ps_cap_*_next imms to incoming cap handlers.
;   - Set pipe_state[incoming].gap_y = prep_gap_y, byte_x = 29.
;   - Dep body-slot target rewrite (~13.8 k T): write line_addr+34 to the 2 target
;     imm bytes of each of dep's 160 slot rows. Body slots become invisible writes
;     (byte_x=29 buffer cols) immediately without clearing the full 6-byte slot.
;   - Dep cap-slot deactivate (~50 T): write $00 to byte 0 of dep's old cap_top
;     and cap_bot slots, neutralising the $C3 JP opcode until prep_step phase 1
;     NOP-fills those rows.
;   - Update prep_pipe_idx = dep. Pick new gap_y. Reset prep state to phase 0.
;   NOTE: incoming pipe's body slot targets are NOT written here. prep_step phases 0
;   and 2 stamp body slots with target=line_addr+34 (byte_x=29 buffer col, invisible).
;   After swap the newly-active pipe's body slots already point at byte_x=29.
;   patch_pipe_targets walks the new active pipe each wrap → targets decrement and
;   pipe scrolls leftward naturally.
;
; If prep_phase != 7 (fallback):
;   - Re-randomise departing pipe's gap_y and set byte_x=29 in place.
;     (byte_x=29 is intentional: pipe stays at 29 while its slot column is
;     all-NOP, so pipe_state[dep].byte_x stays at 29 throughout dep's prep
;     cycle — pipe_state drives attr routines, not the NOP column itself.)
;   - Clear all 6 bytes of each of the departing pipe's 160 slot rows to $00
;     (full NOP slide). Without clearing bytes 1-5, stray pushes would occur
;     when the slot executes with a wrong SP.
;   - Set prep_pipe_swap_pending = dep+1 (deferred; applied after wrap_byte_x
;     loop exits to prevent the loop from walking the old prep pipe).
;
; In:  A = departing pipe index (0..3; NOT prep_pipe_idx).
; Clobbers: AF, BC, DE, HL, HL' (saved and restored).
;----------------------------------------------------------------
do_swap:
        ld      (ds_dep), a                     ; save departing pipe index

        ; Zero-fill ACTIVE_PIPE_<dep> (224 bytes = 112 words) via SP-hijack.
        ; ~1.3 k T vs ~4.7 k T for LDIR. Keeps swap-frame budget under 70 k.
        ; Stale entries from dep's previous active period would otherwise let
        ; patch_pipe_targets corrupt slot bytes via $00→$FF wraps when dep
        ; becomes active again before phase 6 rebuilds the list.
        add     a, a                            ; dep*2
        ld      e, a
        ld      d, 0
        ld      hl, active_pipe_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = ACTIVE_PIPE_<dep>
        ld      hl, 224
        add     hl, de                          ; HL = ACTIVE_PIPE_<dep> + 224 (end)
        ld      (saved_sp_inner), sp            ; save real SP (reuse patch's slot)
        ld      sp, hl                          ; SP = end of buffer
        ld      hl, 0
        ; 112 pushes × 11 T = 1232 T
        REPT 112
            push hl
        ENDR
        ld      sp, (saved_sp_inner)            ; restore real SP

        ; Guard: only do full swap when prep is complete (phase 7).
        ld      a, (prep_phase)
        cp      7
        jr      z, .ds_full_swap

        ; ── Fallback: prep not ready. Fast in-place recycle. ────────────
        ; Just pick new random gap_y and reset byte_x=29 for the departing pipe.
        ; The departing pipe's slot column stays configured (body targets at old byte_x=1
        ; position, which is the LEFT buffer → invisible writes for 1 frame until
        ; patch_pipe_targets scrolls targets further). After ~2 frames the old targets
        ; wrap off left buffer into visible area, so we MUST clear the $31 opcode.
        ; Clear: write $00 to byte 0 of all 160 departing-pipe slots → NOP slide.
        ; Then body slots write nothing, and prep_step will reconfigure them.
        call    random_gap_y                    ; A = new random gap_y
        ld      (ds_tmp), a                     ; save gap_y

        ; Clear all 6 bytes of all 160 slots in departing pipe's column → full NOP slide.
        ; Without this, bytes 1-5 left as ($00 $00 $E5 $D5 $C5) after clearing byte 0
        ; would cause stray pushes with wrong SP on execution.
        ld      a, (ds_dep)
        ld      e, a
        add     a, a    ; dep*2
        add     a, e    ; dep*3
        add     a, e    ; dep*4
        add     a, e    ; dep*5
        add     a, e    ; dep*6
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[0][dep]
        ld      de, SLOT_ROW_STRIDE - SLOT_STRIDE + 1 ; 27: HL at slot+5 after 5 incs;
                                                      ; +27 reaches next row's slot+0.
        ld      b, GROUND_TOP                   ; 160
        xor     a
.ds_fb_clr:
        ld      (hl), a                         ; byte 0
        inc     hl
        ld      (hl), a                         ; byte 1
        inc     hl
        ld      (hl), a                         ; byte 2
        inc     hl
        ld      (hl), a                         ; byte 3
        inc     hl
        ld      (hl), a                         ; byte 4
        inc     hl
        ld      (hl), a                         ; byte 5
        add     hl, de                          ; advance to next row's dep slot
        djnz    .ds_fb_clr

        ; Set pipe_state[dep] byte_x=29, gap_y=new
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de                          ; HL = &pipe_state[dep*2]
        ld      (hl), 29                        ; byte_x = 29
        inc     hl
        ld      a, (ds_tmp)
        ld      (hl), a                         ; gap_y = new random

        ; Update prep state so prep_step rebuilds this pipe (new gap_y may differ).
        ; NOTE: we do NOT update prep_pipe_idx here — the wrap_byte_x loop is still
        ; running and relies on the OLD prep_pipe_idx to skip the old prep pipe.
        ; Instead, set prep_pipe_swap_pending = dep+1; wrap_byte_x applies it after
        ; its loop exits (see .wbx_apply_pending below).
        ld      a, (ds_dep)
        inc     a                               ; dep+1 (0 means "no pending")
        ld      (prep_pipe_swap_pending), a
        ld      a, (ds_tmp)
        ld      (prep_gap_y), a
        xor     a
        ld      (prep_phase), a
        ld      (prep_row), a
        ret

        ; ── Full swap ────────────────────────────────────────────────────
.ds_full_swap:
        ; Capture dep's OLD gap_y for later band-boundary computations.
        ; Must happen BEFORE step 3 overwrites pipe_state[inc].
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de                          ; HL = &pipe_state[dep].gap_y
        ld      a, (hl)                         ; A = OLD gap_y
        ld      (ds_old_gap_y), a

        ld      a, (prep_pipe_idx)
        ld      (ds_inc), a                     ; incoming = old prep_pipe_idx

        ; 1. Set incoming pipe's byte_x=29, gap_y=prep_gap_y in pipe_state.
        ld      a, (ds_inc)
        add     a, a                            ; inc*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de                          ; HL = &pipe_state[inc*2]
        ld      (hl), 29                        ; byte_x = 29
        inc     hl
        ld      a, (prep_gap_y)
        ld      (hl), a                         ; gap_y = prep_gap_y

        ; 2. Arm incoming cap slots in PIPE_PROGRAM.
        ;    slot[cap_top_row][inc] byte 0: write $C3; bytes 1-2: write handler addr
        ;    slot[cap_bot_row][inc] byte 0: write $C3; bytes 1-2: write handler addr
        ;
        ;    slot[row][pipe] = SLOT_GRID_BASE + 1 + row*32 + pipe*6

        ; --- Compute pipe offset = inc*6 ---
        ld      a, (ds_inc)
        ld      e, a
        add     a, a    ; inc*2
        add     a, e    ; inc*3
        add     a, e    ; inc*4
        add     a, e    ; inc*5
        add     a, e    ; inc*6
        ld      (ds_pipe6), a                   ; save inc*6

        ; --- cap_top slot ---
        ld      a, (ps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl  ; row*2
        add     hl, hl  ; row*4
        add     hl, hl  ; row*8
        add     hl, hl  ; row*16
        add     hl, hl  ; row*32
        ld      a, (ds_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de                          ; HL += pipe*6
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[cap_top_row][inc]
        ; Write $C3 + handler addr (lo, hi)
        ld      (hl), $C3                       ; JP opcode
        inc     hl
        ; Look up cap_top_handler_pipe_<inc> from cap_top_handler_addrs[inc]
        ld      a, (ds_inc)
        add     a, a                            ; inc * 2
        ld      e, a
        ld      d, 0
        push    hl                              ; save slot+1 addr
        ld      hl, cap_top_handler_addrs
        add     hl, de                          ; HL = &cap_top_handler_addrs[inc]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = handler address
        pop     hl                              ; restore slot+1 addr
        ld      (hl), e                         ; write handler.lo
        inc     hl
        ld      (hl), d                         ; write handler.hi

        ; --- cap_bot slot ---
        ld      a, (ps_cap_bot_row)
        ld      l, a
        ld      h, 0
        add     hl, hl  ; row*2
        add     hl, hl  ; row*4
        add     hl, hl  ; row*8
        add     hl, hl  ; row*16
        add     hl, hl  ; row*32
        ld      a, (ds_pipe6)
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de                          ; HL = slot[cap_bot_row][inc]
        ld      (hl), $C3                       ; JP opcode
        inc     hl
        ld      a, (ds_inc)
        add     a, a
        ld      e, a
        ld      d, 0
        push    hl
        ld      hl, cap_bot_handler_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = handler address
        pop     hl
        ld      (hl), e                         ; write handler.lo
        inc     hl
        ld      (hl), d                         ; write handler.hi

        ; 3. Write ps_cap_top_target into cap_top_handler_pipe_<inc>_target
        ;    Address of the SMC imm slot = cap_top_target_imm_addrs[inc]
        ld      a, (ds_inc)
        add     a, a                            ; inc * 2
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_target_imm_addrs
        add     hl, de                          ; HL = &cap_top_target_imm_addrs[inc]
        ld      c, (hl)
        inc     hl
        ld      b, (hl)                         ; BC = address of cap_top_handler_<inc>_target imm
        ld      hl, ps_cap_top_target
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; Write ps_cap_bot_target into cap_bot_handler_pipe_<inc>_target
        ld      a, (ds_inc)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_bot_target_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)                         ; BC = address of cap_bot_handler_<inc>_target imm
        ld      hl, ps_cap_bot_target
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; Write ps_cap_top_next into cap_top_handler_pipe_<inc>_next
        ld      a, (ds_inc)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_next_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)                         ; BC = address of cap_top_handler_<inc>_next imm
        ld      hl, ps_cap_top_next
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; Write ps_cap_bot_next into cap_bot_handler_pipe_<inc>_next
        ld      a, (ds_inc)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_bot_next_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        ld      hl, ps_cap_bot_next
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; 4. (REMOVED) Body-target-write for incoming pipe eliminated.
        ;    prep_step phases 0 and 2 now stamp body slots with target=line_addr+34
        ;    (= byte_x=29 buffer col) instead of $0000. After swap the incoming
        ;    pipe's body slots already point at byte_x=29. No per-swap rewrite needed.

        ; 5. Clear dep's slot column to all NOPs (6 bytes × 160 rows = 960 bytes).
        ;    Earlier attempt rewrote only bytes 1, 2 (target) assuming all 160 of
        ;    dep's slots were body slots. BUG: dep's cap-skip rows (50 rows between
        ;    cap_top and cap_bot) were NOP slides pre-swap. Partial rewrite turned
        ;    them into `$00 <lo> <hi> $00 $00 $00` — e.g., row 104 with gap_y=88
        ;    decoded as `NOP ; JP NZ $0048 ; NOP × 3`, jumping into ROM when ZF
        ;    was clear → CPU reset.
        ;    Clearing all 6 bytes makes every slot a harmless NOP slide until
        ;    prep_step (phases 0/1/2) rebuilds the body template + cap NOPs.
        ;    Cost ~16 k T (96 T/row × 160).

        ; Compute dep*6 for slot column base.
        ld      a, (ds_dep)
        ld      e, a
        add     a, a    ; dep*2
        add     a, e    ; dep*3
        add     a, e    ; dep*4
        add     a, e    ; dep*5
        add     a, e    ; dep*6
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1          ; HL = slot[0][dep] byte 0
        add     hl, de
        ld      de, SLOT_ROW_STRIDE - SLOT_STRIDE + 1  ; 27: HL is at slot+5 after
                                                       ; 5 inc-hl's; +27 reaches slot+5+27
                                                       ; = slot+32 = next row's slot+0.
        ld      b, GROUND_TOP                   ; 160
        xor     a
.ds_dep_clr_lp:
        ld      (hl), a                         ; byte 0
        inc     hl
        ld      (hl), a                         ; byte 1
        inc     hl
        ld      (hl), a                         ; byte 2
        inc     hl
        ld      (hl), a                         ; byte 3
        inc     hl
        ld      (hl), a                         ; byte 4
        inc     hl
        ld      (hl), a                         ; byte 5
        add     hl, de                          ; advance to next row's dep slot
        djnz    .ds_dep_clr_lp

        ; 7. Update prep_pipe_idx, pick new gap_y, reset prep state.
        ld      a, (ds_dep)
        ld      (prep_pipe_idx), a              ; departing pipe is now the prep pipe
        call    random_gap_y                    ; A = new random gap_y for next prep cycle
        ld      (prep_gap_y), a
        ; ps_cap_top_row/ps_cap_bot_row will be reset by prep_step phase 3.
        xor     a
        ld      (prep_phase), a                 ; reset to phase 0 (start fresh)
        ld      (prep_row), a
        ld      a, 1
        ld      (do_swap_fired), a              ; tell main_loop to skip prep_step this frame
        ret

; ── Scratch variables for do_swap ────────────────────────────────
do_swap_fired: db 0                            ; main_loop reads and clears each frame
ds_dep:     db 0                               ; departing pipe index
ds_inc:     db 0                               ; incoming pipe index
ds_tmp:     db 0                               ; temp (fallback gap_y)
ds_pipe6:   db 0                               ; incoming pipe index × 6
ds_cap_top: db 0                               ; temp scratch (reused for dep*6 in cap deactivate)
ds_cap_bot: db 0                               ; (unused in full_swap path; kept for alignment)
ds_old_gap_y: db 0                             ; dep's OLD gap_y, captured at .ds_full_swap entry

active_pipe_addrs:
        dw      ACTIVE_PIPE_0
        dw      ACTIVE_PIPE_1
        dw      ACTIVE_PIPE_2
        dw      ACTIVE_PIPE_3

;----------------------------------------------------------------
; Cap handlers (JP'd to by cap_top / cap_bot slots — never CALLed).
; Each handler:
;   1. Hijacks SP to the cap's screen target (SMC slot patched by patch_pipe_targets)
;   2. Loads cap M2/R byte pair into HL via SMC imm, pushes (writes M2/R cells)
;   3. Loads cap L/M1 byte pair into HL via SMC imm, pushes (writes L/M1 cells)
;   4. JPs to next slot (SMC imm patched by configure_pipe_slots)
;
; No CALL/RET — the slot emits JP $CD→$C3 so SP is never pushed with a
; return address while pointing into screen RAM.  The next slot's ld sp,target
; will set SP correctly, so the interim SP value doesn't matter.
;
; HL is used (not BC/DE) so the row's main register set survives —
; this preserves A/B row-parity dithering across cap rows.
;
; SMC slots:
;   *_target  : 2-byte screen address, patched by configure_pipe_slots
;   *_de      : 2-byte M2/R byte pair (low=M2, high=R), patched by update_cap_imm_v2
;   *_bc      : 2-byte L/M1 byte pair (low=L, high=M1), patched by update_cap_imm_v2
;   *_next    : 2-byte address of next slot, patched by configure_pipe_slots
;----------------------------------------------------------------

cap_top_handler_pipe_0:
cap_top_handler_pipe_0_target EQU $+1
        ld      sp, $0000                       ; SMC: cap row's screen target
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_top_handler_pipe_0_de EQU $+1
        ld      hl, $0000                       ; SMC: M2/R pair (low=M2, high=R)
        push    hl
cap_top_handler_pipe_0_bc EQU $+1
        ld      hl, $0000                       ; SMC: L/M1 pair (low=L, high=M1)
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_top_handler_pipe_0_next EQU $+1
        jp      $0000                           ; SMC: address of next slot after cap row

cap_top_handler_pipe_1:
cap_top_handler_pipe_1_target EQU $+1
        ld      sp, $0000
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_top_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_top_handler_pipe_1_next EQU $+1
        jp      $0000

cap_top_handler_pipe_2:
cap_top_handler_pipe_2_target EQU $+1
        ld      sp, $0000
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_top_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_top_handler_pipe_2_next EQU $+1
        jp      $0000

cap_top_handler_pipe_3:                         ; Phase 3
cap_top_handler_pipe_3_target EQU $+1
        ld      sp, $0000
        push    hl                              ; HL=0 → writes trailing zero pair
cap_top_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; restore HL=0 invariant
cap_top_handler_pipe_3_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_0:
cap_bot_handler_pipe_0_target EQU $+1
        ld      sp, $0000
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_bot_handler_pipe_0_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_0_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_bot_handler_pipe_0_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_1:
cap_bot_handler_pipe_1_target EQU $+1
        ld      sp, $0000
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_bot_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_bot_handler_pipe_1_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_2:
cap_bot_handler_pipe_2_target EQU $+1
        ld      sp, $0000
        push    hl                              ; Phase 1: HL=0 → writes trailing zero pair
cap_bot_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; Phase 1: restore HL=0 invariant
cap_bot_handler_pipe_2_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_3:                         ; Phase 3
cap_bot_handler_pipe_3_target EQU $+1
        ld      sp, $0000
        push    hl                              ; HL=0 → writes trailing zero pair
cap_bot_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                           ; restore HL=0 invariant
cap_bot_handler_pipe_3_next EQU $+1
        jp      $0000

; Per-pipe handler address tables for indexed dispatch in configure_pipe_slots.
cap_top_handler_addrs:
        dw      cap_top_handler_pipe_0
        dw      cap_top_handler_pipe_1
        dw      cap_top_handler_pipe_2
        dw      cap_top_handler_pipe_3             ; Phase 3
cap_bot_handler_addrs:
        dw      cap_bot_handler_pipe_0
        dw      cap_bot_handler_pipe_1
        dw      cap_bot_handler_pipe_2
        dw      cap_bot_handler_pipe_3             ; Phase 3

; Per-pipe SMC label tables for update_cap_imm_v2 and configure_pipe_slots.
cap_top_bc_imm_addrs:
        dw      cap_top_handler_pipe_0_bc
        dw      cap_top_handler_pipe_1_bc
        dw      cap_top_handler_pipe_2_bc
        dw      cap_top_handler_pipe_3_bc          ; Phase 3
cap_top_de_imm_addrs:
        dw      cap_top_handler_pipe_0_de
        dw      cap_top_handler_pipe_1_de
        dw      cap_top_handler_pipe_2_de
        dw      cap_top_handler_pipe_3_de          ; Phase 3
cap_bot_bc_imm_addrs:
        dw      cap_bot_handler_pipe_0_bc
        dw      cap_bot_handler_pipe_1_bc
        dw      cap_bot_handler_pipe_2_bc
        dw      cap_bot_handler_pipe_3_bc          ; Phase 3
cap_bot_de_imm_addrs:
        dw      cap_bot_handler_pipe_0_de
        dw      cap_bot_handler_pipe_1_de
        dw      cap_bot_handler_pipe_2_de
        dw      cap_bot_handler_pipe_3_de          ; Phase 3
cap_top_target_imm_addrs:
        dw      cap_top_handler_pipe_0_target
        dw      cap_top_handler_pipe_1_target
        dw      cap_top_handler_pipe_2_target
        dw      cap_top_handler_pipe_3_target      ; Phase 3
cap_bot_target_imm_addrs:
        dw      cap_bot_handler_pipe_0_target
        dw      cap_bot_handler_pipe_1_target
        dw      cap_bot_handler_pipe_2_target
        dw      cap_bot_handler_pipe_3_target      ; Phase 3
cap_top_next_imm_addrs:
        dw      cap_top_handler_pipe_0_next
        dw      cap_top_handler_pipe_1_next
        dw      cap_top_handler_pipe_2_next
        dw      cap_top_handler_pipe_3_next        ; Phase 3
cap_bot_next_imm_addrs:
        dw      cap_bot_handler_pipe_0_next
        dw      cap_bot_handler_pipe_1_next
        dw      cap_bot_handler_pipe_2_next
        dw      cap_bot_handler_pipe_3_next        ; Phase 3

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
        ; Phase 5: deferred_configure / pending_regen removed. Recycle is now
        ; O(1) via do_swap. redraw_pipes_v2 is now pure: loads BC/DE/BC'/DE'
        ; from pre-computed body bytes then calls PIPE_PROGRAM.

        ; --- Sky-A pair into BC/DE ---
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap
        add     hl, bc
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        inc     hl
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      (body_a_bc), bc
        ld      (body_a_de), de
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
        ld      (body_b_bc), bc
        ld      (body_b_de), de
        exx
        ; (update_cap_imm_v2 moved to main_loop's CYAN region — pre-computes
        ; cap byte imms for NEXT frame's PIPE_PROGRAM. Saves ~2 k T from
        ; pre-PP block so PP starts BEFORE raster reaches pixel area.)

        ld      a, 3                    ; MAGENTA = PIPE_PROGRAM
        out     ($fe), a
        ; PIPE_PROGRAM has a leading EXX at every row to alternate A/B variants.
        ; Enter with main = B-pattern, shadow = A-pattern; row 0's EXX swaps to A.
        ld      bc, (body_a_bc)
        ld      de, (body_a_de)
        exx                                   ; A → shadow
        ld      bc, (body_b_bc)
        ld      de, (body_b_de)               ; B → main
        ; Save SP for the slot grid's epilogue (ld sp,(saved_sp); ret) to restore.
        ld      hl, 0                   ; Phase 1: trailing-zero pair — main bank HL = 0
        exx
        ld      hl, 0                   ; Phase 1: trailing-zero pair — shadow bank HL = 0
        exx                             ; back to main (B-pattern active)
        ld      (saved_sp), sp
        call    PIPE_PROGRAM
        ret

;----------------------------------------------------------------
; update_cap_imm_v2 — write current phase's cap bytes into the 6
; cap handler SMC imm slots (cap_top × 3 + cap_bot × 3 pipes).
; Mirrors update_cap_imm exactly but targets the v2 handler tables.
; No skip-if-absent check — imms are always written (harmless).
; Clobbers: AF, BC, DE, HL, IX.
;----------------------------------------------------------------
update_cap_imm_v2:
        ; Cache L, M1, M2, R from cap_rounded_bitmap[phase*4]
        ld      hl, cap_rounded_bitmap
        ld      a, (phase)
        add     a, a
        add     a, a                    ; A = phase * 4
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → cap_rounded_bitmap[phase*4]
        ld      a, (hl)
        ld      (cap_L_temp), a         ; L
        inc     hl
        ld      a, (hl)
        ld      (cap_M1_temp), a        ; M1
        inc     hl
        ld      a, (hl)
        ld      (cap_M2_temp), a        ; M2
        inc     hl
        ld      a, (hl)
        ld      (cap_R_temp), a         ; R

        ; Write bc/de pairs into cap_top handlers (pipes 0..3 — Phase 5: all 4)
        ld      ix, cap_top_bc_imm_addrs
        ld      iy, cap_top_de_imm_addrs
        ld      b, 4
.top_lp:
        push    bc
        ; BC-imm slot: byte at addr = L, byte at addr+1 = M1
        ld      l, (ix+0)
        ld      h, (ix+1)
        ld      a, (cap_L_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_M1_temp)
        ld      (hl), a
        ; DE-imm slot: byte at addr = M2, byte at addr+1 = R
        ld      l, (iy+0)
        ld      h, (iy+1)
        ld      a, (cap_M2_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_R_temp)
        ld      (hl), a
        ; Advance table pointers by 2
        inc     ix
        inc     ix
        inc     iy
        inc     iy
        pop     bc
        djnz    .top_lp

        ; Write bc/de pairs into cap_bot handlers (pipes 0..3 — Phase 5: all 4)
        ld      ix, cap_bot_bc_imm_addrs
        ld      iy, cap_bot_de_imm_addrs
        ld      b, 4
.bot_lp:
        push    bc
        ld      l, (ix+0)
        ld      h, (ix+1)
        ld      a, (cap_L_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_M1_temp)
        ld      (hl), a
        ld      l, (iy+0)
        ld      h, (iy+1)
        ld      a, (cap_M2_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_R_temp)
        ld      (hl), a
        inc     ix
        inc     ix
        inc     iy
        inc     iy
        pop     bc
        djnz    .bot_lp
        ret

;----------------------------------------------------------------
; Bird routines
;----------------------------------------------------------------
init_bird:
        xor     a
        ld      (bird_old_y_valid), a
        ld      (bird_attr_valid), a
        ld      (bird_anim_tick), a
        ld      (bird_anim_phase), a
        ld      hl, bird_sprite_f0
        ld      (bird_sprite_ptr), hl
        ret

; advance_bird_anim: wing flap state machine.
;   - Bird falling (vy >= 0):  freeze on bird_sprite_f3 (wings fully spread,
;                              gliding pose). Reset tick/phase so the next
;                              flap restarts the cycle at f0.
;   - Bird rising  (vy <  0):  cycle phase 0→1→2→3→0 every BIRD_ANIM_RATE
;                              frames. Real birds only flap on the up-stroke.
advance_bird_anim:
        ld      a, (bird_vy + 1)
        bit     7, a
        jr      nz, .rising

        ; Falling: lock to f3 (wings spread).
        xor     a
        ld      (bird_anim_tick), a
        ld      (bird_anim_phase), a
        ld      hl, bird_sprite_f3
        ld      (bird_sprite_ptr), hl
        ret

.rising:
        ld      hl, bird_anim_tick
        ld      a, (hl)
        inc     a
        cp      BIRD_ANIM_RATE
        jr      c, .store_tick
        xor     a                       ; tick wraps to 0
        ld      (hl), a
        ld      a, (bird_anim_phase)
        inc     a
        and     3                       ; 4-frame cycle 0..3
        ld      (bird_anim_phase), a
        jr      .update_ptr
.store_tick:
        ld      (hl), a
        ld      a, (bird_anim_phase)
.update_ptr:
        ; ptr = bird_sprite_f0 + phase * BIRD_FRAME_BYTES (=96)
        ; Multiplying by 96 = 64 + 32 = (phase<<6) + (phase<<5), or just 96*phase.
        ; phase ∈ {0,1,2,3} so max = 288. Compute as phase*64 + phase*32.
        ld      h, 0
        ld      l, a
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        add     hl, hl                  ; *8
        add     hl, hl                  ; *16
        add     hl, hl                  ; *32
        ld      d, h
        ld      e, l                    ; DE = phase * 32
        add     hl, hl                  ; HL = phase * 64
        add     hl, de                  ; HL = phase * 96
        ld      de, bird_sprite_f0
        add     hl, de
        ld      (bird_sprite_ptr), hl
        ret

;----------------------------------------------------------------
; Score routines
;----------------------------------------------------------------

; next_random: 16-bit Galois LFSR (taps $002D, period 65535). Returns the
; new low byte in A; HL clobbered, BC/DE/IY preserved.
next_random:
        ld      hl, (rand_state)
        add     hl, hl
        jr      nc, .skip
        ld      a, l
        xor     $2D
        ld      l, a
.skip:
        ld      (rand_state), hl
        ld      a, l
        ret

; random_gap_y: random gap_y in [8, 96], step 8. 12 evenly-distributed values
; (8, 16, 24, ..., 96). Called from wrap_byte_x's recycle path.
random_gap_y:
        call    next_random             ; A = random byte
        and     $0F                     ; 0..15
        cp      12
        jr      c, .ok
        sub     12                      ; 12..15 → 0..3 (slight bias to low values)
.ok:
        inc     a                       ; 1..12
        rlca
        rlca
        rlca                            ; × 8 → 8..96
        ret

; update_score: per-pipe edge detect. byte_x decreases as pipes scroll left.
; When byte_x drops below 6 (pipe right edge has just cleared bird col 8),
; mark scored and bump score. Reset the flag once byte_x climbs back above
; 10 (pipe has wrapped to the right side of the screen).
update_score:
        ld      iy, pipe_state
        ld      hl, pipe_scored
        ld      b, NUM_PIPES                    ; iterate all 4 pipes, skip prep_pipe_idx
.lp:
        push    bc
        ; current pipe index = NUM_PIPES - B (B counts down 4→1, idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .next                        ; skip the preparing pipe
        ld      a, (iy+0)               ; byte_x
        cp      6
        jr      nc, .check_reset
        ; byte_x in 0..5 — pipe passed
        ld      a, (hl)
        or      a
        jr      nz, .next               ; already scored this cycle
        ld      (hl), 1
        push    hl
        push    bc
        ld      hl, (score)
        inc     hl
        ld      (score), hl
        pop     bc
        pop     hl
        jr      .next
.check_reset:
        cp      10
        jr      c, .next                ; byte_x 6..9 = transition zone, no-op
        ld      (hl), 0                 ; byte_x ≥ 10 = pipe on right side, reset
.next:
        inc     iy
        inc     iy
        inc     hl
        pop     bc
        djnz    .lp
        ret

; render_score: draw the 4-digit score at char row 22, cols 14–17 using the
; ROM character set (digit '0' = $3D80, +8 bytes per digit).
SCORE_DIGITS_ROW    EQU $50C0           ; char row 22 col 0 screen address
render_score:
        ld      hl, (score)
        ld      bc, 1000
        call    .get_digit
        ld      c, 14
        call    .draw_digit
        ld      bc, 100
        call    .get_digit
        ld      c, 15
        call    .draw_digit
        ld      bc, 10
        call    .get_digit
        ld      c, 16
        call    .draw_digit
        ld      a, l                    ; ones digit (HL < 10 here)
        ld      c, 17
        ; fall through

.draw_digit:
        ; A = digit (0..9), C = screen col. Writes 8 ROM-font bytes down a
        ; single char row (consecutive scanlines = HL + 256 each).
        push    hl
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl                  ; HL = digit * 8
        ld      de, $3D80
        add     hl, de                  ; HL = ROM font byte 0 for this digit
        ex      de, hl                  ; DE = font src
        ld      a, c
        add     a, $C0
        ld      l, a
        ld      h, $50                  ; HL = SCORE_DIGITS_ROW + col
        ld      b, 8
.row_lp:
        ld      a, (de)
        ld      (hl), a
        inc     de
        inc     h                       ; next scanline within the char row
        djnz    .row_lp
        pop     hl
        ret

.get_digit:
        ; HL = value, BC = divisor. Returns A = quotient, HL = remainder.
        xor     a
.gd_lp:
        or      a                       ; clear carry
        sbc     hl, bc
        jr      c, .gd_done
        inc     a
        jr      .gd_lp
.gd_done:
        add     hl, bc                  ; undo the overshoot
        ret

; bird_attr_addr: HL = ATTRS + (A >> 3) * 32 + 8, A = y_high.
;   (A & $F8) << 2 == char_row * 32 (since char_row*32 = (y>>3)*32 = y*4 once
;   the low 3 bits are masked off).
bird_attr_addr:
        and     $F8
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        ld      de, ATTRS + 8
        add     hl, de
        ret

; paint_bird_attrs: paint ONE char cell of yellow at col 8 of the char
; row containing the bird's vertical centre. Sprite is centred at col 8 so
; the colour-clash boundary is symmetric (4 px of sprite each side in cols
; 7 and 9, which keep their cyan sky attr).
paint_bird_attrs:
        ld      a, (bird_y + 1)
        add     a, 8                    ; +8 snaps to char row containing bird centre
        and     $F8
        ld      (bird_attr_y), a
        ld      a, 1
        ld      (bird_attr_valid), a
        ld      a, (bird_attr_y)
        call    bird_attr_addr
        ld      a, (hl)
        ld      (bird_attr_save), a
        ld      (hl), ATTR_BIRD
        ret

; restore_bird_attrs: write saved attr byte back at bird_attr_y's row.
restore_bird_attrs:
        ld      a, (bird_attr_valid)
        or      a
        ret     z
        ld      a, (bird_attr_y)
        call    bird_attr_addr
        ld      a, (bird_attr_save)
        ld      (hl), a
        ret

read_input:
        ld      a, $7F                  ; row B-N-M-Sym-Space
        in      a, ($fe)
        bit     0, a                    ; SPACE: bit 0 = 0 if pressed
        ret     nz
        ld      hl, FLAP_VY
        ld      (bird_vy), hl
        ret

update_bird:
        ld      hl, (bird_vy)
        ld      de, GRAVITY
        add     hl, de
        ld      (bird_vy), hl

        ex      de, hl                  ; DE = new vy
        ld      hl, (bird_y)
        add     hl, de
        ld      (bird_y), hl

        ld      a, d                    ; vy_high
        bit     7, a
        jr      nz, .vy_neg

        ; vy positive (falling): clamp y_high to <= 144
        ld      a, h
        cp      145
        ret     c
        ld      hl, $9000               ; y = 144.0
        ld      (bird_y), hl
        ld      hl, 0
        ld      (bird_vy), hl
        ret

.vy_neg:
        ; vy negative (rising): if y wrapped (y_high > 200), clamp to 0
        ld      a, h
        cp      200
        ret     c
        ld      hl, 0
        ld      (bird_y), hl
        ld      (bird_vy), hl
        ret

; draw_bird: masked draw across 3 cells (cols 7, 8, 9). Sprite is pre-shifted
; 4 px left so the 16-px-wide bird spans cols 7..9 with col 8 centred. Per
; row we read 6 sprite bytes: mask_c7, sprite_c7, mask_c8, sprite_c8,
; mask_c9, sprite_c9. Per cell: screen = (screen AND inv_mask) OR sprite.
draw_bird:
        ld      a, (bird_y + 1)
        ld      (bird_old_y), a
        ld      a, 1
        ld      (bird_old_y_valid), a

        ld      a, (bird_y + 1)
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      de, (bird_sprite_ptr)
        ld      b, BIRD_LINES
.lp:
        pop     hl
        ld      a, l
        or      7                       ; bits 0..2 → col 7 (sprite starts here)
        ld      l, a
        ; col 7
        ld      a, (de)
        and     (hl)
        ld      c, a
        inc     de
        ld      a, (de)
        or      c
        ld      (hl), a
        inc     de
        inc     hl                      ; → col 8
        ; col 8
        ld      a, (de)
        and     (hl)
        ld      c, a
        inc     de
        ld      a, (de)
        or      c
        ld      (hl), a
        inc     de
        inc     hl                      ; → col 9
        ; col 9
        ld      a, (de)
        and     (hl)
        ld      c, a
        inc     de
        ld      a, (de)
        or      c
        ld      (hl), a
        inc     de
        djnz    .lp
        ld      sp, (saved_sp)
        ret

; compute_bird_overlap: build a BIRD_LINES-byte mask describing which bird
; cells are covered by a pipe pixel after the line-major pipe render.
; Bit 0 of byte N = some pipe drew at col 8 on bird's row N. Bit 1 = col 9.
; Called by restore_bird_bg right before it touches the screen.
compute_bird_overlap:
        ld      hl, bird_overlap
        xor     a
        ld      b, BIRD_LINES
.clear:
        ld      (hl), a
        inc     hl
        djnz    .clear

        ld      iy, pipe_state
        ld      b, ACTIVE_PIPES                 ; Phase 3: only check active pipes 0..2
.pipe_lp:
        push    bc
        ld      a, (iy+0)               ; byte_x
        ld      c, 0                    ; per-pipe col coverage bits
        cp      6
        jr      c, .skip                ; byte_x < 6 → no overlap with cols 8/9
        cp      11
        jr      nc, .skip               ; byte_x ≥ 11 → no overlap
        ; byte_x in [6, 10]. byte_x covers cols [byte_x-1 .. byte_x+2].
        ; col 8 covered if byte_x in [6, 9]; col 9 if byte_x in [7, 10].
        cp      10
        jr      nc, .check9
        set     0, c                    ; covers col 8
.check9:
        cp      7
        jr      c, .have_mask
        set     1, c                    ; covers col 9
.have_mask:
        ld      a, c
        or      a
        jr      z, .skip

        ; This pipe covers at least one bird col. For each bird line, if the
        ; pipe is drawing (not in gap), OR its mask bits into bird_overlap[N].
        ld      a, (iy+1)
        ld      d, a                    ; D = gap_y (= capt + 1)
        ld      a, (bird_old_y)
        ld      e, a                    ; E = current bird row
        ld      hl, bird_overlap
        push    bc                      ; preserve pipe loop counter
        ld      b, BIRD_LINES
.line_lp:
        ld      a, e
        cp      d
        jr      c, .draws               ; row < gap_y → top body / top cap, drawn
        sub     d                       ; row - gap_y
        cp      PIPE_GAP
        jr      c, .next_line           ; in [0, PIPE_GAP) → gap row, not drawn
.draws:
        ld      a, (hl)
        or      c
        ld      (hl), a
.next_line:
        inc     hl
        inc     e
        djnz    .line_lp
        pop     bc
.skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .pipe_lp
        ret

restore_bird_bg:
        ld      a, (bird_old_y_valid)
        or      a
        ret     z

        ld      a, (bird_old_y)
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      b, BIRD_LINES
        ; Clear all 3 bird cells (cols 7, 8, 9). Pipes will re-stamp on the
        ; following frame at any col they still cover.
.lp:
        pop     hl
        ld      a, l
        or      7                       ; → col 7
        ld      l, a
        ld      (hl), 0
        inc     hl                      ; → col 8
        ld      (hl), 0
        inc     hl                      ; → col 9
        ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

;----------------------------------------------------------------
; Cap routines
;----------------------------------------------------------------

;----------------------------------------------------------------
; update_pipe_attrs:
;   Full attr refill (sky/ground/scoreboard), then overwrite cells that
;   currently contain pipe pixels with ATTR_PIPE (paper green + ink black).
;----------------------------------------------------------------
update_pipe_attrs:
        call    refill_base_attrs       ; full attr refill (slow path, init only)
        ; fall through to apply_pipe_attrs

;----------------------------------------------------------------
; apply_pipe_attrs: for each pipe, overlay ATTR_PIPE at M1/M2 cells.
; Reads pipe_state; chooses the right per-row routine based on byte_x.
; Used at init (paints both M1 and M2 from sky base).
;----------------------------------------------------------------
apply_pipe_attrs:
        ld      iy, pipe_state
        ld      b, NUM_PIPES                    ; iterate all 4 pipes, skip prep_pipe_idx
.lp:
        push    bc
        ; current pipe index = NUM_PIPES - B (B counts down 4→1, idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .skip                        ; skip the preparing pipe
        ld      a, (iy+0)
        cp      4                       ; M1 must be visible (byte_x ≥ 4)
        jr      c, .skip
        cp      27                      ; M2 must be visible (byte_x ≤ 26)
        jr      nc, .skip
        ld      c, a
        ld      a, (iy+1)
        ld      e, a
        call    paint_pipe_attrs_inner
.skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .lp
        ret

;----------------------------------------------------------------
; apply_pipe_attrs_wrap: WRAP-TIME variant. Paints ATTR_PIPE only at
; NEW M1 (col = byte_x). Skips NEW M2 (= OLD M1, already ATTR_PIPE
; from last frame). Saves ~16 T per body row × ~14 rows × 3 pipes
; ≈ 670 T per wrap frame vs the 2-col init-time variant.
;
; Range: byte_x in [4, 27] — wider than the init variant ([4, 26])
; because we only need M1 visible, not M1+M2. Bonus: paints the
; first-visible-row case (byte_x=27 → col 27 = right-edge of playfield).
;----------------------------------------------------------------
apply_pipe_attrs_wrap:
        ld      iy, pipe_state
        ld      b, NUM_PIPES                    ; iterate all 4 pipes, skip prep_pipe_idx
.lp:
        push    bc
        ; current pipe index = NUM_PIPES - B (B counts down 4→1, idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .skip                        ; skip the preparing pipe
        ld      a, (iy+0)
        cp      4
        jr      c, .skip
        cp      28
        jr      nc, .skip
        ld      c, a
        ld      a, (iy+1)
        ld      e, a
        call    paint_pipe_attrs_inner_1col
.skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .lp
        ret

;----------------------------------------------------------------
; refill_base_attrs: LDIR sky + ground + scoreboard attr bands, then buffer
; cols. Used once at init to set up BACKUP_ATTRS.
;----------------------------------------------------------------
refill_base_attrs:
        ld      hl, ATTRS
        ld      de, ATTRS + 1
        ld      (hl), ATTR_SKY
        ld      bc, 20 * 32 - 1
        ldir
        inc     hl
        ld      (hl), ATTR_GROUND
        ld      d, h
        ld      e, l
        inc     de
        ld      bc, 1 * 32 - 1
        ldir
        inc     hl
        ld      (hl), ATTR_SCOREBOARD
        ld      d, h
        ld      e, l
        inc     de
        ld      bc, 3 * 32 - 1
        ldir
        jp      paint_buffer_attrs      ; tail-call: overlay invisible attr in buffer cols

;----------------------------------------------------------------
; backup_base_attrs: copy ATTRS → BACKUP_ATTRS. Called once at init after
; refill_base_attrs so BACKUP_ATTRS holds the "no pipes" base.
;----------------------------------------------------------------
backup_base_attrs:
        ld      hl, ATTRS
        ld      de, BACKUP_ATTRS
        ld      bc, 768
        ldir
        ret

;----------------------------------------------------------------
; restore_pipe_attrs: per-pipe, restore base attrs at CURRENT (= about-to-be-old)
; pipe cells. Called BEFORE wrap_byte_x so pipe_state still has old positions.
; After this + wrap_byte_x + apply_pipe_attrs, ATTRS reflects new positions
; without needing a full refill.
;----------------------------------------------------------------
restore_pipe_attrs:
        ld      iy, pipe_state
        ld      b, NUM_PIPES                    ; iterate all 4 pipes, skip prep_pipe_idx
.lp:
        push    bc
        ; current pipe index = NUM_PIPES - B (B counts down 4→1, idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .skip                        ; skip the preparing pipe
        ld      a, (iy+0)
        cp      4                       ; M1 must be in visible playfield (≥4)
        jr      c, .skip
        cp      27                      ; M2 must be ≤27 → byte_x ≤ 26
        jr      nc, .skip
        ld      c, a
        ld      a, (iy+1)
        ld      e, a
        call    restore_pipe_attrs_inner
.skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .lp
        ret

;----------------------------------------------------------------
; restore_trailing_pipe_attrs: deferred end-of-frame cleanup after wrap.
; byte_x was decremented; the OLD M2 cell is now at (current byte_x + 2),
; which apply_pipe_attrs left green from last frame. Un-green just that
; column (NEW M1 = byte_x and NEW M2 = byte_x+1 stay green — we already
; repainted them this frame).
;----------------------------------------------------------------
restore_trailing_pipe_attrs:
        ld      iy, pipe_state
        ld      b, NUM_PIPES                    ; iterate all 4 pipes, skip prep_pipe_idx
.lp:
        push    bc
        ; current pipe index = NUM_PIPES - B (B counts down 4→1, idx = 0..3)
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = current pipe index
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .skip                        ; skip the preparing pipe
        ld      a, (iy+0)
        add     a, 2                    ; OLD M2 = current byte_x + 2
        cp      4
        jr      c, .skip
        cp      28                      ; in visible playfield? (col ≤27)
        jr      nc, .skip
        ld      c, a
        ld      a, (iy+1)
        ld      e, a
        call    restore_pipe_attrs_inner_1col
.skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .lp
        ret
;----------------------------------------------------------------
; paint_buffer_attrs: overlay invisible attr at buffer cols (0-3, 28-31)
; in rows 0-19 — pipes scrolling through these cols render invisibly because
; paper = ink, so no edge-case clipping needed in the dispatcher.
;----------------------------------------------------------------
paint_buffer_attrs:
        ld      a, ATTR_BUFFER
        ld      c, 24                   ; rows 0..23 — whole screen height
        ld      hl, ATTRS
.row_lp:
        ld      b, 4
.lp1:
        ld      (hl), a
        inc     hl
        djnz    .lp1
        ld      de, 24
        add     hl, de                  ; skip cols 4..27 (visible playfield)
        ld      b, 4
.lp2:
        ld      (hl), a
        inc     hl
        djnz    .lp2                    ; HL now at next row col 0
        dec     c
        jr      nz, .row_lp
        ret

;----------------------------------------------------------------
; paint_pipe_attrs_inner_2col: same as _inner but paints 2 cells per row.
; Used when only two body cells are on-screen (byte_x = 31, body at 30/31,
; or byte_x = 255 (-1), body at 0/1).
;----------------------------------------------------------------
paint_pipe_attrs_inner_2col:
        ld      a, e
        or      a
        jr      z, .no_top
        dec     a
        srl     a
        srl     a
        srl     a
        inc     a
        ld      b, a
        xor     a
        call    paint_attr_rows_2col
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        jr      c, .done
        add     a, 7
        jr      c, .done
        srl     a
        srl     a
        srl     a
        cp      20
        jr      nc, .done
        ld      d, a
        ld      a, 20
        sub     d
        ld      b, a
        ld      a, d
        call    paint_attr_rows_2col
.done:
        ret

;----------------------------------------------------------------
; paint_attr_rows_2col: paint ATTR_PIPE at cols C and C+1 for B rows.
; Preserves DE.
;----------------------------------------------------------------
paint_attr_rows_2col:
        push    de
        push    bc
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        ld      de, ATTRS
        add     hl, de
        ld      d, 0
        ld      e, c
        add     hl, de
        pop     bc
.row_lp:
        ld      (hl), ATTR_PIPE
        inc     hl
        ld      (hl), ATTR_PIPE
        ld      a, l
        add     a, 31
        ld      l, a
        jr      nc, .nc
        inc     h
.nc:
        djnz    .row_lp
        pop     de
        ret

;----------------------------------------------------------------
; paint_pipe_attrs_inner_1col: same as _inner but paints 1 cell per row.
; Used when only one interior cell is on-screen (byte_x = 32, body at 31,
; or byte_x = 254 (-2), body at 0).
;----------------------------------------------------------------
paint_pipe_attrs_inner_1col:
        ld      a, e
        or      a
        jr      z, .no_top
        dec     a
        srl     a
        srl     a
        srl     a
        inc     a
        ld      b, a
        xor     a
        call    paint_attr_rows_1col
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        jr      c, .done
        add     a, 7
        jr      c, .done
        srl     a
        srl     a
        srl     a
        cp      20
        jr      nc, .done
        ld      d, a
        ld      a, 20
        sub     d
        ld      b, a
        ld      a, d
        call    paint_attr_rows_1col
.done:
        ret

;----------------------------------------------------------------
; paint_attr_rows_1col: paint ATTR_PIPE at single col C for B rows starting
; at row A. Preserves DE.
;----------------------------------------------------------------
paint_attr_rows_1col:
        push    de
        push    bc
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        ld      de, ATTRS
        add     hl, de
        ld      d, 0
        ld      e, c
        add     hl, de
        pop     bc
.row_lp:
        ld      (hl), ATTR_PIPE
        ld      a, l
        add     a, 32
        ld      l, a
        jr      nc, .nc
        inc     h
.nc:
        djnz    .row_lp
        pop     de
        ret

; in: C = byte_x (0..31), E = gap_y
paint_pipe_attrs_inner:
        ld      a, e
        or      a
        jr      z, .no_top
        dec     a
        srl     a
        srl     a
        srl     a                       ; (gap_y-1)/8 = last row containing pipe pixel
        inc     a                       ; top row count
        ld      b, a
        xor     a                       ; start row 0
        call    paint_attr_rows
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        jr      c, .done
        add     a, 7
        jr      c, .done
        srl     a
        srl     a
        srl     a                       ; ceil((gap_y+GAP)/8) = bot_start
        cp      20                      ; stop at ground band (row 20 = line 160)
        jr      nc, .done
        ld      d, a
        ld      a, 20
        sub     d
        ld      b, a                    ; bot row count (clamped above ground)
        ld      a, d
        call    paint_attr_rows
.done:
        ret

; in: A = start row, B = row count, C = byte_x
; Paints ATTR_PIPE at byte_x (M1) and byte_x+1 (M2) — 2 cells = 16 px green.
; L cell (byte_x-1) and R cell (byte_x+2) stay sky → sky spills into pipe
; at both walls.
paint_attr_rows:
        push    de                       ; preserve caller's gap_y in E
        push    bc
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                  ; HL = row * 32
        ld      de, ATTRS
        add     hl, de                  ; HL = ATTRS + row*32
        ld      d, 0
        ld      e, c                    ; col byte_x
        add     hl, de                  ; HL = ATTRS + row*32 + byte_x
        pop     bc
.row_lp:
        ld      (hl), ATTR_PIPE         ; col byte_x (M1)
        inc     hl
        ld      (hl), ATTR_PIPE         ; col byte_x+1 (M2)
        ld      a, l
        add     a, 31                   ; advance from byte_x+1 to next row's byte_x
        ld      l, a
        jr      nc, .no_carry
        inc     h
.no_carry:
        djnz    .row_lp
        pop     de                       ; restore caller's gap_y
        ret

;----------------------------------------------------------------
; paint_pipe_attrs_inner_1col / paint_attr_rows_1col live further down
; (originally added for edge-case byte_x=32 single-cell paint).
; apply_pipe_attrs_wrap reuses them — no duplication needed here.
;----------------------------------------------------------------

;----------------------------------------------------------------
; restore_pipe_attrs_inner: mirror of paint_pipe_attrs_inner that copies
; base attrs from BACKUP_ATTRS into ATTRS at M1, M2 cells across the pipe
; body rows. Used to clear OLD pipe attrs before wrap_byte_x advances.
;----------------------------------------------------------------
restore_pipe_attrs_inner:
        ld      a, e
        or      a
        jr      z, .no_top
        dec     a
        srl     a
        srl     a
        srl     a
        inc     a
        ld      b, a
        xor     a
        call    restore_attr_rows
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        jr      c, .done
        add     a, 7
        jr      c, .done
        srl     a
        srl     a
        srl     a
        cp      20
        jr      nc, .done
        ld      d, a
        ld      a, 20
        sub     d
        ld      b, a
        ld      a, d
        call    restore_attr_rows
.done:
        ret

restore_pipe_attrs_inner_1col:
        ld      a, e
        or      a
        jr      z, .no_top
        dec     a
        srl     a
        srl     a
        srl     a
        inc     a
        ld      b, a
        xor     a
        call    restore_attr_rows_1col
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        jr      c, .done
        add     a, 7
        jr      c, .done
        srl     a
        srl     a
        srl     a
        cp      20
        jr      nc, .done
        ld      d, a
        ld      a, 20
        sub     d
        ld      b, a
        ld      a, d
        call    restore_attr_rows_1col
.done:
        ret

;----------------------------------------------------------------
; restore_attr_rows: read 2 cells at (row*32+C, row*32+C+1) from BACKUP_ATTRS
; and write to ATTRS, for B rows starting at row A. Preserves DE.
; BACKUP_ATTRS is at HL | $8000 (set 7,h → backup, res 7,h → attrs).
;----------------------------------------------------------------
restore_attr_rows:
        push    de
        push    bc
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                  ; HL = row * 32
        ld      de, ATTRS
        add     hl, de
        ld      d, 0
        ld      e, c
        add     hl, de                  ; HL = ATTRS + row*32 + byte_x
        pop     bc
.row_lp:
        set     7, h                    ; HL → BACKUP_ATTRS
        ld      a, (hl)
        res     7, h                    ; HL → ATTRS
        ld      (hl), a                 ; restore M1
        inc     hl
        set     7, h
        ld      a, (hl)
        res     7, h
        ld      (hl), a                 ; restore M2
        ld      a, l
        add     a, 31
        ld      l, a
        jr      nc, .nc
        inc     h
.nc:
        djnz    .row_lp
        pop     de
        ret

;----------------------------------------------------------------
; restore_attr_rows_1col: same as restore_attr_rows but 1 cell per row.
;----------------------------------------------------------------
restore_attr_rows_1col:
        push    de
        push    bc
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        ld      de, ATTRS
        add     hl, de
        ld      d, 0
        ld      e, c
        add     hl, de
        pop     bc
.row_lp:
        set     7, h
        ld      a, (hl)
        res     7, h
        ld      (hl), a
        ld      a, l
        add     a, 32
        ld      l, a
        jr      nc, .nc
        inc     h
.nc:
        djnz    .row_lp
        pop     de
        ret

;----------------------------------------------------------------
line_table:
Y = 0
        DUP 192
        dw $4000 + ((Y & 7) << 8) + ((Y & $38) << 2) + ((Y & $C0) << 5)
Y = Y + 1
        EDUP

        SAVESNA "build/main.sna", start
