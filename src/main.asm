        DEVICE  ZXSPECTRUM48

;----------------------------------------------------------------
; Speccy Flappy Bird — sky/pipes/ground/scoreboard rendering at 50Hz.
;
; Per frame: PIPE_PROGRAM (SMC slot grid at $DB00) emits all 160 pipe-band
; scan lines via stack-blast pushes, then bird + ground + scoreboard.
; Pipes scroll by 2 px per frame; on each phase wrap, byte_x decrements
; and per-pipe slot templates are reconfigured.
;----------------------------------------------------------------

NUM_PIPES   EQU 3
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
ATTR_BIRD       EQU $70                 ; bright yellow paper + black ink
ATTR_BUFFER     EQU $2D                 ; paper cyan + ink cyan — invisible buffer cols (0-3, 28-31)
GROUND_TOP      EQU 160                 ; first scan line of ground band — pipes stop here
SCORE_TOP       EQU 168                 ; first scan line of scoreboard band (= ground+8)

; ─── Slot grid layout (fixed-slot dispatch) ──────────────────────
; All 160 rows use a 5-byte normal slot template:
;   ld sp,target ; push de ; push bc
; The epilogue sits immediately after row 159's last slot so PIPE_PROGRAM
; falls straight through into `ld sp,(saved_sp) ; ret` with no NOP slide.
SLOT_GRID_BASE         EQU $DB00
SLOT_GRID_END          EQU SLOT_GRID_BASE + 160 * 16   ; $E500
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

SLOT_ROW_STRIDE        EQU 16          ; 1 (exx) + 3*5
SLOT_STRIDE            EQU 5

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

; ─── Pre-computed slot addresses ─────────────────────────────────
SLOT_ADDR_TABLE        EQU $F440       ; 480 entries × 2 B = 960 B
SLOT_ADDR_TABLE_END    EQU $F800

; ─── Active list (per-pipe sublists) ─────────────────────────────
ACTIVE_PIPE_0          EQU $FA40       ; 112 entries × 2 B = 224 B
ACTIVE_PIPE_1          EQU ACTIVE_PIPE_0 + 224
ACTIVE_PIPE_2          EQU ACTIVE_PIPE_1 + 224
ACTIVE_LIST_END        EQU ACTIVE_PIPE_2 + 224       ; $FD10
ACTIVE_COUNT           EQU 336         ; constant; all three sublists × 112

ACTIVE_LIST_NEW        EQU ACTIVE_PIPE_0
ACTIVE_COUNT_NEW       EQU $FD10       ; 2 B counter

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
        ld      a, 2                    ; PROFILE: RED = pre-frame_update overhead (tiny)
        out     ($fe), a
        call    frame_update
        ld      a, 5                    ; PROFILE: CYAN = idle until next halt
        out     ($fe), a
        ei
        jr      main_loop

;----------------------------------------------------------------
phase:      db 0
saved_sp:   dw 0
saved_sp_inner: dw 0                    ; second save slot — inner CALL inside
                                        ; the SP-hijacked line loop swaps SP
                                        ; back to caller stack so the return
                                        ; address doesn't overwrite line_table.
ground_iy_save: dw 0

pipe_state:
        ; 3 pipes distributed around the 29-step byte_x cycle (byte_x ∈ [1,29]).
        ; Buffer cols 0-3 and 28-31 have attr ink=paper so pipe parts there
        ; render invisibly. Initial gap_y values arbitrary (randomised on wrap).
        db 29, 64                       ; pipe just entering from right buffer
        db 19, 40
        db  9, 88

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
pipe_scored:  db 0, 0, 0
scroll_extra: db 0                      ; mod-5 counter for 1.2 px/frame avg
wrap_pending:  db 0                      ; set when a wrap happened this frame
pending_regen: db 0                      ; set when a recycle happened; configure_pipe_slots deferred
patch_pending: db 0                      ; set by wrap_byte_x when byte_x changed; cleared after patch_pipe_targets runs
recycled_pipe_idx: db 0

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

; Yellow-paper attr cell — 1 char row (8 px) snapped to the row that holds
; the bird's vertical centre. Top/bottom of sprite are filled with dense ink
; (rows 2, 3, 12) so the bird's pixels on the neighbouring SKY rows render
; as solid black silhouette — the cyan paper clash is hidden by ink density.
bird_attr_y:        db 0
bird_attr_valid:    db 0
bird_attr_save:     ds 2

; Bird animation — wing flap cycles 0→1→2→0 every BIRD_ANIM_RATE frames.
BIRD_ANIM_RATE      EQU 6
BIRD_FRAME_BYTES    EQU 64              ; 16 rows × (mask + sprite) × 2 cols
bird_anim_tick:     db 0
bird_anim_phase:    db 1                ; start in wing-mid pose
bird_sprite_ptr:    dw bird_sprite_f1

; Flappy Bird, 16×16 line-art matching the original mobile sprite:
;   - Stepped flat-top head (cols 4–9 row 1, shoulders rows 2–4)
;   - Hollow 3×3 eye at cols 5–7 rows 3–6
;   - Open beak: top bar row 6 cols 13–15, bottom bar row 8 cols 13–15,
;     row 7 cols 13–15 transparent (mouth interior shows background)
;   - Hollow rectangular wing, animated rows 8–11 → 9–12 → 10–13
;   - Three horizontal tail stripes OR'd onto bg at cols 13–15 rows 9, 11, 13
;
; Stored as 4 bytes/row interleaved: inv_maskL, spriteL, inv_maskR, spriteR.
; draw_bird does  screen = (screen AND inv_mask) OR sprite.
; Body silhouette has inv_mask=0 (interior cleared then OR'd) so pipe pixels
; don't bleed through — bird interior reads as paper (yellow in the ATTR_BIRD
; char row, sky cyan above/below). Beak bars and tail stripes use inv_mask=1
; so they OR onto the background as floating black lines.

bird_sprite_f0:                         ; wing UP — wing box rows 8–11
        db $FF, $00, $FF, $00           ; row  0  ................
        db $F0, $0F, $3F, $C0           ; row  1  ....@@@@@@......   head top
        db $C0, $30, $0F, $30           ; row  2  ..@@......@@....   head shoulders
        db $80, $47, $07, $08           ; row  3  .@...@@@....@...   head + eye top
        db $80, $45, $07, $08           ; row  4  .@...@.@....@...   eye sides
        db $00, $85, $07, $08           ; row  5  @....@.@....@...   eye sides
        db $00, $87, $07, $0F           ; row  6  @....@@@....@@@@   eye bottom + beak top
        db $00, $80, $07, $08           ; row  7  @...........@...   mouth interior (gap)
        db $00, $BE, $07, $0F           ; row  8  @.@@@@@.....@@@@   wing top + beak bottom
        db $00, $A2, $07, $0F           ; row  9  @.@...@.....@@@@   wing sides + tail stripe
        db $00, $A2, $07, $08           ; row 10  @.@...@.....@...   wing sides
        db $00, $BE, $07, $0F           ; row 11  @.@@@@@.....@@@@   wing bottom + tail stripe
        db $00, $80, $07, $08           ; row 12  @...........@...
        db $80, $40, $0F, $17           ; row 13  .@.........@@@@@   body narrow + tail stripe
        db $C0, $3F, $1F, $E0           ; row 14  ..@@@@@@@@@.....   bottom curve
        db $FF, $00, $FF, $00           ; row 15  ................

bird_sprite_f1:                         ; wing MID — wing box rows 9–12
        db $FF, $00, $FF, $00
        db $F0, $0F, $3F, $C0
        db $C0, $30, $0F, $30
        db $80, $47, $07, $08
        db $80, $45, $07, $08
        db $00, $85, $07, $08
        db $00, $87, $07, $0F
        db $00, $80, $07, $08
        db $00, $80, $07, $0F           ; row  8  beak bottom only
        db $00, $BE, $07, $0F           ; row  9  wing top + tail stripe
        db $00, $A2, $07, $08           ; row 10  wing sides
        db $00, $A2, $07, $0F           ; row 11  wing sides + tail stripe
        db $00, $BE, $07, $08           ; row 12  wing bottom
        db $80, $40, $0F, $17           ; row 13  body narrow + tail stripe
        db $C0, $3F, $1F, $E0           ; row 14  bottom curve
        db $FF, $00, $FF, $00

bird_sprite_f2:                         ; wing DOWN — wing box rows 10–13
        db $FF, $00, $FF, $00
        db $F0, $0F, $3F, $C0
        db $C0, $30, $0F, $30
        db $80, $47, $07, $08
        db $80, $45, $07, $08
        db $00, $85, $07, $08
        db $00, $87, $07, $0F
        db $00, $80, $07, $08
        db $00, $80, $07, $0F           ; row  8  beak bottom only
        db $00, $80, $07, $0F           ; row  9  body + tail stripe
        db $00, $BE, $07, $08           ; row 10  wing top
        db $00, $A2, $07, $0F           ; row 11  wing sides + tail stripe
        db $00, $A2, $07, $08           ; row 12  wing sides
        db $80, $7E, $0F, $17           ; row 13  wing bottom + body narrow + tail stripe
        db $C0, $3F, $1F, $E0           ; row 14  bottom curve
        db $FF, $00, $FF, $00

; Ground tiles — 8x8 pattern, 4 phases of horizontal scroll.
;   Row 0: $FF — solid black top edge.
;   Rows 1..6: "/" diagonal (period 4 horizontally).
;   Row 7: $AA / $55 — dotted bottom edge (period 2 horizontally).
; All rows cyclically shift left by 1 px per phase.
ground_tiles:
        db $FF, $11, $22, $44, $88, $11, $22, $AA   ; phase 0
        db $FF, $22, $44, $88, $11, $22, $44, $55   ; phase 1 (shifted left 1px)
        db $FF, $44, $88, $11, $22, $44, $88, $AA   ; phase 2 (shifted left 2px)
        db $FF, $88, $11, $22, $44, $88, $11, $55   ; phase 3 (shifted left 3px)

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
; Layout: SLOT_GRID_BASE + row*16 + 1 + pipe*5 for all 160 rows.
;
; Entry index: row*3 + pipe (16-bit address per entry).
; Total table size: 480 × 2 = 960 bytes at SLOT_ADDR_TABLE.
;----------------------------------------------------------------
init_slot_addr_table:
        ld      ix, SLOT_ADDR_TABLE
        ld      b, 0
.row_lp:
        push    bc
        ld      l, b
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; HL = row × 16
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de
        ex      de, hl                          ; DE = base addr for pipe 0
        ld      c, SLOT_STRIDE

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

;----------------------------------------------------------------
; init_pipe_program: emit the initial slot grid into PIPE_PROGRAM
; memory ($DB00+).  Caller must call init_slot_addr_table first
; (this routine assumes the table is already populated).
;
; Walks rows 0..159.  For each row:
;   - Reads slot[row][0] address from SLOT_ADDR_TABLE (entry index
;     row*3, 2-byte little-endian address).
;   - Writes $D9 (EXX) at (slot[row][0] - 1).
;   - Writes 3 × 5-byte body templates for pipes 0-2.
;
; After the loop writes the 5-byte epilogue at SLOT_GRID_END:
;   ED 7B lo hi C9  =  ld sp,(saved_sp) ; ret
;
; Scratch: ipp_byte_x (3 bytes) caches byte_x for each pipe so we
; don't touch pipe_state during the inner loop.
;
; Register usage (outer loop):
;   B  = row (0..159)
;   IY = write cursor (slot[row][0] for each row, advances per pipe)
;   HL = address scratch
;   DE = address scratch / cache_addr
;   C  = pipe index (0..2) in inner loops
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

        ld      b, 0                    ; row counter 0..159
.ipp_row_lp:
        push    bc                      ; save B=row

        ; ── Look up slot[row][0] address from SLOT_ADDR_TABLE ─────
        ; Table entry index = row*3 + pipe (pipe=0 here).
        ; Each entry is 2 bytes → byte offset = (row*3)*2 = row*6.
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      d, h
        ld      e, l                    ; DE = row*2
        add     hl, hl                  ; row*4
        add     hl, de                  ; row*6
        ld      de, SLOT_ADDR_TABLE
        add     hl, de                  ; HL → table[row*3]
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

        ; All 160 rows: 3 × 5-byte body template
        ;   $31 lo hi $D5 $C5  =  ld sp,target ; push de ; push bc
        ld      c, 0                    ; pipe index
.ipp_pipe_lp:
        ; Compute screen_target = line_table[B] + byte_x[C] + 3
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
        add     a, 3                    ; +3 for stack-blast offset
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = screen_target

        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $D5             ; push de
        ld      (iy+4), $C5             ; push bc
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

ipp_byte_x:     ds 3, 0                 ; scratch: byte_x per pipe (3 bytes)
init_pipe_bx_tmp: db 0                 ; scratch: byte_x for the pipe being configured at init

;----------------------------------------------------------------
; configure_pipe_slots(A=pipe 0..2, E=new_gap_y 1..111)
;
; Incremental reconfigure of all 160 slots for one pipe.
; Row type classification:
;   row == new_gap_y - 1                  -> cap_top
;   row == new_gap_y + PIPE_GAP           -> cap_bot
;   new_gap_y <= row < new_gap_y+PIPE_GAP -> skip
;   otherwise                             -> body
;
; For rows whose type is body in BOTH the previous and new config,
; only ADD 28 to the slot's lo-byte (with carry to hi-byte) instead
; of full re-stamping. Only rows whose type changed get a full stamp.
; pipe_prev_cap_top/bot track the previous call's cap positions;
; sentinel $FF means 'no prior call' and forces a full stamp.
;
; Also rebuilds that pipe's active sublist (ACTIVE_PIPE_N).
; After the row loop, patches cap_top/cap_bot handler target imms.
; Finally stores new_gap_y -> pipe_state[pipe*2 + 1].
;
; In:  A = pipe (0..2)
;      E = gap_y (multiple of 8 in 8..96)
;     B, C = ignored (kept for caller-compat with prior signature)
; Clobbers: AF, BC, DE, HL, IX, IY.
;
; Recycle cost: ~22k T-states (down from ~42k template-stamp).
;----------------------------------------------------------------
configure_pipe_slots:
        ; --- Prologue: save args ---
        ld      (cps_pipe), a
        ld      a, e
        ld      (cps_gap_y), a
        dec     a
        ld      (cps_cap_top_row), a
        ld      a, e
        add     a, PIPE_GAP
        ld      (cps_cap_bot_row), a

        ; Load OLD cap rows from pipe_prev_cap_top/bot[pipe]
        ld      a, (cps_pipe)
        ld      hl, pipe_prev_cap_top
        add     a, l
        ld      l, a
        jr      nc, .cps_pct_nc
        inc     h
.cps_pct_nc:
        ld      a, (hl)
        ld      (cps_old_cap_top_row), a

        ld      a, (cps_pipe)
        ld      hl, pipe_prev_cap_bot
        add     a, l
        ld      l, a
        jr      nc, .cps_pcb_nc
        inc     h
.cps_pcb_nc:
        ld      a, (hl)
        ld      (cps_old_cap_bot_row), a

        ; HL = slot[0][pipe]+1 (target imm lo addr for row 0). We walk
        ; row-by-row and dispatch based on type.
        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e            ; pipe * 5
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 1
        add     hl, de          ; HL = slot[0][pipe]
        push    hl
        pop     iy              ; IY = slot[0][pipe]  (full slot start, points at $31 or $C3 or $00)

        ; --- Walk rows 0..159 ---
        ; For each row R, compute NEW type and OLD type, then dispatch.
        ; Type encoding: 0 = body, 1 = cap_top, 2 = skip, 3 = cap_bot
        ;
        ; Performance: most rows are body->body, so we want that path fast.
        ; We compute NEW type from R vs NEW gap_y, OLD type from R vs
        ; OLD gap_y. If both are body, just ADD 28 to lo byte of slot.
        ; Else, full re-stamp from BODY_TEMPLATE / CAP_BLOCK as needed.

        ld      b, 0            ; B = current row R

.cps_walk_lp:
        ; Determine NEW_type for row B
        ;   = body  if B < NEW_cap_top_row OR B > NEW_cap_bot_row
        ;   = cap_top if B == NEW_cap_top_row
        ;   = cap_bot if B == NEW_cap_bot_row
        ;   = skip otherwise

        ld      a, (cps_cap_top_row)
        cp      b
        jp      z, .cps_new_cap_top
        ld      a, (cps_cap_bot_row)
        cp      b
        jp      z, .cps_new_cap_bot
        ; NEW is body or skip
        ld      a, (cps_cap_top_row)
        cp      b
        jp      c, .cps_new_maybe_skip   ; NEW_cap_top < b -> b above top -> maybe skip
        ; NEW_cap_top > b -> b above cap_top -> NEW is body
        jp      .cps_new_body
.cps_new_maybe_skip:
        ld      a, b
        ld      hl, cps_cap_bot_row
        cp      (hl)
        jp      c, .cps_new_skip         ; b < NEW_cap_bot -> in skip region
        jp      .cps_new_body            ; b > NEW_cap_bot -> body below

        ; --- NEW is body (most common path) ---
.cps_new_body:
        ; Compare with OLD type. If OLD was also body, just add 28 to lo.
        ld      a, (cps_old_cap_top_row)
        cp      $FF
        jp      z, .cps_body_full_stamp  ; sentinel: no prior call -> full stamp
        cp      b
        jp      z, .cps_body_full_stamp  ; OLD type was cap_top, now body -> full stamp
        ld      a, (cps_old_cap_bot_row)
        cp      b
        jp      z, .cps_body_full_stamp  ; OLD type was cap_bot, now body -> full stamp
        ; OLD might be body or skip. If b in [old_cap_top, old_cap_bot], OLD was skip; else body.
        ld      a, (cps_old_cap_top_row)
        cp      b
        jp      nc, .cps_body_add_28     ; OLD_cap_top >= b -> b at or above old gap top -> was body
        ld      a, b
        ld      hl, cps_old_cap_bot_row
        cp      (hl)
        jp      nc, .cps_body_add_28     ; b >= OLD_cap_bot -> was body (at or below)
        ; Else: OLD was skip -> full stamp.
        jp      .cps_body_full_stamp

.cps_body_add_28:
        ; ADD 28 to (iy+1) lo byte with carry to (iy+2) hi byte.
        ld      a, (iy+1)
        add     a, 28
        ld      (iy+1), a
        jr      nc, .cps_body_add_done
        inc     (iy+2)
.cps_body_add_done:
        jp      .cps_walk_advance

.cps_body_full_stamp:
        ; Stamp full body slot: $31, line_table[B].lo+32, line_table[B].hi, $D5, $C5
        ld      a, $31
        ld      (iy+0), a
        push    bc
        ld      l, b
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      a, (hl)
        add     a, 32
        ld      (iy+1), a
        inc     hl
        ld      a, (hl)
        adc     a, 0
        ld      (iy+2), a
        pop     bc
        ld      a, $D5
        ld      (iy+3), a
        ld      a, $C5
        ld      (iy+4), a
        jp      .cps_walk_advance

.cps_new_cap_top:
        ; Stamp cap_top slot at this row.
        ld      a, $C3
        ld      (iy+0), a
        xor     a
        ld      (iy+1), a       ; handler addr patched later (step 3)
        ld      (iy+2), a
        ld      (iy+3), a
        ld      (iy+4), a
        jp      .cps_walk_advance

.cps_new_cap_bot:
        ld      a, $C3
        ld      (iy+0), a
        xor     a
        ld      (iy+1), a
        ld      (iy+2), a
        ld      (iy+3), a
        ld      (iy+4), a
        jp      .cps_walk_advance

.cps_new_skip:
        ; Only stamp zeros if OLD was NOT also skip.
        ld      a, (cps_old_cap_top_row)
        cp      $FF
        jp      z, .cps_skip_stamp       ; sentinel: stamp
        cp      b
        jp      z, .cps_skip_stamp       ; OLD was cap_top, now skip -> stamp
        ld      a, (cps_old_cap_bot_row)
        cp      b
        jp      z, .cps_skip_stamp       ; OLD was cap_bot, now skip -> stamp
        ld      a, (cps_old_cap_top_row)
        cp      b
        jp      nc, .cps_skip_stamp      ; OLD_cap_top >= b -> b at/above old gap -> was body -> stamp
        ld      a, b
        ld      hl, cps_old_cap_bot_row
        cp      (hl)
        jp      nc, .cps_skip_stamp      ; b >= OLD_cap_bot -> was body below old gap -> stamp
        ; OLD was also skip -> no stamp needed.
        jp      .cps_walk_advance

.cps_skip_stamp:
        xor     a
        ld      (iy+0), a
        ld      (iy+1), a
        ld      (iy+2), a
        ld      (iy+3), a
        ld      (iy+4), a

.cps_walk_advance:
        ; Advance IY by SLOT_ROW_STRIDE
        push    de
        ld      de, SLOT_ROW_STRIDE
        add     iy, de
        pop     de
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jp      nz, .cps_walk_lp

        ; --- Step 3: patch cap-slot handler addresses (pipe-specific) ---
        ; slot[NEW_cap_top_row][pipe]+1..+2 := cap_top_handler_pipe_<pipe>
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
        add     a, e
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      de, SLOT_GRID_BASE + 2
        add     hl, de
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_top_handler_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_ctp_nc
        inc     d
.cps_ctp_nc:
        ld      a, (de)
        ld      (hl), a
        inc     hl
        inc     de
        ld      a, (de)
        ld      (hl), a

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

        ; --- Step 4: cap target imms from CAP_TARGET_TABLE ---
        ld      a, (cps_gap_y)
        rrca
        rrca
        rrca
        and     $0F
        dec     a
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        ld      de, CAP_TARGET_TABLE
        add     hl, de

        ld      a, (cps_pipe)
        add     a, a
        push    hl
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
        ld      b, a
        pop     hl
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a
        inc     hl

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

        ; --- Step 5: cap _next imms via compute_next_slot ---
        ld      a, (cps_cap_top_row)
        call    compute_next_slot
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

        ; --- Step 6: rebuild active sublist (computed walk) ---
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
        pop     ix

        ld      a, (cps_pipe)
        ld      e, a
        add     a, a
        add     a, a
        add     a, e
        ld      l, a
        ld      h, 0
        ld      de, SLOT_GRID_BASE + 2
        add     hl, de

        ld      a, (cps_cap_top_row)
        or      a
        jr      z, .cps_act_skip_band1
        ld      b, a
.cps_act_band1_lp:
        ld      (ix+0), l
        ld      (ix+1), h
        inc     ix
        inc     ix
        ld      de, SLOT_ROW_STRIDE
        add     hl, de
        djnz    .cps_act_band1_lp
.cps_act_skip_band1:

        push    hl
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
        pop     hl

        push    bc
        ld      bc, 49 * SLOT_ROW_STRIDE
        add     hl, bc
        pop     bc

        push    hl
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
        pop     hl

        ld      de, SLOT_ROW_STRIDE
        add     hl, de

        ld      a, (cps_cap_bot_row)
        inc     a
        cp      GROUND_TOP
        jr      nc, .cps_act_skip_band2
        ld      b, a
        ld      a, GROUND_TOP
        sub     b
        ld      b, a
.cps_act_band2_lp:
        ld      (ix+0), l
        ld      (ix+1), h
        inc     ix
        inc     ix
        ld      de, SLOT_ROW_STRIDE
        add     hl, de
        djnz    .cps_act_band2_lp
.cps_act_skip_band2:

        ; --- Step 7: store new gap_y and update pipe_prev_cap_top/bot ---
        ld      a, (cps_pipe)
        add     a, a
        inc     a
        ld      hl, pipe_state
        add     a, l
        ld      l, a
        jr      nc, .cps_gap_nc
        inc     h
.cps_gap_nc:
        ld      a, (cps_gap_y)
        ld      (hl), a

        ; Save NEW cap_top/cap_bot to pipe_prev arrays for next call.
        ld      a, (cps_pipe)
        ld      hl, pipe_prev_cap_top
        add     a, l
        ld      l, a
        jr      nc, .cps_ppt_nc
        inc     h
.cps_ppt_nc:
        ld      a, (cps_cap_top_row)
        ld      (hl), a

        ld      a, (cps_pipe)
        ld      hl, pipe_prev_cap_bot
        add     a, l
        ld      l, a
        jr      nc, .cps_ppb_nc
        inc     h
.cps_ppb_nc:
        ld      a, (cps_cap_bot_row)
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
        cp      2
        jr      z, .cns_next_row        ; pipe == 2 → go to next row
        ; pipe 0 or 1: next pipe in same row = SLOT_ADDR_TABLE[(row*3 + pipe+1)*2]
        inc     a                       ; A = pipe + 1
        ; index = row*6 + (pipe+1)*2
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      d, h
        ld      e, l                    ; DE = row*2
        add     hl, hl                  ; row*4
        add     hl, de                  ; row*6
        add     a, a                    ; (pipe+1)*2
        ld      e, a
        ld      d, 0
        add     hl, de                  ; row*6 + (pipe+1)*2
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl                  ; HL = slot[row][pipe+1]
        ret
.cns_next_row:
        ; pipe == 2: next = slot_addr_table[row+1][0] - 1 (the EXX byte before it)
        ld      a, b
        inc     a                       ; A = row + 1
        cp      GROUND_TOP              ; 160 = end of grid
        jr      z, .cns_end_of_grid
        ; index = (row+1)*6
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; (row+1)*2
        ld      d, h
        ld      e, l
        add     hl, hl                  ; (row+1)*4
        add     hl, de                  ; (row+1)*6
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
cps_old_cap_top_row:    db 0       ; OLD cap rows from previous configure for this pipe
cps_old_cap_bot_row:    db 0

pipe_prev_cap_top:      ds 3, 255  ; per-pipe history; $FF = no prior call
pipe_prev_cap_bot:      ds 3, 255

; ── Per-pipe active sublist base table ───────────────────────────
cps_sublist_base_table:
        dw      ACTIVE_PIPE_0
        dw      ACTIVE_PIPE_1
        dw      ACTIVE_PIPE_2

; Precomputed screen targets for byte_x=29 baseline (recycle byte_x).
; targets[row] = line_table[row] + 32 (= byte_x=29 + 3). Populated at init.
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
;   targets[row] = line_table[row] + 32 (= byte_x=29 + 3).
; Configure_pipe_slots reads this on every body emit instead of recomputing.
;----------------------------------------------------------------
init_screen_target_table:
        ld      hl, line_table
        ld      de, screen_target_table_29
        ld      b, 160
.istt_lp:
        ld      a, (hl)
        add     a, 32
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

        ; cap_top_target: read line_table[gap_y - 1], add 32
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
        add     a, 32
        ld      (ix+0), a
        ld      a, d
        adc     a, 0
        ld      (ix+1), a

        ; cap_bot_target: read line_table[gap_y + 48], add 32
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

;----------------------------------------------------------------
init_pipes:
        xor     a
        ld      (phase), a
        call    init_slot_addr_table        ; precompute slot_addr_table[160][3]
        call    init_screen_target_table    ; precompute screen_target_table_29[160]
        call    init_pipe_program           ; emit fixed slot grid (reads slot_addr_table)
        ; For each pipe, apply initial cap/skip configuration (full pass).
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
        cp      NUM_PIPES
        jr      nz, .init_cps_lp
        ; ACTIVE_COUNT_NEW = 3 * 112 = 336 (used by patch_pipe_targets to walk
        ; the three per-pipe sublists at ACTIVE_PIPE_0..PIPE_2 contiguously).
        ld      hl, 336
        ld      (ACTIVE_COUNT_NEW), hl
        call    redraw_pipes_v2
        ret

;----------------------------------------------------------------
frame_update:
        ; ── Pipes go FIRST so X_0 is as low as possible. Skipped the magenta
        ; OUT-($fe) — saved 18 T-st of lead-time over the raster. The border
        ; band that used to mark "pipes phase" is gone; what was BLUE for
        ; restore-bird-bg now spans the full pipes+restore region. Worth it.
        call    redraw_pipes_v2
        ld      a, 1                    ; PROFILE: BLUE = bird ops region
        out     ($fe), a
        call    restore_bird_bg
        call    restore_bird_attrs
        call    read_input
        call    update_bird
        call    advance_bird_anim
        call    draw_bird
        call    paint_bird_attrs
        call    update_score
        ld      a, 4                    ; PROFILE: GREEN = ground
        out     ($fe), a
        call    draw_ground
        ld      a, 7                    ; PROFILE: WHITE = end-of-frame state prep
        out     ($fe), a
        call    advance_phase           ; 2 px/frame scroll, takes effect NEXT frame
        call    advance_phase
        ; Deferred wrap cleanup: restore OLD pipe positions to bg attrs.
        ; Safe here because the raster has passed all pipe attr rows by now;
        ; the restore affects NEXT frame's display, not this one's.
        ld      a, (wrap_pending)
        or      a
        jr      z, .skip_restore
        xor     a
        ld      (wrap_pending), a
        call    restore_trailing_pipe_attrs
.skip_restore:
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
        call    apply_pipe_attrs
        ld      a, 1
        ld      (wrap_pending), a
        ret

;----------------------------------------------------------------
; draw_ground: fill lines 160..191 with diagonal-stripe pattern, phase-shifted
; for scroll. Uses push-BC stack-fill (12 pushes = 24 bytes per line, cols 4-27).
;----------------------------------------------------------------
draw_ground:
        ld      (saved_sp), sp
        ; IY = ground_tiles + (phase mod 4) * 8
        ld      a, (phase)
        and     3
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
        ; Assumes ACTIVE_COUNT = 336 (constant, 3 pipes × 112 active rows).
        ; 336/4 = 84 djnz iterations.
        ;
        ; On recycle frames (pending_regen != 0) the recycled pipe's 112 entries
        ; are skipped because configure_pipe_slots will overwrite them anyway.
        ; That saves ~28 djnz iterations × 4 entries × ~46T ≈ 5.2k T-states.
        ld      (saved_sp_inner), sp
        ld      a, (pending_regen)
        or      a
        jr      nz, .pt_skip_path

        ; --- Normal path: all 3 pipes, 84 iterations ---
        ld      sp, ACTIVE_LIST_NEW
        ld      b, 84                           ; 336 / 4
.pt_lp:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_nc1
        inc     hl
        dec     (hl)
.pt_nc1:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_nc2
        inc     hl
        dec     (hl)
.pt_nc2:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_nc3
        inc     hl
        dec     (hl)
.pt_nc3:
        pop     hl
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_nc4
        inc     hl
        dec     (hl)
.pt_nc4:
        djnz    .pt_lp
        ld      sp, (saved_sp_inner)
        ret

        ; --- Recycle path: skip the recycled pipe's 112 entries ---
        ; Three inline sub-walks (28 iters each = 112 entries each).
        ; Each is guarded by a jr z so the recycled pipe is skipped.
.pt_skip_path:
        ld      a, (recycled_pipe_idx)

        ; Pipe 0
        or      a                               ; recycled_pipe_idx == 0?
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
        ld      a, (recycled_pipe_idx)
        cp      1                               ; recycled_pipe_idx == 1?
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
        ld      a, (recycled_pipe_idx)
        cp      2                               ; recycled_pipe_idx == 2?
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

        ld      sp, (saved_sp_inner)
        ret

;----------------------------------------------------------------
; wrap_byte_x: scroll all pipes left by one byte (8 px). For each pipe:
;   - clear the old trailing column (paint_restore) if it is in visible playfield
;   - decrement byte_x; on byte_x == 1 → recycle (random gap_y, byte_x = 29,
;     defer slot regen by 2 frames via pending_regen)
; Tail-call patch_pipe_targets to decrement every active body slot's screen
; target by ROW_OFFSET (= 1) so they walk to the next column.
;----------------------------------------------------------------
wrap_byte_x:
        ld      iy, pipe_state
        ld      b, NUM_PIPES
.outer:
        push    bc
        ld      a, (iy+0)
        ; Clear OLD trailing col = old byte_x + 2. Skip clear if trailing is
        ; in either buffer (cols 0-3 left, 28-31 right) since buffer attr
        ; hides whatever pixels are there — no restore needed.
        cp      2                       ; byte_x < 2 → trailing ≤ 3 (left buffer)
        jr      c, .skip_clear
        cp      26                      ; byte_x ≥ 26 → trailing ≥ 28 (right buffer)
        jr      nc, .skip_clear
        inc     a
        inc     a                       ; trailing = byte_x + 2 (in 4..27)
        ld      c, a
        ld      e, (iy+1)
        call    clear_pipe_col

.skip_clear:
        ld      a, (iy+0)
        cp      1
        jr      z, .recycle
        dec     a
        jr      .save
.recycle:
        call    random_gap_y            ; A = new random gap_y; IY/BC preserved
        ld      (iy+1), a
        ld      a, 2
        ld      (pending_regen), a      ; defer 1 frame, then run full configure
        ; Record which pipe recycled — B counts down from NUM_PIPES to 1, so index = NUM_PIPES - B.
        ld      a, NUM_PIPES
        sub     b
        ld      (recycled_pipe_idx), a
        ld      a, 29
.save:
        ld      (iy+0), a
        inc     iy
        inc     iy
        pop     bc
        djnz    .outer
        ; Run patch_pipe_targets in WHITE band (end-of-frame state prep).
        ; WHITE is partially hidden in bottom blanking, so this is less visible
        ; than running it in RED at top of next frame.
        call    patch_pipe_targets
        ret

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
cap_top_handler_pipe_0_de EQU $+1
        ld      hl, $0000                       ; SMC: M2/R pair (low=M2, high=R)
        push    hl
cap_top_handler_pipe_0_bc EQU $+1
        ld      hl, $0000                       ; SMC: L/M1 pair (low=L, high=M1)
        push    hl
cap_top_handler_pipe_0_next EQU $+1
        jp      $0000                           ; SMC: address of next slot after cap row

cap_top_handler_pipe_1:
cap_top_handler_pipe_1_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_1_next EQU $+1
        jp      $0000

cap_top_handler_pipe_2:
cap_top_handler_pipe_2_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_2_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_0:
cap_bot_handler_pipe_0_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_0_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_0_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_0_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_1:
cap_bot_handler_pipe_1_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_1_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_1_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_1_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_2:
cap_bot_handler_pipe_2_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_2_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_2_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_2_next EQU $+1
        jp      $0000

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
cap_top_next_imm_addrs:
        dw      cap_top_handler_pipe_0_next
        dw      cap_top_handler_pipe_1_next
        dw      cap_top_handler_pipe_2_next
cap_bot_next_imm_addrs:
        dw      cap_bot_handler_pipe_0_next
        dw      cap_bot_handler_pipe_1_next
        dw      cap_bot_handler_pipe_2_next

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
        ; Deferred configure_pipe_slots dispatch, split across two frames so a
        ; recycle frame fits under the 50Hz budget. configure_pipe_slots itself
        ; is band-emit + IY-direct (~32k T), and each half is ~16k T; plus
        ; PIPE_PROGRAM (~16k) plus bird/ground/etc (~8k) keeps the recycle
        ; frame around ~40k.
        ;   pending_regen states: 0 = idle
        ;                         3 = just-recycled, defer one frame
        ;                         2 = configure rows 0..79  (first half)
        ;                         1 = configure rows 80..159 (second half)
        ; pending_regen: 0 = idle; 2 = defer one frame; 1 = run full configure.
        ; (Split across two frames was tried but introduces a cap-handler race:
        ; the OLD cap slot stays in the second-half range, and a cap firing
        ; there with a NEW _next pointing BEFORE the cap row creates an
        ; infinite-loop in PIPE_PROGRAM. The optimization alone brings cps
        ; under budget without needing the split.)
        ld      a, (pending_regen)
        or      a
        jr      z, .skip_regen
        cp      1
        jr      z, .regen_full
        dec     a
        ld      (pending_regen), a
        jr      .skip_regen
.regen_full:
        ld      a, (recycled_pipe_idx)
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, pipe_state
        add     hl, de
        inc     hl
        ld      e, (hl)
        ld      a, (recycled_pipe_idx)
        ld      b, 0
        ld      c, GROUND_TOP
        call    configure_pipe_slots
        xor     a
        ld      (pending_regen), a
.skip_regen:

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
        ; Refresh cap byte values for current phase
        call    update_cap_imm_v2       ; clobbers BC, DE

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

        ; Write bc/de pairs into cap_top handlers (pipes 0..2)
        ld      ix, cap_top_bc_imm_addrs
        ld      iy, cap_top_de_imm_addrs
        ld      b, 3
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

        ; Write bc/de pairs into cap_bot handlers (pipes 0..2)
        ld      ix, cap_bot_bc_imm_addrs
        ld      iy, cap_bot_de_imm_addrs
        ld      b, 3
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
clear_pipe_col:
        ld      a, e
        or      a
        jr      z, .no_top
        push    de
        ld      b, e
        xor     a
        call    paint_restore
        pop     de
.no_top:
        ld      a, e
        add     a, PIPE_GAP
        cp      GROUND_TOP              ; stop at ground — pipe doesn't paint below
        ret     nc
        ld      d, a
        neg
        add     a, GROUND_TOP           ; count = GROUND_TOP - (gap_y + PIPE_GAP)
        ld      b, a
        ld      a, d
        jp      paint_restore

;----------------------------------------------------------------
; paint_restore: copy bg_buffer[col] → screen[col] for B scan lines
; starting at line A. Used as the "erase" when pipe leaves a col.
;
; 4x-unrolled per iteration to amortize the djnz / loop overhead.
; Callers (clear_pipe_col) always pass B as a multiple of 8 (gap_y is
; aligned to 8), so no remainder handling is needed: B is divided by 4
; up front and the inner block writes 4 lines per pass.
; Cost: ~55 cyc/line vs ~65 unrolled = ~10 cyc/line saved × ~336 lines
; per wrap = ~3300 cyc saved per wrap frame.
;----------------------------------------------------------------
paint_restore:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        srl     b
        srl     b                       ; B = line groups of 4
        ret     z                       ; (caller never passes B<4 in practice)
.lp:
        pop     hl                      ; line N
        ld      a, c
        add     a, l
        ld      l, a
        set     7, h
        ld      d, (hl)
        res     7, h
        ld      (hl), d
        pop     hl                      ; line N+1
        ld      a, c
        add     a, l
        ld      l, a
        set     7, h
        ld      d, (hl)
        res     7, h
        ld      (hl), d
        pop     hl                      ; line N+2
        ld      a, c
        add     a, l
        ld      l, a
        set     7, h
        ld      d, (hl)
        res     7, h
        ld      (hl), d
        pop     hl                      ; line N+3
        ld      a, c
        add     a, l
        ld      l, a
        set     7, h
        ld      d, (hl)
        res     7, h
        ld      (hl), d
        djnz    .lp
        ld      sp, (saved_sp)
        ret

;----------------------------------------------------------------
; Bird routines
;----------------------------------------------------------------
init_bird:
        xor     a
        ld      (bird_old_y_valid), a
        ld      (bird_attr_valid), a
        ld      (bird_anim_tick), a
        ld      a, 1
        ld      (bird_anim_phase), a
        ld      hl, bird_sprite_f1
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
        ld      b, NUM_PIPES
.lp:
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

; advance_bird_anim: every BIRD_ANIM_RATE frames, advance wing phase 0→1→2→0
; and refresh bird_sprite_ptr. Called once per frame from frame_update.
advance_bird_anim:
        ld      hl, bird_anim_tick
        ld      a, (hl)
        inc     a
        cp      BIRD_ANIM_RATE
        jr      c, .store_tick
        xor     a                       ; tick wraps to 0
        ld      (hl), a
        ld      a, (bird_anim_phase)
        inc     a
        cp      3
        jr      c, .store_phase
        xor     a
.store_phase:
        ld      (bird_anim_phase), a
        ; ptr = bird_sprite_f0 + phase * BIRD_FRAME_BYTES (=64)
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                  ; HL = phase * 64
        ld      de, bird_sprite_f0
        add     hl, de
        ld      (bird_sprite_ptr), hl
        ret
.store_tick:
        ld      (hl), a
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

; paint_bird_attrs: paint exactly 1 char row of yellow at the char row
; containing the bird's vertical centre ((y_high + 8) >> 3).
paint_bird_attrs:
        ld      a, (bird_y + 1)
        add     a, 8                    ; +8 snaps to char row containing bird centre
        and     $F8
        ld      (bird_attr_y), a
        ld      a, 1
        ld      (bird_attr_valid), a
        ld      a, (bird_attr_y)
        call    bird_attr_addr
        ld      de, bird_attr_save
        ld      a, (hl)
        ld      (de), a
        ld      (hl), ATTR_BIRD
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        ld      (hl), ATTR_BIRD
        ret

; restore_bird_attrs: write the 2 saved attr bytes back at bird_attr_y's row.
restore_bird_attrs:
        ld      a, (bird_attr_valid)
        or      a
        ret     z
        ld      a, (bird_attr_y)
        call    bird_attr_addr
        ld      de, bird_attr_save
        ld      a, (de)
        ld      (hl), a
        inc     hl
        inc     de
        ld      a, (de)
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

; draw_bird: masked draw at fixed col BIRD_X=8. Sprite data is interleaved
; 4 bytes/row: inv_maskL, spriteL, inv_maskR, spriteR. Per byte we do
;   screen = (screen AND inv_mask) OR sprite
; so the bird's body footprint is cleared to paper colour before the outline
; is laid on top — pipe pixels behind the bird don't bleed through.
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
        set     3, l                    ; HL → screen[col BIRD_X=8]
        ld      a, (de)                 ; inv_maskL
        and     (hl)
        ld      c, a
        inc     de
        ld      a, (de)                 ; spriteL
        or      c
        ld      (hl), a
        inc     de
        inc     hl
        ld      a, (de)                 ; inv_maskR
        and     (hl)
        ld      c, a
        inc     de
        ld      a, (de)                 ; spriteR
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
        ld      b, NUM_PIPES
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

        call    compute_bird_overlap    ; fill mask before we walk the rows

        ld      a, (bird_old_y)
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      iy, bird_overlap
        ld      b, BIRD_LINES
.lp:
        pop     hl
        set     3, l                    ; HL → screen[col 8]
        ld      d, h
        ld      e, l
        set     7, d                    ; DE → bg_buffer at col 8
        bit     0, (iy+0)
        jr      nz, .skip_col8          ; pipe covers col 8 here → leave pipe pixel
        ld      a, (de)
        ld      (hl), a
.skip_col8:
        inc     hl
        inc     e
        bit     1, (iy+0)
        jr      nz, .skip_col9
        ld      a, (de)
        ld      (hl), a
.skip_col9:
        inc     iy
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
;----------------------------------------------------------------
apply_pipe_attrs:
        ld      iy, pipe_state
        ld      b, NUM_PIPES
.lp:
        push    bc
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
        ld      b, NUM_PIPES
.lp:
        push    bc
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
        ld      b, NUM_PIPES
.lp:
        push    bc
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
