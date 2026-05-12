        DEVICE  ZXSPECTRUM48

;----------------------------------------------------------------
; Speccy Flappy Bird — step 7: static cityscape behind pipes
;
; - bg_buffer at $C000-$D7FF mirrors the pristine background
;   (sky zeros + cityscape building columns)
; - At init: paint attrs, build bg_buffer, copy to screen, draw pipes
; - When a pipe column needs clearing on scroll, paint_restore
;   copies the bg_buffer byte back instead of writing zero — so the
;   cityscape persists as pipes pass through
; - Cityscape band attribute = bright cyan paper + white ink, so
;   the buildings show white and pipes turning green→white as they
;   cross the band's char rows (Spectrum attribute clash, by design)
;----------------------------------------------------------------

NUM_PIPES   EQU 3
PIPE_GAP    EQU 48

BIRD_X      EQU 8                       ; fixed col (= 64 px from left)
BIRD_LINES  EQU 16
GRAVITY     EQU 64                      ; vy += GRAVITY per frame (16-bit fixed-point)
FLAP_VY     EQU $FC00                   ; signed -1024 (4 px/frame upward)

ATTRS           EQU $5800
BG_BUFFER       EQU $C000
BACKUP_ATTRS    EQU $D800               ; mirror of ATTRS without pipe overlay (768 B)

ATTR_SKY        EQU $28                 ; paper cyan + ink black
ATTR_CITY       EQU $38                 ; paper white + ink black (skyscraper windows)
ATTR_GROUND     EQU $20                 ; paper green + ink black (ground band, row 20)
ATTR_SCOREBOARD EQU $07                 ; paper black + ink white (rows 21..23)
ATTR_PIPE       EQU $20                 ; paper green + ink black (dynamic, inner pipe cells)
GROUND_TOP      EQU 160                 ; first scan line of ground band — pipes stop here
SCORE_TOP       EQU 168                 ; first scan line of scoreboard band (= ground+8)

CITY_TOP        EQU 128                 ; first scan line of cityscape band
CITY_BOTTOM     EQU 160                 ; first scan line below cityscape

        ORG $8000

start:
        di
        ld      sp, $8000
        ld      a, 5
        out     ($fe), a
        call    paint_attrs             ; initial base attrs (rows 16..19 all city)
        call    init_background
        call    refill_base_attrs       ; convert row 16..19 to sky + per-cell city
        call    backup_base_attrs       ; snapshot ATTRS → BACKUP_ATTRS (no pipes)
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
        ld      a, 5                    ; PROFILE: CYAN = end of frame (idle until next halt)
        out     ($fe), a
        ei
        jr      main_loop

;----------------------------------------------------------------
phase:      db 0
saved_sp:   dw 0
ground_iy_save: dw 0
paint_LMMR_start_line: db 0             ; scratch — start line saved across SP-hijack

pipe_state:
        db 30, 24                       ; gap_y values are multiples of 8 so cap
        db 22, 56                       ;   rows align cleanly with char-row
        db 14, 88                       ;   boundaries (no green paper spill)

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
; Green paper extends to byte_x+2 cell (3-cell green attr) so the byte 3
; alternation lands on green paper → reads as checker on green, NOT as
; diagonal stripes on white at cityscape rows.
pipe_bitmap_b:
        db $00, $EA, $00, $AB           ; phase 0
        db $01, $D4, $01, $56           ; phase 1
        db $03, $A8, $02, $AC           ; phase 2
        db $07, $50, $05, $58           ; phase 3
        db $0E, $A0, $0A, $B0           ; phase 4
        db $1D, $40, $15, $60           ; phase 5
        db $3A, $80, $2A, $C0           ; phase 6
        db $75, $00, $55, $80           ; phase 7

; Outside-the-pipe pixel masks per phase. The 24-px pipe sits at pixels
; phase..phase+23 within the 32-px LMMR window, so:
;   L_out_mask(phase) selects bits 7..8-phase of L cell (the padding left
;   of the pipe — $FF for phase 0 grows toward $80 for phase 7).
;   R_out_mask(phase) selects bits phase-1..0 of R cell (the padding right
;   of the pipe — $00 for phase 0 grows toward $7F for phase 7).
; Used by paint_LMMR_city to mask the bg_buffer byte so cityscape pattern
; appears only in pixels outside the pipe shape, never inside it.
l_out_masks:
        db $FF, $FE, $FC, $F8, $F0, $E0, $C0, $80
r_out_masks:
        db $00, $01, $03, $07, $0F, $1F, $3F, $7F

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

; Bird sprite — 16 rows × 2 bytes, simple egg shape
bird_sprite:
        db $1F, $F8
        db $3F, $FC
        db $7F, $FE
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $FF, $FF
        db $7F, $FE
        db $3F, $FC
        db $1F, $F8

; Skyline silhouette — building height (in scan lines, multiples of 8) per col.
; Each value / 8 = number of 8-row skyscraper tiles. Multiples of 8 keep tiles
; aligned to char-row boundaries so the per-cell ATTR_CITY (white paper) only
; covers the building cells, not the whole row.
cityscape_heights:
        db 16, 16, 8, 24, 16, 24, 16, 32, 16, 16, 24, 16, 32, 16, 32, 24
        db 16, 24, 16, 16, 32, 16, 16, 24, 16, 32, 24, 16, 16, 16, 24, 16

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

; Skyscraper tile — 8x8 px, used as building texture under ATTR_CITY
; (paper white + ink black). Bit set = black ink = wall; bit clear = white
; paper = window.
;   Row 0 ($FF): floor / roof edge.
;   Row 1 ($99): window row — wall, 2-px window, 2-px wall, 2-px window, wall.
;   Rows 2..7: alternating floor + window pattern.
; 32-byte pattern = tile repeated 4 times so a building at any line within the
; 32-line city band (lines 128..159) can index by (start_y - CITY_TOP + iter).
cityscape_pattern:
        db $FF, $99, $FF, $99, $FF, $99, $FF, $99
        db $FF, $99, $FF, $99, $FF, $99, $FF, $99
        db $FF, $99, $FF, $99, $FF, $99, $FF, $99
        db $FF, $99, $FF, $99, $FF, $99, $FF, $99

;----------------------------------------------------------------
paint_attrs:
        ld      hl, ATTRS
        ld      de, ATTRS + 1
        ld      (hl), ATTR_SKY
        ld      bc, 16 * 32 - 1         ; 16 char rows of sky
        ldir
        inc     hl
        ld      (hl), ATTR_CITY
        ld      d, h
        ld      e, l
        inc     de
        ld      bc, 4 * 32 - 1          ; 4 char rows of cityscape
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
; init_background: fill bg_buffer with sky + cityscape, then blit
; the buffer to the screen
;----------------------------------------------------------------
init_background:
        ld      hl, BG_BUFFER
        ld      de, BG_BUFFER + 1
        ld      (hl), 0
        ld      bc, $17FF
        ldir                            ; bg = all zero (sky)

        ld      iy, cityscape_heights
        ld      c, 0
.cs:
        ld      a, (iy+0)
        or      a
        jr      z, .cs_skip
        ld      b, a                    ; line count = height
        ld      d, a
        ld      a, CITY_BOTTOM
        sub     d                       ; A = start_line
        push    iy
        call    draw_bg_column
        pop     iy
.cs_skip:
        inc     iy
        inc     c                       ; advance col counter
        ld      a, c
        cp      32
        jr      nz, .cs

        ld      hl, BG_BUFFER
        ld      de, $4000
        ld      bc, $1800
        ldir                            ; copy bg → screen
        ret

;----------------------------------------------------------------
; draw_bg_column: write cityscape_pattern bytes to bg_buffer at column C,
; lines A..A+B-1. Pattern indexed by (start_line - CITY_TOP + iter) so
; the skyscraper tile aligns globally across all building columns.
; All stack work happens BEFORE SP-hijack (otherwise pop reads line_table).
;----------------------------------------------------------------
draw_bg_column:
        ; Compute DE = cityscape_pattern + (A - CITY_TOP)
        push    af                       ; save A
        sub     CITY_TOP
        ld      de, cityscape_pattern
        add     a, e
        ld      e, a
        jr      nc, .no_carry
        inc     d
.no_carry:
        pop     af                       ; restore A = start line
        ; Compute HL = line_table + A*2 (preserving DE)
        ld      h, 0
        ld      l, a
        add     hl, hl
        push    de
        ld      de, line_table
        add     hl, de
        pop     de
        ; SP-hijack — from here on, no push/pop on caller's stack
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        set     7, h                    ; HL → bg_buffer
        ld      a, (de)
        ld      (hl), a
        inc     de
        djnz    .lp
        ld      sp, (saved_sp)
        ret

;----------------------------------------------------------------
init_pipes:
        xor     a
        ld      (phase), a
        call    update_smc
        call    redraw_all_pipes
        ret

;----------------------------------------------------------------
frame_update:
        ld      a, 1                    ; PROFILE: BLUE = bird ops
        out     ($fe), a
        call    restore_bird_bg         ; clear OLD bird position to bg
        call    read_input              ; SPACE key → flap
        call    update_bird             ; gravity + position update
        call    draw_bird               ; draw bird EARLY (before raster reaches Y)

        ld      a, (frame_skip)
        inc     a
        ld      (frame_skip), a
        and     1
        jr      nz, .skip_phase_work    ; non-phase-change frame → skip SMC + wrap + attrs
        ld      a, (phase)
        inc     a
        and     7
        ld      (phase), a
        or      a
        jr      nz, .no_wrap
        ; Wrap frame: byte_x is about to change for all pipes. Use incremental
        ; attrs: restore base at OLD positions, advance, set ATTR_PIPE at NEW.
        ld      a, 2                    ; PROFILE: RED = restore_pipe_attrs (old positions)
        out     ($fe), a
        call    restore_pipe_attrs
        ld      a, 7                    ; PROFILE: WHITE = wrap_byte_x (clear trailing cols)
        out     ($fe), a
        call    wrap_byte_x
        ld      a, 2                    ; PROFILE: RED = apply_pipe_attrs (new positions)
        out     ($fe), a
        call    apply_pipe_attrs
.no_wrap:
        ; Phase changed — update pre-shifted bitmap SMC slots.
        ld      a, 6                    ; PROFILE: YELLOW = update_smc + update_cap_smc
        out     ($fe), a
        call    update_smc
        call    update_cap_smc
.skip_phase_work:
        ld      a, 3                    ; PROFILE: MAGENTA = redraw_all_pipes
        out     ($fe), a
        call    redraw_all_pipes        ; body + caps inlined per pipe in line order
        ld      a, 4                    ; PROFILE: GREEN = draw_ground
        out     ($fe), a
        call    draw_ground
        ret

;----------------------------------------------------------------
; draw_ground: fill lines 160..191 with diagonal-stripe pattern, phase-shifted
; for scroll. Uses push-BC stack-fill (16 pushes = 32 bytes per line).
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
        ; push iy/push bc would write into the interleaved cityscape row 19.
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
        ; Compute HL = line_table[D] + 32 (= end of line D's screen row)
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
        ld      bc, 32
        add     hl, bc                  ; HL = line addr + 32
        pop     bc
        ld      sp, hl
        ; Push BC 16 times = fill 32 bytes (decrementing SP, writing high-then-low)
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
; update_cap_smc: load pre-shifted rounded-rim bytes into all 7 cap variants.
;----------------------------------------------------------------
update_cap_smc:
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, cap_rounded_bitmap
        add     hl, bc
        ; byte 0 → all *_l slots (normal + city)
        ld      a, (hl)
        ld      (paint_cap_rounded_L.smc_l + 1), a
        ld      (paint_cap_rounded_LM.smc_l + 1), a
        ld      (paint_cap_rounded_LMM.smc_l + 1), a
        ld      (paint_cap_rounded_LMMR.smc_l + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_l + 1), a
        ld      (paint_cap_rounded_LMM_city.smc_l + 1), a
        ld      (paint_cap_rounded_LM_city.smc_l + 1), a
        ld      (paint_cap_rounded_L_city.smc_l + 1), a
        inc     hl
        ; byte 1 → smc_m of LM/LM_city, smc_m1 of LMM/LMMR/MMR (+ city)
        ld      a, (hl)
        ld      (paint_cap_rounded_LM.smc_m + 1), a
        ld      (paint_cap_rounded_LM_city.smc_m + 1), a
        ld      (paint_cap_rounded_LMM.smc_m1 + 1), a
        ld      (paint_cap_rounded_LMM_city.smc_m1 + 1), a
        ld      (paint_cap_rounded_LMMR.smc_m1 + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_m1 + 1), a
        ld      (paint_cap_rounded_MMR.smc_m1 + 1), a
        ld      (paint_cap_rounded_MMR_city.smc_m1 + 1), a
        inc     hl
        ; byte 2 → smc_m2 of LMM/LMMR/MMR (+ city), smc_m of MR (+ city)
        ld      a, (hl)
        ld      (paint_cap_rounded_LMM.smc_m2 + 1), a
        ld      (paint_cap_rounded_LMM_city.smc_m2 + 1), a
        ld      (paint_cap_rounded_LMMR.smc_m2 + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_m2 + 1), a
        ld      (paint_cap_rounded_MMR.smc_m2 + 1), a
        ld      (paint_cap_rounded_MMR_city.smc_m2 + 1), a
        ld      (paint_cap_rounded_MR.smc_m + 1), a
        ld      (paint_cap_rounded_MR_city.smc_m + 1), a
        inc     hl
        ; byte 3 → smc_r of LMMR/MMR/MR/R (+ city)
        ld      a, (hl)
        ld      (paint_cap_rounded_LMMR.smc_r + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_r + 1), a
        ld      (paint_cap_rounded_MMR.smc_r + 1), a
        ld      (paint_cap_rounded_MMR_city.smc_r + 1), a
        ld      (paint_cap_rounded_MR.smc_r + 1), a
        ld      (paint_cap_rounded_MR_city.smc_r + 1), a
        ld      (paint_cap_rounded_R.smc_r + 1), a
        ld      (paint_cap_rounded_R_city.smc_r + 1), a

        ; Phase-indexed outside-pixel masks for cap city variants.
        ld      a, (phase)
        ld      c, a
        ld      b, 0
        ld      hl, l_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_cap_rounded_LMMR_city.smc_l_outmask + 1), a
        ld      (paint_cap_rounded_LMM_city.smc_l_outmask + 1), a
        ld      (paint_cap_rounded_LM_city.smc_l_outmask + 1), a
        ld      (paint_cap_rounded_L_city.smc_l_outmask + 1), a
        ld      hl, r_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_cap_rounded_LMMR_city.smc_r_outmask + 1), a
        ld      (paint_cap_rounded_MMR_city.smc_r_outmask + 1), a
        ld      (paint_cap_rounded_MR_city.smc_r_outmask + 1), a
        ld      (paint_cap_rounded_R_city.smc_r_outmask + 1), a
        ret

frame_skip: db 0

;----------------------------------------------------------------
wrap_byte_x:
        ld      iy, pipe_state
        ld      b, NUM_PIPES
.outer:
        push    bc
        ld      a, (iy+0)
        ; Clear OLD trailing col = old byte_x + 2, if it was on-screen.
        ; OLD byte_x in 254..32 maps trailing col to (254+2)..(32+2) = 0..34.
        ; Only clear if (byte_x+2) in 0..31 (= on-screen).
        cp      254
        jr      c, .check_normal
        ; OLD = 254 or 255: trailing = 0 or 1 (on-screen)
        cp      255
        jr      z, .clear_col_1
        ; OLD = 254
        ld      c, 0
        jr      .do_clear
.clear_col_1:
        ld      c, 1
        jr      .do_clear
.check_normal:
        cp      30
        jr      nc, .skip_clear         ; OLD in 30..253: trailing off-screen
        inc     a
        inc     a                       ; trailing = byte_x + 2 (in 2..31)
        ld      c, a
.do_clear:
        ld      e, (iy+1)
        call    clear_pipe_col

.skip_clear:
        ld      a, (iy+0)
        cp      254
        jr      z, .recycle
        dec     a
        jr      .save
.recycle:
        ld      a, 32
.save:
        ld      (iy+0), a
        inc     iy
        inc     iy
        pop     bc
        djnz    .outer
        ret

;----------------------------------------------------------------
update_smc:
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap
        add     hl, bc
        ld      a, (hl)
        ld      (paint_L.smc_l + 1), a
        ld      (paint_LM.smc_l + 1), a
        ld      (paint_LMM.smc_l + 1), a
        ld      (paint_LMM.smc_pre_l + 1), a    ; unrolled preamble L
        ld      (paint_LMM.smc_pair_b_l + 1), a ; unrolled pair-B L (same as A)
        ld      (paint_LMM.smc_tail_l + 1), a   ; unrolled tail L
        ld      (paint_LMMR.smc_l + 1), a
        ld      (paint_LMMR.smc_tail_l + 1), a
        ld      (paint_LMMR_city.smc_l + 1), a
        ld      (paint_LMMR_city.smc_tail_l + 1), a
        ld      (paint_LMM_city.smc_l + 1), a
        ld      (paint_LM_city.smc_l + 1), a
        ld      (paint_L_city.smc_l + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LM.smc_m + 1), a
        ld      (paint_LMM.smc_m1 + 1), a
        ld      (paint_LMM.smc_pre_m1 + 1), a
        ld      (paint_LMM.smc_pair_b_m1 + 1), a
        ld      (paint_LMM.smc_tail_m1 + 1), a
        ld      (paint_LMMR.smc_m1 + 1), a
        ld      (paint_LMMR.smc_tail_m1 + 1), a
        ld      (paint_LMMR_city.smc_m1 + 1), a
        ld      (paint_LMMR_city.smc_tail_m1 + 1), a
        ld      (paint_LMM_city.smc_m1 + 1), a
        ld      (paint_LM_city.smc_m + 1), a
        ld      (paint_MMR.smc_m1 + 1), a
        ld      (paint_MMR.smc_pre_m1 + 1), a
        ld      (paint_MMR.smc_pair_b_m1 + 1), a
        ld      (paint_MMR.smc_tail_m1 + 1), a
        ld      (paint_MMR_city.smc_m1 + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LMM.smc_m2 + 1), a       ; A pattern M2 (pair_A and tail)
        ld      (paint_LMM.smc_tail_m2 + 1), a
        ld      (paint_LMMR.smc_m2 + 1), a
        ld      (paint_LMMR.smc_tail_m2 + 1), a
        ld      (paint_LMMR_city.smc_m2 + 1), a
        ld      (paint_LMMR_city.smc_tail_m2 + 1), a
        ld      (paint_LMM_city.smc_m2 + 1), a
        ld      (paint_MMR.smc_m2 + 1), a
        ld      (paint_MMR.smc_tail_m2 + 1), a
        ld      (paint_MMR_city.smc_m2 + 1), a
        ld      (paint_MR.smc_m + 1), a
        ld      (paint_MR.smc_tail_m + 1), a
        ld      (paint_MR_city.smc_m + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LMMR.smc_r + 1), a
        ld      (paint_LMMR.smc_tail_r + 1), a
        ld      (paint_LMMR_city.smc_r + 1), a
        ld      (paint_LMMR_city.smc_tail_r + 1), a
        ld      (paint_MMR.smc_r + 1), a
        ld      (paint_MMR.smc_tail_r + 1), a
        ld      (paint_MMR_city.smc_r + 1), a
        ld      (paint_MR.smc_r + 1), a
        ld      (paint_MR.smc_tail_r + 1), a
        ld      (paint_MR_city.smc_r + 1), a
        ld      (paint_R.smc_r + 1), a
        ld      (paint_R.smc_tail_r + 1), a
        ld      (paint_R_city.smc_r + 1), a

        ; Pattern B — bytes 0/1 identical to A (LEFT zone), so only bytes 2/3
        ; (RIGHT zone) need separate B slots. byte 0 and 1 of B still load into
        ; LMMR.smc_b_l / smc_b_m1 (which have copies of A) for correctness.
        ld      hl, pipe_bitmap_b
        add     hl, bc
        ld      a, (hl)
        ld      (paint_LMMR.smc_b_l + 1), a
        ld      (paint_LMMR.smc_pre_b_l + 1), a  ; unrolled B preamble
        ld      (paint_LMMR_city.smc_b_l + 1), a
        ld      (paint_LMMR_city.smc_pre_b_l + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LMMR.smc_b_m1 + 1), a
        ld      (paint_LMMR.smc_pre_b_m1 + 1), a
        ld      (paint_LMMR_city.smc_b_m1 + 1), a
        ld      (paint_LMMR_city.smc_pre_b_m1 + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LMMR.smc_b_m2 + 1), a
        ld      (paint_LMMR.smc_pre_b_m2 + 1), a
        ld      (paint_LMMR_city.smc_b_m2 + 1), a
        ld      (paint_LMMR_city.smc_pre_b_m2 + 1), a
        ld      (paint_LMM.smc_b_m2 + 1), a
        ld      (paint_LMM.smc_pre_b_m2 + 1), a
        ld      (paint_LMM_city.smc_b_m2 + 1), a
        ld      (paint_MMR.smc_b_m2 + 1), a
        ld      (paint_MMR.smc_pre_b_m2 + 1), a
        ld      (paint_MMR_city.smc_b_m2 + 1), a
        ld      (paint_MR.smc_b_m + 1), a
        ld      (paint_MR.smc_pre_b_m + 1), a
        ld      (paint_MR_city.smc_b_m + 1), a
        inc     hl
        ld      a, (hl)
        ld      (paint_LMMR.smc_b_r + 1), a
        ld      (paint_LMMR.smc_pre_b_r + 1), a
        ld      (paint_LMMR_city.smc_b_r + 1), a
        ld      (paint_LMMR_city.smc_pre_b_r + 1), a
        ld      (paint_MMR.smc_b_r + 1), a
        ld      (paint_MMR.smc_pre_b_r + 1), a
        ld      (paint_MMR_city.smc_b_r + 1), a
        ld      (paint_MR.smc_b_r + 1), a
        ld      (paint_MR.smc_pre_b_r + 1), a
        ld      (paint_MR_city.smc_b_r + 1), a
        ld      (paint_R.smc_b_r + 1), a
        ld      (paint_R.smc_pre_b_r + 1), a
        ld      (paint_R_city.smc_b_r + 1), a

        ; Phase-indexed outside-pixel masks for masked-OR in city variants.
        ld      a, (phase)
        ld      c, a
        ld      b, 0
        ld      hl, l_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_LMMR_city.smc_l_outmask + 1), a
        ld      (paint_LMMR_city.smc_b_l_outmask + 1), a
        ld      (paint_LMMR_city.smc_pre_b_l_outmask + 1), a
        ld      (paint_LMMR_city.smc_tail_l_outmask + 1), a
        ld      (paint_LMM_city.smc_l_outmask + 1), a
        ld      (paint_LM_city.smc_l_outmask + 1), a
        ld      (paint_L_city.smc_l_outmask + 1), a
        ld      hl, r_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_LMMR_city.smc_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_b_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_pre_b_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_tail_r_outmask + 1), a
        ld      (paint_MMR_city.smc_r_outmask + 1), a
        ld      (paint_MMR_city.smc_b_r_outmask + 1), a
        ld      (paint_MR_city.smc_r_outmask + 1), a
        ld      (paint_MR_city.smc_b_r_outmask + 1), a
        ld      (paint_R_city.smc_r_outmask + 1), a
        ld      (paint_R_city.smc_b_r_outmask + 1), a
        ret

;----------------------------------------------------------------
redraw_all_pipes:
        ld      iy, pipe_state
        ld      b, NUM_PIPES
.lp:
        push    bc
        ld      a, (iy+0)
        ld      c, a
        ld      e, (iy+1)
        call    draw_pipe
        inc     iy
        inc     iy
        pop     bc
        djnz    .lp
        ret

;----------------------------------------------------------------
; draw_pipe: dispatch to the right body variant based on byte_x, then
;   paint body+caps inline in line-sequential order so writes stay ahead
;   of the raster beam. Caps use paint_cap_M (char-cell-aligned, 16-px wide).
;   in: C = byte_x, E = gap_y
;
;   Body variant per byte_x range:
;     254 (-2):  paint_R     (1 col on screen)
;     255 (-1):  paint_MR    (2 cols)
;       0    :  paint_MMR   (3 cols)
;     1..29 :  paint_LMMR  (4 cols)
;       30   :  paint_LMM   (3 cols)
;       31   :  paint_LM    (2 cols)
;       32   :  paint_L     (1 col)
;----------------------------------------------------------------
draw_pipe:
        push    de                      ; save gap_y across HL/DE reuse for dispatch
        ld      a, c
        cp      33
        jp      nc, .check_neg
        cp      30
        jp      nc, .right_edge
        or      a
        jp      z, .case_MMR
        ; LMMR (byte_x in 1..29)
        ld      hl, paint_LMMR_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_LMMR_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_LMMR
        ld      de, paint_cap_rounded_LMMR
        jp      .install
.case_MMR:
        ld      hl, paint_MMR_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_MMR_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_MMR
        ld      de, paint_cap_rounded_MMR
        jp      .install
.right_edge:
        cp      32
        jr      z, .case_L
        cp      31
        jr      z, .case_LM
        ; byte_x = 30: LMM
        ld      hl, paint_LMM_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_LMM_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_LMM
        ld      de, paint_cap_rounded_LMM
        jp      .install
.case_LM:
        ld      hl, paint_LM_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_LM_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_LM
        ld      de, paint_cap_rounded_LM
        jp      .install
.case_L:
        ld      hl, paint_L_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_L_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_L
        ld      de, paint_cap_rounded_L
        jp      .install
.check_neg:
        cp      254
        jp      c, .ret_done             ; jp — .ret_done is beyond jr range
        jr      z, .case_R
        ; byte_x = 255: MR
        ld      hl, paint_MR_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_MR_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_MR
        ld      de, paint_cap_rounded_MR
        jp      .install
.case_R:
        ld      hl, paint_R_city
        ld      (.smc_body_bot_city + 1), hl
        ld      hl, paint_cap_rounded_R_city
        ld      (.smc_cap_top_city + 1), hl
        ld      (.smc_cap_bot_city + 1), hl
        ld      hl, paint_R
        ld      de, paint_cap_rounded_R

.install:
        ld      (.smc_body_top + 1), hl
        ld      (.smc_body_bot + 1), hl
        ld      (.smc_cap_top + 1), de
        ld      (.smc_cap_bot + 1), de
        pop     de                      ; restore gap_y in E

        ; Body top extends through old cap area to line gap_y-2
        ld      a, e
        cp      2
        jr      c, .skip_body_top
        push    de
        sub     1
        ld      b, a
        xor     a
.smc_body_top:
        call    paint_LMMR
        pop     de
.skip_body_top:
        ; Cap top rim — 1 line at gap_y-1. City variant if in city band.
        ld      a, e
        or      a
        jr      z, .skip_cap_top
        push    de
        dec     a                       ; A = gap_y - 1
        ld      b, 1
        cp      CITY_TOP
        jr      c, .cap_top_normal
        cp      CITY_BOTTOM
        jr      nc, .cap_top_normal
.smc_cap_top_city:
        call    paint_cap_rounded_LMMR_city
        jr      .cap_top_done
.cap_top_normal:
.smc_cap_top:
        call    paint_cap_rounded_LMMR
.cap_top_done:
        pop     de
.skip_cap_top:
        ; Cap bot rim — 1 line at gap_y+GAP. City variant if in city band.
        ld      a, e
        add     a, PIPE_GAP
        cp      GROUND_TOP
        jr      nc, .skip_cap_bot
        push    de
        ld      b, 1
        cp      CITY_TOP
        jr      c, .cap_bot_normal
        cp      CITY_BOTTOM
        jr      nc, .cap_bot_normal
.smc_cap_bot_city:
        call    paint_cap_rounded_LMMR_city
        jr      .cap_bot_done
.cap_bot_normal:
.smc_cap_bot:
        call    paint_cap_rounded_LMMR
.cap_bot_done:
        pop     de
.skip_cap_bot:
        ; Body bot: split at CITY_TOP. When sky+city both fire, the city
        ; portion is always GROUND_TOP-CITY_TOP=32 lines (since body_bot
        ; ends at GROUND_TOP-1=CITY_BOTTOM-1), so no push/pop needed.
        ld      a, e
        add     a, PIPE_GAP + 1         ; A = gap_y + 49 = body_bot start
        cp      GROUND_TOP
        ret     nc
        ld      d, a                    ; D = start
        cp      CITY_TOP
        jr      nc, .body_bot_city_only ; start >= CITY_TOP → no sky portion
        ; Sky portion: start=D, count=CITY_TOP-D
        ld      a, CITY_TOP
        sub     d                       ; A = sky_count
        ld      b, a
        ld      a, d                    ; A = sky start
.smc_body_bot:
        call    paint_LMMR
        ; City portion: start=CITY_TOP, count=32 (constant)
        ld      b, CITY_BOTTOM - CITY_TOP
        ld      a, CITY_TOP
        jp      .city_dispatch
.body_bot_city_only:
        ; D >= CITY_TOP. count = GROUND_TOP - D.
        ld      a, GROUND_TOP
        sub     d
        ld      b, a
        ld      a, d
.city_dispatch:
.smc_body_bot_city:
        jp      paint_LMMR_city

.ret_done:
        pop     de
        ret


;----------------------------------------------------------------
; Paint variants — each writes 1..4 SMC'd bytes per scan line.
; Body and cap share structure; only the SMC slot names differ so
; update_smc / update_cap_smc each target their own routines.
;----------------------------------------------------------------
; paint_LMMR (Joffa-style unrolled A/B-pair version):
; Draws 2 scanlines per loop iteration with A pattern on the (even-Y) first
; line and B pattern on the (odd-Y) second line, eliminating the per-line
; bit-parity test that the bitmap-shift dither would otherwise need.
;
; in: A = start_line, B = count (≥1), C = byte_x
;
; Dispatch: if start_line is odd, draw 1 B preamble first; if count is odd,
; draw 1 A tail at the end. The middle is B/2 AB pairs.
;
; ~85 cyc/line vs ~118 for the bit-parity loop. Critical path for body_top
; and body_bot sky portion across all 3 pipes.
paint_LMMR:
        ld      (paint_LMMR_start_line), a
        ; SP-hijack to line_table[start_line]
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ; Start parity check
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: draw 1 B line so we enter pair loop at an even Y.
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_pre_b_l:
        ld      (hl), 0
        inc     l
.smc_pre_b_m1:
        ld      (hl), 0
        inc     l
.smc_pre_b_m2:
        ld      (hl), 0
        inc     l
.smc_pre_b_r:
        ld      (hl), 0
        dec     b
        jp      z, .done
.start_was_even:
        ; Now B is the count of lines remaining after any preamble.
        ; Trim B to even, save odd-tail flag.
        xor     a
        bit     0, b
        jr      z, .count_was_even
        inc     a
        dec     b
.count_was_even:
        ld      (.smc_count_odd + 1), a
        srl     b                        ; B = pair count
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l:
        ld      (hl), 0
        inc     l
.smc_m1:
        ld      (hl), 0
        inc     l
.smc_m2:
        ld      (hl), 0
        inc     l
.smc_r:
        ld      (hl), 0
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_b_l:
        ld      (hl), 0
        inc     l
.smc_b_m1:
        ld      (hl), 0
        inc     l
.smc_b_m2:
        ld      (hl), 0
        inc     l
.smc_b_r:
        ld      (hl), 0
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0                     ; SMC: 0 or 1
        or      a
        jr      z, .done
        ; Tail: 1 A line at the end.
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_tail_l:
        ld      (hl), 0
        inc     l
.smc_tail_m1:
        ld      (hl), 0
        inc     l
.smc_tail_m2:
        ld      (hl), 0
        inc     l
.smc_tail_r:
        ld      (hl), 0
.done:
        ld      sp, (saved_sp)
        ret

; paint_LMMR_city: like paint_LMMR but L and R cells are written as
;   screen = pipe_byte | (bg_byte & outside_mask)
; with `outside_mask` selecting only the pixels that aren't part of the
; 24-px pipe shape at this phase. bg_buffer (which holds the cityscape
; pattern only at columns/rows where buildings actually exist) supplies
; the building bricks; the mask keeps cityscape OUT of pipe-occupied
; pixels so the pipe itself never has skyscraper inside it. M1/M2 stay
; direct writes (ATTR_PIPE green paper).
;
; Performance: DE holds a parallel bg_buffer pointer (= HL with bit 7 of
; high byte set), so per-byte set/res 7,h is replaced by a single set 7,d
; per line plus inc e to follow HL.
;
; Joffa-style unrolled A/B-pair: same shape as paint_LMMR — preamble for
; odd start (1 B line), B/2 AB pairs, optional A tail for odd remainder.
; No per-line `bit 0, h` parity test.
paint_LMMR_city:
        ld      (paint_LMMR_start_line), a
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: 1 B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        ld      d, h
        ld      e, l
        set     7, d
        ld      a, (de)
.smc_pre_b_l_outmask:
        and     0
.smc_pre_b_l:
        or      0
        ld      (hl), a
        inc     l
.smc_pre_b_m1:
        ld      (hl), 0
        inc     l
.smc_pre_b_m2:
        ld      (hl), 0
        inc     l
        inc     e
        inc     e
        inc     e
        ld      a, (de)
.smc_pre_b_r_outmask:
        and     0
.smc_pre_b_r:
        or      0
        ld      (hl), a
        dec     b
        jp      z, .done
.start_was_even:
        xor     a
        bit     0, b
        jr      z, .count_was_even
        inc     a
        dec     b
.count_was_even:
        ld      (.smc_count_odd + 1), a
        srl     b
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        ld      d, h
        ld      e, l
        set     7, d
        ld      a, (de)
.smc_l_outmask:
        and     0
.smc_l:
        or      0
        ld      (hl), a
        inc     l
.smc_m1:
        ld      (hl), 0
        inc     l
.smc_m2:
        ld      (hl), 0
        inc     l
        inc     e
        inc     e
        inc     e
        ld      a, (de)
.smc_r_outmask:
        and     0
.smc_r:
        or      0
        ld      (hl), a
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        ld      d, h
        ld      e, l
        set     7, d
        ld      a, (de)
.smc_b_l_outmask:
        and     0
.smc_b_l:
        or      0
        ld      (hl), a
        inc     l
.smc_b_m1:
        ld      (hl), 0
        inc     l
.smc_b_m2:
        ld      (hl), 0
        inc     l
        inc     e
        inc     e
        inc     e
        ld      a, (de)
.smc_b_r_outmask:
        and     0
.smc_b_r:
        or      0
        ld      (hl), a
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0                     ; SMC: 0 or 1
        or      a
        jr      z, .done
        ; Tail: 1 A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        ld      d, h
        ld      e, l
        set     7, d
        ld      a, (de)
.smc_tail_l_outmask:
        and     0
.smc_tail_l:
        or      0
        ld      (hl), a
        inc     l
.smc_tail_m1:
        ld      (hl), 0
        inc     l
.smc_tail_m2:
        ld      (hl), 0
        inc     l
        inc     e
        inc     e
        inc     e
        ld      a, (de)
.smc_tail_r_outmask:
        and     0
.smc_tail_r:
        or      0
        ld      (hl), a
.done:
        ld      sp, (saved_sp)
        ret

; paint_LMM: A/B-pair unrolled. Parity only affects M2 (A: smc_m2, B: smc_b_m2);
; L and M1 are identical across A/B (same SMC value patched to all 4 instances).
paint_LMM:
        ld      (paint_LMMR_start_line), a
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: 1 B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_pre_l:
        ld      (hl), 0
        inc     l
.smc_pre_m1:
        ld      (hl), 0
        inc     l
.smc_pre_b_m2:
        ld      (hl), 0
        dec     b
        jp      z, .done
.start_was_even:
        xor     a
        bit     0, b
        jr      z, .ce
        inc     a
        dec     b
.ce:
        ld      (.smc_count_odd + 1), a
        srl     b
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l:
        ld      (hl), 0
        inc     l
.smc_m1:
        ld      (hl), 0
        inc     l
.smc_m2:
        ld      (hl), 0
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_pair_b_l:
        ld      (hl), 0
        inc     l
.smc_pair_b_m1:
        ld      (hl), 0
        inc     l
.smc_b_m2:
        ld      (hl), 0
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0
        or      a
        jr      z, .done
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_tail_l:
        ld      (hl), 0
        inc     l
.smc_tail_m1:
        ld      (hl), 0
        inc     l
.smc_tail_m2:
        ld      (hl), 0
.done:
        ld      sp, (saved_sp)
        ret

paint_LM:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l:
        ld      (hl), 0
        inc     l
.smc_m:
        ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_L:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l:
        ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

; paint_MMR: A/B-pair unrolled. M1 same across A/B; M2 and R alternate.
paint_MMR:
        ld      (paint_LMMR_start_line), a
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: 1 B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_pre_m1:
        ld      (hl), 0
        inc     l
.smc_pre_b_m2:
        ld      (hl), 0
        inc     l
.smc_pre_b_r:
        ld      (hl), 0
        dec     b
        jp      z, .done
.start_was_even:
        xor     a
        bit     0, b
        jr      z, .ce
        inc     a
        dec     b
.ce:
        ld      (.smc_count_odd + 1), a
        srl     b
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_m1:
        ld      (hl), 0
        inc     l
.smc_m2:
        ld      (hl), 0
        inc     l
.smc_r:
        ld      (hl), 0
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_pair_b_m1:
        ld      (hl), 0
        inc     l
.smc_b_m2:
        ld      (hl), 0
        inc     l
.smc_b_r:
        ld      (hl), 0
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0
        or      a
        jr      z, .done
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_tail_m1:
        ld      (hl), 0
        inc     l
.smc_tail_m2:
        ld      (hl), 0
        inc     l
.smc_tail_r:
        ld      (hl), 0
.done:
        ld      sp, (saved_sp)
        ret

; paint_MR: A/B-pair unrolled. Both M and R alternate.
paint_MR:
        ld      (paint_LMMR_start_line), a
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: 1 B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_pre_b_m:
        ld      (hl), 0
        inc     l
.smc_pre_b_r:
        ld      (hl), 0
        dec     b
        jp      z, .done
.start_was_even:
        xor     a
        bit     0, b
        jr      z, .ce
        inc     a
        dec     b
.ce:
        ld      (.smc_count_odd + 1), a
        srl     b
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_m:
        ld      (hl), 0
        inc     l
.smc_r:
        ld      (hl), 0
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_b_m:
        ld      (hl), 0
        inc     l
.smc_b_r:
        ld      (hl), 0
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0
        or      a
        jr      z, .done
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_tail_m:
        ld      (hl), 0
        inc     l
.smc_tail_r:
        ld      (hl), 0
.done:
        ld      sp, (saved_sp)
        ret

; paint_R: A/B-pair unrolled. Only R cell, alternates.
paint_R:
        ld      (paint_LMMR_start_line), a
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
        ld      a, (paint_LMMR_start_line)
        bit     0, a
        jr      z, .start_was_even
        ; Preamble: 1 B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
.smc_pre_b_r:
        ld      (hl), 0
        dec     b
        jp      z, .done
.start_was_even:
        xor     a
        bit     0, b
        jr      z, .ce
        inc     a
        dec     b
.ce:
        ld      (.smc_count_odd + 1), a
        srl     b
        jp      z, .check_tail
.pair_loop:
        ; A line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
.smc_r:
        ld      (hl), 0
        ; B line
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
.smc_b_r:
        ld      (hl), 0
        djnz    .pair_loop
.check_tail:
.smc_count_odd:
        ld      a, 0
        or      a
        jr      z, .done
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
.smc_tail_r:
        ld      (hl), 0
.done:
        ld      sp, (saved_sp)
        ret

; Edge body city variants — same shape as their non-city counterparts but
; the L cell (right-edge variants) or R cell (left-edge variants) is written
; with masked OR against bg_buffer: `screen = pipe_byte | (bg_byte & out_mask)`
; so cityscape pattern fills outside-pipe pixels only, never inside the pipe.

paint_LMM_city:                         ; byte_x=30: L+M1+M2 visible
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l                       ; → L cell
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        inc     l                       ; → M1
.smc_m1:
        ld      (hl), 0
        inc     l                       ; → M2
        bit     0, h
        jr      nz, .odd
.smc_m2:
        ld      (hl), 0
        jr      .next
.odd:
.smc_b_m2:
        ld      (hl), 0
.next:
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_LM_city:                          ; byte_x=31: L+M visible
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l                       ; → L cell
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        inc     l                       ; → M
.smc_m:
        ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_L_city:                           ; byte_x=32: L cell only
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l                       ; → L cell
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_MMR_city:                         ; byte_x=0: M1+M2+R visible
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a                    ; → M1
.smc_m1:
        ld      (hl), 0
        inc     l                       ; → M2
        bit     0, h
        jr      nz, .odd
.smc_m2:
        ld      (hl), 0
        inc     l                       ; → R
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        jr      .next
.odd:
.smc_b_m2:
        ld      (hl), 0
        inc     l                       ; → R
        set     7, h
        ld      a, (hl)
.smc_b_r_outmask:
        and     0
        res     7, h
.smc_b_r:
        or      0
        ld      (hl), a
.next:
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_MR_city:                          ; byte_x=255: M+R visible (at cols 0,1)
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l                       ; → M (col 0)
        bit     0, h
        jr      nz, .odd
.smc_m:
        ld      (hl), 0
        inc     l                       ; → R (col 1)
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        jr      .next
.odd:
.smc_b_m:
        ld      (hl), 0
        inc     l
        set     7, h
        ld      a, (hl)
.smc_b_r_outmask:
        and     0
        res     7, h
.smc_b_r:
        or      0
        ld      (hl), a
.next:
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_R_city:                           ; byte_x=254: R cell only (at col 0)
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l                       ; → R (col 0)
        set     7, h
        ld      a, (hl)
        bit     0, h
        jr      nz, .odd
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        jr      .next
.odd:
.smc_b_r_outmask:
        and     0
        res     7, h
.smc_b_r:
        or      0
        ld      (hl), a
.next:
        djnz    .lp
        ld      sp, (saved_sp)
        ret

; paint_cap_rounded_* — 1-row rim with chamfered ends. 7 partial variants
; matching body variants for smooth entry/exit at screen edges.
paint_cap_rounded_LMMR:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l: ld      (hl), 0
        inc     l
.smc_m1: ld     (hl), 0
        inc     l
.smc_m2: ld     (hl), 0
        inc     l
.smc_r: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

; paint_cap_rounded_LMMR_city: cap-rim variant for the cityscape band.
; Same masked-OR approach as paint_LMMR_city — bg_buffer is OR'd into
; the L and R cells but only in pixels outside the 24-px cap shape, so
; the cap rim itself never has skyscraper inside it. M1/M2 stay direct
; writes (ATTR_PIPE green paper).
paint_cap_rounded_LMMR_city:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l                       ; HL → L cell
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        inc     l                       ; → M1
.smc_m1:
        ld      (hl), 0
        inc     l                       ; → M2
.smc_m2:
        ld      (hl), 0
        inc     l                       ; → R
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_LMM:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l: ld      (hl), 0
        inc     l
.smc_m1: ld     (hl), 0
        inc     l
.smc_m2: ld     (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_LM:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l: ld      (hl), 0
        inc     l
.smc_m: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_L:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
.smc_l: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_MMR:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_m1: ld     (hl), 0
        inc     l
.smc_m2: ld     (hl), 0
        inc     l
.smc_r: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_MR:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_m: ld      (hl), 0
        inc     l
.smc_r: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_R:
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
.smc_r: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

; Edge cap city variants — same shape as the non-city cap variants but
; with masked-OR against bg_buffer at the L/R cells (whichever the variant
; has). Used for cap rim lines that fall inside the cityscape band.

paint_cap_rounded_LMM_city:             ; byte_x=30: L+M1+M2
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        inc     l
.smc_m1: ld     (hl), 0
        inc     l
.smc_m2: ld     (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_LM_city:              ; byte_x=31: L+M
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        inc     l
.smc_m: ld      (hl), 0
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_L_city:               ; byte_x=32: L only
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        dec     l
        set     7, h
        ld      a, (hl)
.smc_l_outmask:
        and     0
        res     7, h
.smc_l:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_MMR_city:             ; byte_x=0: M1+M2+R
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
.smc_m1: ld     (hl), 0
        inc     l
.smc_m2: ld     (hl), 0
        inc     l
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_MR_city:              ; byte_x=255: M+R at cols 0,1
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
.smc_m: ld      (hl), 0
        inc     l
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

paint_cap_rounded_R_city:               ; byte_x=254: R only at col 0
        ld      h, 0
        ld      l, a
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      (saved_sp), sp
        ld      sp, hl
.lp:
        pop     hl
        ld      a, c
        add     a, l
        ld      l, a
        inc     l
        inc     l
        set     7, h
        ld      a, (hl)
.smc_r_outmask:
        and     0
        res     7, h
.smc_r:
        or      0
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
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
; starting at line A. Used as the "erase" when pipe leaves a col,
; so cityscape pixels survive.
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

; draw_bird: compiled-sprite version specialized for fixed col BIRD_X=8.
;   - `set 3, l` replaces `ld a,c; add a,l; ld l,a` (offsets to col 8 — bit 3
;     of L is always 0 because line_table addresses are 8-aligned).
;   - DE holds the sprite pointer (7-cyc `ld a,(de)`) instead of IY (19-cyc
;     `ld a,(iy+d)` + 10-cyc `inc iy`).
; ~85 cyc/line vs ~125 in the generic version. Saved ~640 cyc/frame.
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
        ld      de, bird_sprite
        ld      b, BIRD_LINES
.lp:
        pop     hl
        set     3, l                    ; HL → screen[col BIRD_X=8]
        ld      a, (de)
        or      (hl)
        ld      (hl), a
        inc     hl
        inc     de
        ld      a, (de)
        or      (hl)
        ld      (hl), a
        inc     de
        djnz    .lp
        ld      sp, (saved_sp)
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
.lp:
        pop     hl
        set     3, l                    ; HL → screen[col 8]
        ld      d, h
        ld      e, l
        set     7, d                    ; DE → bg_buffer at col 8
        ld      a, (de)
        ld      (hl), a
        inc     hl
        inc     e
        ld      a, (de)
        ld      (hl), a
        djnz    .lp
        ld      sp, (saved_sp)
        ret

;----------------------------------------------------------------
; Cap routines
;----------------------------------------------------------------

;----------------------------------------------------------------
; update_pipe_attrs:
;   Refill sky+city attr bands with defaults, then overwrite cells that
;   currently contain pipe pixels with ATTR_PIPE (paper green + ink black).
;   Ground band is static $20 = ATTR_PIPE already, no refill needed.
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
        cp      31
        jr      z, .case_31
        cp      255
        jr      z, .case_neg1
        cp      31
        jr      nc, .skip               ; byte_x in 32..254: skip
        ld      c, a                    ; byte_x in 0..30: paint M1, M2
        ld      a, (iy+1)
        ld      e, a
        call    paint_pipe_attrs_inner
        jr      .skip
.case_31:
        ld      c, 31                   ; LM: M1 only at col 31
        ld      a, (iy+1)
        ld      e, a
        call    paint_pipe_attrs_inner_1col
        jr      .skip
.case_neg1:
        ld      c, 0                    ; MR: M2 only at col 0
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
; refill_base_attrs: LDIR sky + ground + scoreboard rows, then overlay city.
; Used once at init to set up BACKUP_ATTRS. NOT called per frame anymore.
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
        jp      paint_city_attrs        ; tail-call

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
        cp      31
        jr      z, .case_31
        cp      255
        jr      z, .case_neg1
        cp      31
        jr      nc, .skip
        ld      c, a
        ld      a, (iy+1)
        ld      e, a
        call    restore_pipe_attrs_inner
        jr      .skip
.case_31:
        ld      c, 31
        ld      a, (iy+1)
        ld      e, a
        call    restore_pipe_attrs_inner_1col
        jr      .skip
.case_neg1:
        ld      c, 0
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
; paint_city_attrs: for each col, paint ATTR_CITY at the rows the building
; covers. cityscape_heights[col]/8 = number of city rows from the bottom up.
;----------------------------------------------------------------
paint_city_attrs:
        ld      iy, cityscape_heights
        ld      c, 0                    ; col counter
.col_lp:
        ld      a, (iy+0)
        or      a
        jr      z, .col_skip
        ; cells = height / 8 (heights are multiples of 8)
        srl     a
        srl     a
        srl     a
        ld      b, a                    ; B = cells (= row count for this building)
        ; top_row = 20 - cells
        ld      a, 20
        sub     b
        ; HL = ATTRS + top_row * 32 + col
        ld      h, 0
        ld      l, a
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl
        push    bc
        ld      bc, ATTRS
        add     hl, bc
        pop     bc
        ld      a, c
        add     a, l
        ld      l, a
        jr      nc, .nc
        inc     h
.nc:
.row_lp:
        ld      (hl), ATTR_CITY
        ld      a, l
        add     a, 32
        ld      l, a
        jr      nc, .nc2
        inc     h
.nc2:
        djnz    .row_lp
.col_skip:
        inc     iy
        inc     c
        ld      a, c
        cp      32
        jr      nz, .col_lp
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
