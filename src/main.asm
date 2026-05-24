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

; ─── Beeper sound effects ────────────────────────────────────────
SPK_BIT           EQU $10                ; bit 4 of port $FE = speaker
SOUND_BORDER      EQU $01                ; blue profile band for the sound region
EDGE_FIXED_ITERS  EQU 14                 ; per-edge non-delay overhead in delay-iter units (CALIBRATE — Task 6)
; Per-frame sound budget (delay-iters). One slice per frame, in the idle tail.
; Classified per frame type: build frames (~67k) and wrap/swap frames are
; heavier, so they get less sound budget to stay under the 70k T ceiling.
SND_SLICE_NORMAL  EQU 1100               ; budget on normal frames (CALIBRATE)
SND_SLICE_WRAP    EQU 0                  ; wrap/swap frames already at ~70k — no room for sound
SND_SLICE_CONFIG  EQU 0                  ; build frames are ~67k already — no room for sound

; ─── Slot grid layout — Stage 3: EXX-free 2-push slots ────────────
; The grid is 80 pipe-bands, band-interleaved:
;   P0.b0, P1.b0, P2.b0, P3.b0, P0.b1, …, P3.b19
; where band K (0..19) is screen rows 8K..8K+7 of one pipe.
;
; Every band is BAND_STRIDE = 80 bytes; entry at +0; trailer JP at a
; uniform +68 (JP next_band_base+0; band 79 → epilogue). Two forms:
;
;   BODY band  (12/pipe, outside the gap & caps):
;     +0   ld ix,band_screen_base        (4 B: $DD $21 lo hi)
;     +4   8 IX-walk rows, 6 B each (A on even band-rows, B on odd):
;       A:  DD F9   ld sp,ix
;           D5      push de              (DE = body bytes 2,3 of variant A)
;           C5      push bc              (BC = body bytes 0,1 shared by A/B)
;           DD 24   inc ixh              (+256 → next pixel row in cell)
;       B:  DD F9   ld sp,ix
;           E5      push hl              (HL = body bytes 2,3 of variant B)
;           C5      push bc
;           DD 24   inc ixh
;     +52  end of last row; +52..67 NOP-bridge to the +68 trailer.
;   Scrolling patches ONE immediate per body band (ld ix operand, +2..3).
;
;   CAP/SKIP band  (cap-edge ×2/pipe, skip ×6/pipe — still per-row in S3):
;     +0   8 per-row slots, 5 B each (A on even band-rows, B on odd):
;       A:  31 lo hi D5 C5   ld sp,target ; push de ; push bc
;       B:  31 lo hi E5 C5   ld sp,target ; push hl ; push bc
;     Skip row: 18 03 00 00 00              JR +3 → next slot.
;     Cap row: C3 lo hi 00 00               JP cap_handler; 2 pad.
;     +40  end of last row; +40..67 NOP-bridge to the +68 trailer.
;   cap-edge bands keep per-row scroll targets (Stage 4 folds them in).
;
; A/B parity: a band starts at screen row 8K (even), so band-row index N's
; screen-row parity = N mod 2. Even band-rows are A; odd are B.
SLOT_GRID_BASE         EQU $DB00
BAND_ROWS              EQU 8                          ; rows per char-cell band
NUM_BANDS              EQU 80                         ; 20 char-cells × 4 pipes
BAND_ROW_STRIDE        EQU 5                          ; cap/skip row: 5-byte slot (no EXX)
BAND_IX_PREFIX         EQU 4                          ; body band: ld ix,nn  ($DD $21 lo hi)
BAND_IXROW_STRIDE      EQU 6                          ; body row: ld sp,ix + 2 push + inc ixh
BAND_STRIDE            EQU 80                         ; 4 + 8*6 = 52 used (body); trailer at +68
SLOT_GRID_END          EQU SLOT_GRID_BASE + NUM_BANDS * BAND_STRIDE  ; $DB00 + 80*80 = $F400
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

; Trailer JP at a uniform offset for both band forms.
BAND_TRAILER_OFFSET    EQU 68

; Slot format (Stage 3): 5 bytes. Two variants:
;   A-row: $31 lo hi $D5 $C5   ld sp,target ; push de ; push bc
;   B-row: $31 lo hi $E5 $C5   ld sp,target ; push hl ; push bc
; The single differing byte is at slot+3 ($D5 for A, $E5 for B).
SLOT_STRIDE            EQU 5

; ─── Slot-grid template store (init-time, then read-only) ─────────
; Stage 3: 5-byte slot stride (no EXX). A/B variants alternate per row.
;   BODY_TEMPLATE       800 bytes  (160 rows × 5 bytes, byte_x=29 body slots)
;   CAP_BLOCK           250 bytes  (50 rows × 5 bytes: cap_top + 48 skip + cap_bot)
;   CAP_TARGET_TABLE     48 bytes  (12 gap_y entries × 4 bytes)
TEMPLATE_BASE          EQU $C000
BODY_TEMPLATE          EQU TEMPLATE_BASE                  ; $C000..$C31F (160*5=800 bytes)
CAP_BLOCK              EQU BODY_TEMPLATE + 800            ; 800 bytes for body → cap_block starts here
CAP_TARGET_TABLE       EQU CAP_BLOCK + 250                ; 50 rows × 5 bytes/slot
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
        xor     a
        ld      (sound_heavy_frame), a
        ; Classify this frame → per-frame sound budget. Build frames
        ; (activate_pipe_idx != 255, ~67k) get the tiny budget; wrap/swap
        ; frames (phase == 6 at frame top → this frame wraps) get the reduced
        ; budget; everything else gets the full normal budget.
        ld      hl, SND_SLICE_CONFIG
        ld      a, (activate_pipe_idx)
        inc     a                       ; 255 -> 0
        jr      nz, .snd_slice_set      ; build frame in progress → CONFIG
        ld      hl, SND_SLICE_WRAP
        ld      a, (phase)
        cp      6                       ; phase 6 → second advance_phase wraps
        jr      z, .snd_slice_set       ; wrap/swap frame → WRAP
        ld      hl, SND_SLICE_NORMAL
.snd_slice_set:
        ld      (sound_slice_budget), hl
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
        ld      a, 6                    ; PROFILE: YELLOW = column build
        out     ($fe), a
        ; Amortized column build. do_swap sets activate_pipe_idx to the
        ; just-activated pipe and do_swap_fired=1. The swap frame itself skips
        ; the build (do_swap_fired); subsequent frames run up to 6 prep_step
        ; chunks each, spreading the ~20k build over ~3 frames — small enough
        ; per frame to stay under budget, short enough total (~3 frames <
        ; one 4-frame wrap) that pipe spacing is not disturbed. ps_phase6
        ; sets activate_pipe_idx=255 when the build completes.
        ld      a, (do_swap_fired)
        or      a
        jr      nz, .swap_frame_skip
        ld      b, 6                            ; max prep_step chunks this frame
.build_loop:
        ld      a, (activate_pipe_idx)
        cp      255
        jr      z, .post_prep_step              ; idle, or build just finished
        ld      a, 1
        ld      (sound_heavy_frame), a
        push    bc
        call    prep_step
        pop     bc
        djnz    .build_loop
        jr      .post_prep_step
.swap_frame_skip:
        xor     a
        ld      (do_swap_fired), a
        ld      a, 1
        ld      (sound_heavy_frame), a
.post_prep_step:
        call    sfx_slice               ; sound — single slice in the idle tail
        ld      a, 0                    ; PROFILE: BLACK = idle before halt
        out     ($fe), a
        ei
        jp      main_loop

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
        ; 4 pipes. 3 active + 1 preparing.
        ; The 3 active pipes are spaced evenly across the [1,29] track
        ; (~9-10 byte_x apart). The recycle scheme (leave at 1, enter at 29)
        ; preserves this spacing — so even init = even forever.
        db 29, 64                       ; pipe 0
        db 19, 40                       ; pipe 1
        db 10, 88                       ; pipe 2
        db  8, 24                       ; pipe 3 (prep; byte_x set to 29 at init)

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

; ─── Sound engine state (read/write, persists across frames) ─────
sound_active:     db 0                   ; 0 = idle, 1 = an effect is playing
sound_id:         db 0                   ; 0 = flap, 1 = chime
sound_descptr:    dw 0                   ; -> current segment in descriptor table
sound_edges_left: dw 0                   ; edges remaining in the current segment
sound_half:       dw 0                   ; current edge half-period (delay-loop iters)
sound_speaker:    db 0                   ; current speaker bit ($00 or $10)
sound_sweep:      db 0                   ; signed half-period delta applied per edge
sound_mode:       db 0                   ; current segment mode: 0 = tone, 1 = noise
sound_lfsr:       dw $7ACE               ; 16-bit LFSR state for noise (must stay nonzero)
sound_budget:     dw 0                   ; delay-iters of sound permitted this frame
sound_heavy_frame: db 0                  ; 1 = configure/swap/build frame this frame
sound_slice_budget: dw 0                 ; per-slice delay-iter budget, set once per frame

; ─── SFX descriptors ─────────────────────────────────────────────
; segment = db mode(0=tone,1=noise,$FF=end) : dw half_period : dw edge_count : db sweep
; Flap "fwip": noise burst, clock rate sweeps downward (darkens as it fades).
sfx_flap:
        db 1 : dw  90 : dw 70 : db  3
        db 1 : dw 160 : dw 55 : db  6
        db 1 : dw 280 : dw 40 : db 10
        db $FF
; Score sound: ascending 3-blip arpeggio ("coin pickup"). Each blip is short
; enough that the 50 Hz frame-slice gate has no time to become an audible buzz.
sfx_chime:
        db 0 : dw 50 : dw 48 : db 0   ; blip 1 — ~1350 Hz
        db 0 : dw 40 : dw 56 : db 0   ; blip 2 — ~1680 Hz
        db 0 : dw 32 : dw 80 : db 0   ; blip 3 — ~2100 Hz, held longest
        db $FF

scroll_extra: db 0                      ; mod-5 counter for 1.2 px/frame avg
wrap_pending:  db 0                      ; set when a wrap happened this frame
; Phase 5: pending_regen, recycled_pipe_idx and patch_pending removed.
prep_pipe_idx:   db 3                  ; Phase 3: pipe 3 starts as the preparing column
; Phase 4: incremental-prepare state machine variables.
; prep_phase 0..6 = which configure sub-step we are on; 7 = done.
; prep_row  0..N  = current row within the current phase (phases 0, 2 use rows;
;                   phases 1 uses rows into cap range; phase 6 uses entry index).
; prep_gap_y      = gap_y for pipe 3 (set at game start from pipe_state[3*2+1]).
prep_phase:      db 0
prep_row:        db 0
prep_gap_y:      db 8
; Pipe whose column prep_step is currently building post-swap.
; 255 = no build in progress (prep_step is idle).
activate_pipe_idx: db 255

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
; of the (row, pipe) slot's first byte.
;
; Stage 3 band-interleaved layout. For screen row R (0..159), pipe P (0..3):
;   K        = R >> 3            char-cell band index (0..19)
;   band_row = R & 7             row within the band (0..7)
;   e        = K*4 + P           band-interleaved execution index (0..79)
;   slot_addr = SLOT_GRID_BASE + e*BAND_STRIDE + band_row*BAND_ROW_STRIDE
;             (BAND_ROW_STRIDE = 5; no leading EXX)
;
; This table is the SINGLE SOURCE OF TRUTH for slot addresses — every
; consumer routine looks slots up here rather than recomputing a formula.
;
; Entry index: row*4 + pipe (16-bit address per entry).
; Total table size: 640 × 2 = 1280 bytes at SLOT_ADDR_TABLE.
;----------------------------------------------------------------
init_slot_addr_table:
        ld      ix, SLOT_ADDR_TABLE
        ld      b, 0                            ; B = screen row 0..159
.row_lp:
        push    bc
        ; --- band_row offset within band = (R & 7) * BAND_ROW_STRIDE ---
        ; BAND_ROW_STRIDE = 5 = 4 + 1: double-double to *4, then add *1.
        ld      a, b
        and     7
        ld      c, a                            ; C = band_row (0..7)
        add     a, a                            ; *2
        add     a, a                            ; *4
        add     a, c                            ; *4 + *1 = *5  = band_row*5
        ld      c, a                            ; C = band_row*5
        ; --- K*4 = (R >> 3) << 2 = (R & ~7) >> 1 ---
        ld      a, b
        and     $F8                             ; A = R with low 3 bits cleared = K*8
        srl     a                               ; A = K*4
        ld      e, a                            ; E = K*4 (pipe 0's band index)
        ld      b, NUM_PIPES                    ; 4 pipes
.wp_lp:
        ; HL = SLOT_GRID_BASE + e*BAND_STRIDE + C  (BAND_STRIDE = 80; e = E)
        ; e*80 = e*16 + e*64.  Band index e is held in B'... no — kept in E,
        ; preserved across the arithmetic via the stack.
        push    de                              ; save band index e (in E)
        ld      l, e
        ld      h, 0
        add     hl, hl                          ; e*2
        add     hl, hl                          ; e*4
        add     hl, hl                          ; e*8
        add     hl, hl                          ; e*16
        ld      d, h
        ld      e, l                            ; DE = e*16
        add     hl, hl                          ; e*32
        add     hl, hl                          ; e*64
        add     hl, de                          ; e*64 + e*16 = e*80
        ld      d, 0
        ld      e, c                            ; DE = band_row*5
        add     hl, de                          ; HL = e*80 + C
        ld      a, l
        add     a, low SLOT_GRID_BASE
        ld      l, a
        ld      a, h
        adc     a, high SLOT_GRID_BASE
        ld      h, a                            ; HL = slot addr
        ld      (ix+0), l
        ld      (ix+1), h
        inc     ix
        inc     ix
        pop     de                              ; restore band index e
        inc     e                               ; next pipe → e += 1
        djnz    .wp_lp

        pop     bc
        inc     b
        ld      a, b
        cp      GROUND_TOP
        jr      nz, .row_lp
        ret

;----------------------------------------------------------------
; init_pipe_program: lay down the band skeleton in PIPE_PROGRAM memory.
;
; Stage 2b: every band's BODY content is written later by
; configure_pipe_slots (pipes 0-2) or write_jrskip_column (pipe 3),
; before the grid is ever executed. This routine only:
;   - NOP-fills the whole grid body (+0..67 of every band). NOPs fall
;     through to the trailer — a valid no-op chain — and also serve as
;     the +56..67 bridge for cap/skip bands (whose rows end at +56).
;   - Writes the 80 band trailers at +BAND_TRAILER_OFFSET (68): each a
;     JP to the next band's base; band 79 → SLOT_GRID_END.
;   - Writes the 5-byte epilogue at SLOT_GRID_END (ld sp,(saved_sp); ret).
;----------------------------------------------------------------
init_pipe_program:
        ; ── NOP-fill the whole grid body ($00) ───────────────────
        ld      hl, SLOT_GRID_BASE
        ld      de, SLOT_GRID_BASE + 1
        ld      (hl), 0
        ld      bc, NUM_BANDS * BAND_STRIDE - 1
        ldir

        ; ── Write the 80 band trailers ───────────────────────────
        ; Band e (0..79) trailer at SLOT_GRID_BASE + e*80 + 68.
        ; Bands 0..78: JP next band base = SLOT_GRID_BASE + (e+1)*80.
        ; Band 79    : JP SLOT_GRID_END (epilogue).
        ld      hl, SLOT_GRID_BASE + BAND_TRAILER_OFFSET   ; trailer of band 0
        ld      de, SLOT_GRID_BASE + BAND_STRIDE            ; base of band 1
        ld      b, NUM_BANDS
.ipp_tr_lp:
        ld      (hl), $C3                       ; opcode: jp nn
        inc     hl
        ld      a, b
        cp      1                               ; last band?
        jr      nz, .ipp_tr_normal
        ; band 79 → JP SLOT_GRID_END
        ld      (hl), low SLOT_GRID_END
        inc     hl
        ld      (hl), high SLOT_GRID_END
        jr      .ipp_tr_done
.ipp_tr_normal:
        ld      (hl), e                         ; next band base lo
        inc     hl
        ld      (hl), d                         ; next band base hi
        ; advance HL (trailer+2 → next trailer) and DE (→ next band base)
        ld      a, l
        add     a, BAND_STRIDE - 2              ; from trailer+2 to next trailer
        ld      l, a
        jr      nc, .ipp_tr_hnc
        inc     h
.ipp_tr_hnc:
        ld      a, e
        add     a, BAND_STRIDE
        ld      e, a
        jr      nc, .ipp_tr_dnc
        inc     d
.ipp_tr_dnc:
        djnz    .ipp_tr_lp
.ipp_tr_done:

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
; emit_body_band: write a pure-body band into the grid (IX-walk form).
;   +0   ld ix,<screen_base>     ($DD $21 lo hi)
;   +4   8 IX-walk rows, 6 bytes each (no EXX; A/B by row parity):
;          A-row:  DD F9   ld sp,ix
;                  D5      push de         (variant A bytes 2,3)
;                  C5      push bc         (shared bytes 0,1)
;                  DD 24   inc ixh         (+256 → next pixel row)
;          B-row:  DD F9   ld sp,ix
;                  E5      push hl         (variant B bytes 2,3)
;                  C5      push bc
;                  DD 24   inc ixh
; The trailer at +68 is left untouched (written by init_pipe_program).
; band_base+0 IS overwritten, so any prior JR-skip / per-row content is
; cleanly replaced — no stale-byte hazard.
;
; In:  HL = grid band base address
;      DE = screen base value (the ld ix operand = band_row-0 target)
; Clobbers: AF, B, C, HL.  DE preserved.
;----------------------------------------------------------------
; ── Stage 4 cap-edge band layout ─────────────────────────────────
;
; K_top band  (cap at band-row 7, last row of band):
;   +0..3   DD 21 lo hi      ld ix, screen_target_table_29[8*K_top]
;   +4..45  7 IX-walk rows (band-rows 0..6, A,B,A,B,A,B,A; 6 B each)
;   +46     C3               JP cap_top_handler (handler addr patched later)
;   +47..48 00 00            cap handler operand placeholder
;   +49..67 NOP bridge
;   +68..   band trailer
;
; K_bot band  (cap at band-row 0, first row of band):
;   +0..3   DD 21 lo hi      ld ix, screen_target_table_29[8*K_bot + 1]
;                            (NB: +1 entry — band-row 0 is the cap, doesn't
;                            use IX; the IX-walk covers band-rows 1..7 from
;                            base+256, so the operand must point at band-row
;                            1's address, not band-row 0's.)
;   +4      C3               JP cap_bot_handler (handler addr patched later)
;   +5..6   00 00            cap handler operand placeholder
;   +7..48  7 IX-walk rows (band-rows 1..7, B,A,B,A,B,A,B; 6 B each)
;   +49..67 NOP bridge
;   +68..   band trailer
;
; cap handler _next imms (cap_top / cap_bot) point to:
;   cap_top: band_base + 68  (the trailer; JPs to next band base)
;   cap_bot: band_base + 7   (first byte of the IX-walk)
;----------------------------------------------------------------
emit_body_band:
        ld      (hl), $DD               ; ld ix,nn  byte 1
        inc     hl
        ld      (hl), $21               ; ld ix,nn  byte 2
        inc     hl
        ld      (hl), e                 ; operand lo
        inc     hl
        ld      (hl), d                 ; operand hi
        inc     hl                      ; HL → band_base+4 (first IX row)
        ; Rows 0..7. Even = A (push de = $D5), odd = B (push hl = $E5).
        ; Unroll as 4 A/B pairs.
        ld      b, 4                    ; 4 A/B pairs = 8 rows
.ebb_pair:
        ; --- A-row (even band-row): ld sp,ix ; push de ; push bc ; inc ixh ---
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $D5               ; push de
        inc     hl
        ld      (hl), $C5               ; push bc
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        ; --- B-row (odd band-row): ld sp,ix ; push hl ; push bc ; inc ixh ---
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $E5               ; push hl
        inc     hl
        ld      (hl), $C5               ; push bc
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        djnz    .ebb_pair
        ret

;----------------------------------------------------------------
; emit_capedge_band: write a K_top or K_bot cap-edge band into the grid
; in the IX-walk form. Identical scrolling cost to a body band — the
; band carries ONE base immediate (the ld ix operand at +2).
;
; In:  HL = grid band base address
;      DE = screen base value for the ld ix operand
;           K_top: screen_target_table_29[8*K_top]      (band-row 0)
;           K_bot: screen_target_table_29[8*K_bot + 1]  (band-row 1!)
;      A  = 0 for K_top, 1 for K_bot
; The cap-slot $C3 (JP) opcode is stamped here; the cap handler ADDRESS
; (the JP operand) is patched separately by the cap-arm step in
; configure_pipe_slots / ps_phase6. The cap handler's _next imm is
; patched by compute_next_slot.
; Clobbers: AF, B, C, HL.  DE preserved (re-used by callers across bands).
;----------------------------------------------------------------
emit_capedge_band:
        or      a
        jr      nz, .ecb_bot
        ; ── K_top: 7 IX-walk rows (A,B,A,B,A,B,A) then cap slot ──
        ld      (hl), $DD               ; ld ix,nn
        inc     hl
        ld      (hl), $21
        inc     hl
        ld      (hl), e                 ; operand lo
        inc     hl
        ld      (hl), d                 ; operand hi
        inc     hl                      ; HL = band_base+4
        ; band-rows 0..6: A,B,A,B,A,B,A — 3 A/B pairs + 1 A row.
        ld      b, 3
.ecb_top_pair:
        ; A-row
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $D5               ; push de
        inc     hl
        ld      (hl), $C5               ; push bc
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        ; B-row
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $E5               ; push hl
        inc     hl
        ld      (hl), $C5
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        djnz    .ecb_top_pair
        ; Trailing A-row (band-row 6)
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $D5
        inc     hl
        ld      (hl), $C5
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl                      ; HL = band_base+46 (cap slot)
        ; Cap slot: JP cap_top_handler (operand placeholder; patched later)
        ld      (hl), $C3
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        ret
.ecb_bot:
        ; ── K_bot: cap slot then 7 IX-walk rows (B,A,B,A,B,A,B) ──
        ld      (hl), $DD               ; ld ix,nn
        inc     hl
        ld      (hl), $21
        inc     hl
        ld      (hl), e                 ; operand lo (band-row 1's address)
        inc     hl
        ld      (hl), d                 ; operand hi
        inc     hl                      ; HL = band_base+4 (cap slot)
        ; Cap slot: JP cap_bot_handler
        ld      (hl), $C3
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl                      ; HL = band_base+7 (first IX-walk row)
        ; band-rows 1..7: B,A,B,A,B,A,B — 1 B row then 3 A/B-as-pair iters.
        ; Leading B-row (band-row 1)
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $E5
        inc     hl
        ld      (hl), $C5
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        ld      b, 3
.ecb_bot_pair:
        ; A-row
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $D5
        inc     hl
        ld      (hl), $C5
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        ; B-row
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $E5
        inc     hl
        ld      (hl), $C5
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24
        inc     hl
        djnz    .ecb_bot_pair
        ret

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
        ; Band-interleaved: each row's dest slot is looked up from
        ; SLOT_ADDR_TABLE; the template src advances 5 bytes per row (Stage 3).
        ld      a, (cps_cap_top_row)
        or      a
        jr      z, .cps_body_a_done             ; skip if cap_top_row == 0
        ld      iyl, a                          ; counter = cap_top_row
        ld      hl, BODY_TEMPLATE               ; src (advances +5/row)
        xor     a
        ld      (cps_row_cursor), a             ; row cursor starts at 0
.cps_body_a_lp:
        push    hl                              ; save template src
        ld      a, (cps_row_cursor)
        ld      hl, cps_pipe
        ld      c, (hl)
        call    slot_addr_lookup                ; HL = slot[row][pipe]
        ex      de, hl                          ; DE = dest slot (Stage 3: no leading EXX)
        pop     hl                              ; HL = template src
        ldi
        ldi
        ldi
        ldi
        ldi
        ld      a, (cps_row_cursor)
        inc     a
        ld      (cps_row_cursor), a
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

        ; row cursor starts at cap_bot_row + 1
        ld      a, (cps_cap_bot_row)
        inc     a
        ld      (cps_row_cursor), a
        ; HL = BODY_TEMPLATE + (cap_bot_row+1) * 5  (Stage 3 stride)
        ld      a, (cps_cap_bot_row)
        inc     a                               ; A = cap_bot_row + 1
        ld      l, a
        ld      h, 0
        ld      d, h
        ld      e, l                            ; DE = (cap_bot_row+1)
        add     hl, hl                          ; HL = (cap_bot_row+1) * 2
        add     hl, hl                          ; HL = (cap_bot_row+1) * 4
        add     hl, de                          ; HL = (cap_bot_row+1) * 5
        ld      de, BODY_TEMPLATE
        add     hl, de                          ; HL = BODY_TEMPLATE + (cap_bot_row+1)*5
.cps_body_b_lp:
        push    hl                              ; save template src
        ld      a, (cps_row_cursor)
        ld      hl, cps_pipe
        ld      c, (hl)
        call    slot_addr_lookup                ; HL = slot[row][pipe]
        ex      de, hl                          ; DE = dest slot
        pop     hl                              ; HL = template src
        ldi
        ldi
        ldi
        ldi
        ldi
        ld      a, (cps_row_cursor)
        inc     a
        ld      (cps_row_cursor), a
        dec     iyl
        jr      nz, .cps_body_b_lp
.cps_body_b_done:

        ; ─── Step 2: stamp CAP_BLOCK at slot[cap_top_row][pipe] ─────
        ; 50 rows: cap_top_row .. cap_top_row+49. Band-interleaved dest
        ; addresses are looked up per row from SLOT_ADDR_TABLE.
        ld      a, (cps_cap_top_row)
        ld      (cps_row_cursor), a             ; row cursor = cap_top_row
        ld      hl, CAP_BLOCK
        ld      iyl, 50                         ; 50 rows in cap block
.cps_cap_stamp_lp:
        push    hl                              ; save template src
        ld      a, (cps_row_cursor)
        ld      hl, cps_pipe
        ld      c, (hl)
        call    slot_addr_lookup                ; HL = slot[row][pipe]
        ex      de, hl                          ; DE = dest slot (Stage 3: no leading EXX)
        pop     hl                              ; HL = template src
        ldi
        ldi
        ldi
        ldi
        ldi
        ld      a, (cps_row_cursor)
        inc     a
        ld      (cps_row_cursor), a
        dec     iyl
        jr      nz, .cps_cap_stamp_lp

        ; ─── Step 2b: convert pure-body bands to the IX-walk form ───
        call    cps_emit_body_bands

        ; ─── Step 3: patch cap-slot handler addresses (pipe-specific) ─
        ; Stage 4: cap slot positions are now computed from cps_band_base
        ; (the per-row slot_addr_lookup formula no longer addresses cap rows
        ;  inside the IX-walk cap-edge band).
        ;   K_top band: cap slot at band_base + 46 (after 7 IX-walk rows)
        ;   K_bot band: cap slot at band_base + 4  (after the ld ix)
        ; The +1 step (skip the $C3 opcode) is the same.

        ; cap_top: HL = band_base(K_top) + 46 + 1 = band_base + 47 (operand lo)
        ld      a, (cps_k_top)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_top band base
        ld      de, 47                          ; +46 cap slot, +1 to skip $C3
        add     hl, de
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

        ; cap_bot: HL = band_base(K_bot) + 4 + 1 = band_base + 5 (operand lo)
        ld      a, (cps_k_bot)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_bot band base
        ld      de, 5                           ; +4 cap slot, +1 to skip $C3
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

        ; ─── Step 6: build active sublist (per-band, 112 entries) ───
        call    cps_build_active_list

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
; slot_addr_lookup: read SLOT_ADDR_TABLE[row*4 + pipe] → HL.
; In:  A = row (0..159), C = pipe (0..3)
; Out: HL = slot[row][pipe] physical address
; Clobbers: A, DE, HL.  B preserved.
;----------------------------------------------------------------
slot_addr_lookup:
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        add     hl, hl                  ; row*4
        add     hl, hl                  ; row*8
        ld      a, c
        add     a, a                    ; pipe*2
        add     a, l
        ld      l, a
        jr      nc, .sal_nc
        inc     h
.sal_nc:
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl                  ; HL = slot[row][pipe]
        ret

;----------------------------------------------------------------
; compute_next_slot: given a cap row and the current pipe, return the address
; of the next slot to execute after the cap handler finishes.
;
; Stage 4 band-interleaved IX-walk cap-edge layout:
;   cap_top_row = gap_y-1  → K_top band-row 7 (cap slot at band_base+46).
;   cap_bot_row = gap_y+48 → K_bot band-row 0 (cap slot at band_base+4).
;
; cap_top: next = band_base + 68 (the band trailer; JPs to next band base).
;          Skips the NOP bridge — the trailer alone is enough.
; cap_bot: next = band_base + 7 (first byte of the 7-row IX-walk for
;          band-rows 1..7, i.e. the leading `ld sp,ix` opcode `$DD F9`).
;
; Input:  A = cap_row (0..159), cps_pipe = pipe index (0..3)
; Output: HL = address of next slot
; Clobbers: AF, BC, DE
;----------------------------------------------------------------
compute_next_slot:
        ld      b, a                    ; B = cap row
        ; K = cap_row >> 3
        srl     a
        srl     a
        srl     a                       ; A = K
        ld      (cps_k), a
        ld      a, b
        and     7
        cp      7
        jr      z, .cns_band_last
        ; cap_bot (band-row 0): next = band_base + 7
        call    cps_band_base           ; HL = K_bot band base (uses cps_k)
        ld      de, 7
        add     hl, de
        ret
.cns_band_last:
        ; cap_top (band-row 7): next = band_base + 68 (trailer)
        call    cps_band_base           ; HL = K_top band base (uses cps_k)
        ld      de, BAND_TRAILER_OFFSET ; = 68
        add     hl, de
        ret

;----------------------------------------------------------------
; cps_band_base: HL = grid base of band (cps_k, cps_pipe).
;   = SLOT_GRID_BASE + (cps_k*4 + cps_pipe) * 80
; In:  cps_k, cps_pipe (memory).   Clobbers: AF, DE, HL.
;----------------------------------------------------------------
cps_band_base:
        ld      a, (cps_k)
        add     a, a
        add     a, a                            ; K*4
        ld      hl, cps_pipe
        add     a, (hl)                         ; e = K*4 + pipe
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; e*2
        add     hl, hl                          ; e*4
        add     hl, hl                          ; e*8
        add     hl, hl                          ; e*16
        ld      d, h
        ld      e, l                            ; DE = e*16
        add     hl, hl                          ; e*32
        add     hl, hl                          ; e*64
        add     hl, de                          ; e*80
        ld      de, SLOT_GRID_BASE
        add     hl, de                          ; HL = band base
        ret

;----------------------------------------------------------------
; cps_emit_body_rows: write IYL active-list entries, one per row, each
; = slot_addr(cps_row_cursor, cps_pipe)+1; advances cps_row_cursor.
; In:  DE = write cursor, IYL = count (>0), cps_row_cursor = first row.
; Out: DE advanced.   Clobbers: AF, BC, HL, IYL.
;----------------------------------------------------------------
cps_emit_body_rows:
.cebr_lp:
        push    de
        ld      a, (cps_row_cursor)
        ld      hl, cps_pipe
        ld      c, (hl)
        call    slot_addr_lookup                ; HL = slot[row][pipe]
        inc     hl                              ; HL = slot+1 (target imm lo)
        pop     de
        ex      de, hl                          ; HL = cursor, DE = entry
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ex      de, hl                          ; DE = cursor advanced
        ld      a, (cps_row_cursor)
        inc     a
        ld      (cps_row_cursor), a
        dec     iyl
        jr      nz, .cebr_lp
        ret

;----------------------------------------------------------------
; cps_emit_capedge: write a cap-edge band's 8 active-list entries.
; Stage 4: the cap-edge band is now IX-walk, so it carries ONE base
; immediate (the ld ix operand at band_base+2) — same as a body band.
; The 7 body rows are walked via inc ixh and have no scroll targets.
; The cap row has its own target imm in the cap handler.
; Entry layout (8 entries):
;   +0 (1)  band_base+2          (ld ix operand low byte address)
;   +1 (1)  cap_*_target_imm     (from cap_*_target_imm_addrs[cps_pipe])
;   +2..+7  scroll_sink ×6       (dummies — keep list length 112/pipe)
; cps_k is K_top or K_bot.
; In:  DE = write cursor.   Out: DE advanced by 16 (8 entries).
; Clobbers: AF, BC, HL.
;----------------------------------------------------------------
cps_emit_capedge:
        ; --- entry 0: band base ld-ix operand (band_base+2) ---
        push    de
        call    cps_band_base                   ; HL = band base
        inc     hl
        inc     hl                              ; HL = band_base+2 (ld ix operand lo)
        pop     de
        ex      de, hl                          ; HL = cursor, DE = entry
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ex      de, hl                          ; DE = cursor

        ; --- entry 1: cap_*_target_imm[cps_pipe] ---
        ld      a, (cps_k)
        ld      hl, cps_k_bot
        cp      (hl)
        jr      z, .cec_cap_bot
        ld      hl, cap_top_target_imm_addrs
        jr      .cec_capimm
.cec_cap_bot:
        ld      hl, cap_bot_target_imm_addrs
.cec_capimm:
        ld      a, (cps_pipe)
        add     a, a
        add     a, l
        ld      l, a
        jr      nc, .cec_ci_nc
        inc     h
.cec_ci_nc:
        ld      a, (hl)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a
        inc     de

        ; --- entries 2..7: 6 × scroll_sink dummies ---
        ld      b, 6
.cec_dummy:
        ld      a, low scroll_sink
        ld      (de), a
        inc     de
        ld      a, high scroll_sink
        ld      (de), a
        inc     de
        djnz    .cec_dummy
        ret

;----------------------------------------------------------------
; cps_set_k_bounds: cps_k_top = cap_top_row>>3 ; cps_k_bot = cap_bot_row>>3.
; In: cps_cap_top_row, cps_cap_bot_row.   Clobbers: AF.
;----------------------------------------------------------------
cps_set_k_bounds:
        ld      a, (cps_cap_top_row)
        rrca
        rrca
        rrca
        and     $1F
        ld      (cps_k_top), a
        ld      a, (cps_cap_bot_row)
        rrca
        rrca
        rrca
        and     $1F
        ld      (cps_k_bot), a
        ret

;----------------------------------------------------------------
; cps_emit_body_bands: overwrite every IX-walk band of pipe cps_pipe with
; its IX-walk form:
;   K < K_top  or  K > K_bot   → pure body band (emit_body_band)
;   K == K_top                 → K_top cap-edge band (emit_capedge_band, flag=0)
;   K == K_bot                 → K_bot cap-edge band (emit_capedge_band, flag=1)
;   K_top < K < K_bot          → skip band, left in per-row CAP_BLOCK form
;                                (the 48 skip rows in between).
; Sets cps_k_top / cps_k_bot first. The ld ix operand comes from
; screen_target_table_29 — see emit_capedge_band's header for the K_bot
; +1 entry subtlety. byte_x=29 baseline; shift_pipe_targets adjusts.
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
cps_emit_body_bands:
        call    cps_set_k_bounds
        xor     a
        ld      (cps_k), a
.cebb_lp:
        ld      a, (cps_k)
        ld      hl, cps_k_top
        cp      (hl)
        jr      c, .cebb_body                   ; K < K_top → body
        jr      z, .cebb_capedge_top            ; K == K_top → cap-edge top
        ld      hl, cps_k_bot
        cp      (hl)
        jr      z, .cebb_capedge_bot            ; K == K_bot → cap-edge bot
        jr      c, .cebb_next                   ; K_top < K < K_bot → skip
        jr      .cebb_body                      ; K > K_bot → body
.cebb_body:
        call    cps_band_base                   ; HL = grid band base
        push    hl
        ; DE = screen_target_table_29[8K]  (entry 8K → byte offset 16K)
        ld      a, (cps_k)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; K*16
        ld      de, screen_target_table_29
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = screen base (byte_x=29)
        pop     hl                              ; HL = grid band base
        call    emit_body_band
        jr      .cebb_next
.cebb_capedge_top:
        call    cps_band_base                   ; HL = grid band base
        push    hl
        ; DE = screen_target_table_29[8*K_top]  (band-row 0 of K_top band)
        ld      a, (cps_k)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; K_top*16
        ld      de, screen_target_table_29
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = screen base for band-row 0
        pop     hl                              ; HL = grid band base
        xor     a                               ; flag = 0 → K_top
        call    emit_capedge_band
        jr      .cebb_next
.cebb_capedge_bot:
        call    cps_band_base                   ; HL = grid band base
        push    hl
        ; DE = screen_target_table_29[8*K_bot + 1]  (band-row 1 of K_bot band!)
        ; Byte offset = K_bot*16 + 2.
        ld      a, (cps_k)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; K_bot*16
        ld      de, screen_target_table_29 + 2
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = screen base for band-row 1
        pop     hl                              ; HL = grid band base
        ld      a, 1                            ; flag = 1 → K_bot
        call    emit_capedge_band
.cebb_next:
        ld      a, (cps_k)
        inc     a
        ld      (cps_k), a
        cp      20
        jr      nz, .cebb_lp
        ret

;----------------------------------------------------------------
; cps_build_active_list: build pipe cps_pipe's 112-entry active sublist.
;   body band: ld ix operand (band_base+2) + 7 × scroll_sink.
;   cap-edge:  8 entries (cps_emit_capedge).
;   skip band: 0 entries.
; Requires cps_k_top / cps_k_bot already set.   Clobbers: AF,BC,DE,HL,IYL.
;----------------------------------------------------------------
cps_build_active_list:
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cps_sublist_base_table
        add     a, l
        ld      l, a
        jr      nc, .cbal_sl_nc
        inc     h
.cbal_sl_nc:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = ACTIVE_BASE
        xor     a
        ld      (cps_k), a
.cbal_lp:
        ld      a, (cps_k)
        ld      hl, cps_k_top
        cp      (hl)
        jr      c, .cbal_body                   ; K < K_top → body
        ld      hl, cps_k_bot
        cp      (hl)
        jr      z, .cbal_capedge                ; K == K_bot → cap-edge
        jr      nc, .cbal_body                  ; K > K_bot → body
        ld      hl, cps_k_top
        cp      (hl)
        jr      z, .cbal_capedge                ; K == K_top → cap-edge
        jr      .cbal_next                      ; skip band → 0 entries
.cbal_body:
        push    de
        call    cps_band_base                   ; HL = grid band base
        inc     hl
        inc     hl                              ; HL = band_base+2 (ld ix operand lo)
        pop     de
        ex      de, hl                          ; HL = cursor, DE = entry
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      b, 7
.cbal_dummy:
        ld      (hl), low scroll_sink
        inc     hl
        ld      (hl), high scroll_sink
        inc     hl
        djnz    .cbal_dummy
        ex      de, hl                          ; DE = cursor advanced
        jr      .cbal_next
.cbal_capedge:
        call    cps_emit_capedge                ; 8 entries, advances DE
.cbal_next:
        ld      a, (cps_k)
        inc     a
        ld      (cps_k), a
        cp      20
        jr      nz, .cbal_lp
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
cps_row_cursor:         db 0    ; Stage 2a: screen-row cursor for per-row table lookups
cps_k:                  db 0    ; Stage 2b: char-cell band cursor (0..19)
cps_k_top:              db 0    ; Stage 2b: cap_top_row >> 3
cps_k_bot:              db 0    ; Stage 2b: cap_bot_row >> 3
cps_saved_sp:           dw 0    ; (retained for compat; SP-hijack removed in 2a)

; Stage 2b: dummy active-list sink. A body band contributes 1 real
; entry (its ld ix operand) + 7 entries pointing here, keeping the
; list a fixed 112 entries (patch/shift_pipe_targets unchanged).
; Decrementing this 2-byte cell each wrap is harmless — never executed.
scroll_sink:            dw 0

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
        add     a, 32                           ; Stage 3: +32 = byte_x=29 + 3 (2-push slot: pipe at target-4..target-1)
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
;   BODY_TEMPLATE:    160 rows × 5 bytes ($31, lo+32, hi, $D5/$E5, $C5)
;                     for byte_x=29. Even rows = A (push de = $D5),
;                     odd rows = B (push hl = $E5).
;   CAP_BLOCK:         50 rows × 5 bytes: cap_top stub, 48 skip rows, cap_bot stub
;   CAP_TARGET_TABLE:  12 (gap_y) entries × (cap_top_target, cap_bot_target)
;
; Called once at boot, BEFORE init_pipes. Cost ~80k T-states, run-once.
; Clobbers AF, BC, DE, HL, IX.
;----------------------------------------------------------------
build_slot_templates:
        ; ─── Fill BODY_TEMPLATE: 160 rows × 5 bytes (A/B by parity) ──
        ld      hl, line_table
        ld      de, BODY_TEMPLATE
        ld      b, GROUND_TOP                   ; B = row counter (160)
        ; C will hold the per-row push-2 opcode: $D5 (A) or $E5 (B).
        ld      c, $D5                          ; row 0 = A → push de
.bst_body_lp:
        ld      a, $31                          ; opcode: ld sp, nn
        ld      (de), a
        inc     de
        ld      a, (hl)                         ; line_table[R].lo
        add     a, 32                           ; Stage 3: +32 = byte_x=29 + 3 (2-push slot)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)                         ; line_table[R].hi
        adc     a, 0                            ; carry from +32
        ld      (de), a
        inc     de
        inc     hl
        ld      a, c                            ; push de ($D5) or push hl ($E5)
        ld      (de), a
        inc     de
        ld      a, $C5                          ; push bc
        ld      (de), a
        inc     de
        ; Flip C between $D5 (push de) and $E5 (push hl): $D5 XOR $E5 = $30.
        ld      a, c
        xor     $30
        ld      c, a
        djnz    .bst_body_lp

        ; ─── Fill CAP_BLOCK: 50 rows × 5 bytes ───────────────────
        ; Row 0 (cap_top): $C3, 0, 0, 0, 0  (JP nn + 2 pad — handler addr patched at recycle)
        ; Rows 1..48 (skip): JR +3 + 3 zero pads → 5 bytes total
        ; Row 49 (cap_bot): $C3, 0, 0, 0, 0
        ld      hl, CAP_BLOCK
        ld      (hl), $C3                       ; cap_top stub: jp nn opcode
        inc     hl
        ld      b, 4                            ; remaining cap_top bytes (jp target lo, hi, 2 pad)
.bst_cap_top_zero:
        ld      (hl), 0
        inc     hl
        djnz    .bst_cap_top_zero
        ; 48 skip rows × 5 bytes — JR e=$03 pattern: at slot+0..+1 the JR
        ; advances PC by 2+3=5 bytes, landing on the next slot's first byte.
        ld      b, 48
.bst_cap_skip_lp:
        ld      (hl), $18                       ; opcode: JR e
        inc     hl
        ld      (hl), $03                       ; displacement: skip 3 bytes from PC+2
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0
        inc     hl
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
        add     a, 32                           ; Stage 3: +32 = byte_x=29 + 3 (2-push slot: pipe at target-4..target-1)
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
        add     a, 32                           ; Stage 3: +32 = byte_x=29 + 3 (2-push slot: pipe at target-4..target-1)
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
; write_jrskip_column — make one pipe's whole PIPE_PROGRAM column a
; no-op skip. Used for the parked prep pipe and to disarm the
; departing pipe in do_swap.
;
; Stage 2b: NOP-fills the body region (+0..67) of all 20 of the pipe's
; bands. A NOP-filled band falls through +0..67 to the +68 trailer —
; a valid no-op. Critically, NOP-filling the WHOLE band (not just a
; couple of bytes) is what makes prep_step's INCREMENTAL rebuild safe:
; as prep_step re-stamps rows over several frames, every not-yet-
; stamped byte is a NOP (falls through), so a half-built band never
; executes stale departing-pipe content (IX-walk fragments etc.).
; The +68 trailer is left intact (written once by init_pipe_program).
;
; In:  A = pipe index (0..3).
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
write_jrskip_column:
        ; HL = band base for (K=0, pipe) = SLOT_GRID_BASE + pipe*80.
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; pipe*2
        add     hl, hl                          ; pipe*4
        add     hl, hl                          ; pipe*8
        add     hl, hl                          ; pipe*16
        ld      d, h
        ld      e, l                            ; DE = pipe*16
        add     hl, hl                          ; pipe*32
        add     hl, hl                          ; pipe*64
        add     hl, de                          ; pipe*80
        ld      de, SLOT_GRID_BASE
        add     hl, de                          ; HL = band base (K=0, pipe)
        ld      b, 20                           ; 20 bands
.wjc_band:
        push    bc
        push    hl                              ; save band base
        ; NOP-fill +0..67 (68 bytes) of this band
        ld      (hl), 0
        ld      d, h
        ld      e, l
        inc     de                              ; DE = band base + 1
        ld      bc, BAND_TRAILER_OFFSET - 1     ; 67 → fills +0..67
        ldir
        pop     hl                              ; HL = band base
        ld      de, 4 * BAND_STRIDE             ; +320 → next K, same pipe
        add     hl, de                          ; HL = next band base
        pop     bc
        djnz    .wjc_band
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

        ; Refactor: pipe 3 is the "prep" pipe. Its column is held as a
        ; JR-skip column (cheap no-op) until the first do_swap activates it.
        ; pipe_state[3].byte_x = 29 — parked off-screen right, invisible.
        ; pipe_state[3].gap_y is left at its data default (a valid 8..96
        ; value); do_swap reads it when pipe 3 first activates.
        ld      a, 29
        ld      (pipe_state + 3*2), a        ; pipe 3 byte_x = 29
        ld      a, 3
        call    write_jrskip_column          ; pipe 3 column = JR-skip

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

        ; Refactor: prep state machine is IDLE at startup. No build is in
        ; progress (activate_pipe_idx == 255, its db default) — prep_step
        ; returns immediately. prep_phase = 7 means "done / idle"; the first
        ; do_swap will arm the build and reset prep_phase/prep_row itself.
        ld      a, 7
        ld      (prep_phase), a
        xor     a
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
; ps_slot_addr_for_row — compute slot[row][activate_pipe_idx] address.
; In:  A = row (0..159)
; Out: HL = slot[row][activate_pipe_idx] (band-interleaved, via table)
;      A preserved (= row, as callers rely on).  BC preserved.
; Clobbers: DE, HL.
;----------------------------------------------------------------
ps_slot_addr_for_row:
        push    bc                              ; preserve caller's BC
        push    af                              ; preserve row in A
        ld      bc, activate_pipe_idx
        ld      a, (bc)
        ld      c, a                            ; C = activate_pipe_idx (pipe)
        pop     af                              ; A = row
        push    af                              ; keep row for the restore
        call    slot_addr_lookup                ; HL = slot[row][pipe]; clobbers A,C,DE
        pop     af                              ; A = row (restored)
        pop     bc                              ; BC restored
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
        ; Guard: 255 sentinel means no column build in progress — return cheaply.
        ld      a, (activate_pipe_idx)
        inc     a                               ; 255 -> 0 sets Z
        ret     z
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

; ─── Phase 0: body rows [0 .. 8*K_top - 1], 10 rows/call ────────────────────
; Target = line_table[row]+34 (= byte_x=29 buffer col, invisible writes).
; After swap, active pipe's body slots already point at byte_x=29 → no
; body-target-write needed in do_swap.
;
; Stage 4 cleanup: stamp ONLY the pure-body bands above K_top (bands 0..K_top-1
; = 8*K_top rows). The 7 cap-edge body rows in K_top (band-rows 0..6) are
; emitted later by ps_phase6's cps_emit_body_bands → emit_capedge_band — no
; need to stamp them here just to be overwritten.
;
; Since gap_y is always a multiple of 8, cap_top_row = gap_y - 1 = 8*K_top + 7,
; so 8*K_top = gap_y - 8. When gap_y = 8 the count is 0 and we advance.
ps_phase0:
        ; 8 * K_top = prep_gap_y - 8
        ld      a, (prep_gap_y)
        sub     8                               ; A = 8 * K_top (count)
        ld      b, a                            ; B = total rows to stamp
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
        ld      a, c                            ; actual row = prep_row (band1 starts at 0)
        ld      (ps_row_cursor), a
.p0_lp:
        ; --- dest slot = slot[ps_row_cursor][activate_pipe_idx] ---
        push    bc                              ; save B = loop counter
        ld      a, (ps_row_cursor)
        call    ps_slot_addr_for_row            ; HL = slot[row][pipe]; A = row
        ex      de, hl                          ; DE = slot addr (Stage 3: no leading EXX)
        ; --- HL = screen_target_table_29 + row*2 ---
        ld      a, (ps_row_cursor)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2
        ld      bc, screen_target_table_29
        add     hl, bc
        pop     bc                              ; restore B
        ; Write 5-byte slot: $31 lo hi {D5|E5} C5
        ld      a, $31
        ld      (de), a
        inc     de
        ld      a, (hl)
        ld      (de), a                         ; target.lo = line_table[row]+32
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a                         ; target.hi
        inc     de
        ; Row parity selects A ($D5 push de) or B ($E5 push hl) variant.
        ld      a, (ps_row_cursor)
        rrca
        ld      a, $D5                          ; default A
        jr      nc, .p0_set_push                ; even row → A
        ld      a, $E5                          ; odd row → B (push hl)
.p0_set_push:
        ld      (de), a
        inc     de
        ld      a, $C5                          ; push bc
        ld      (de), a
        ; advance the row cursor
        ld      a, (ps_row_cursor)
        inc     a
        ld      (ps_row_cursor), a
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

; ─── Phase 1: JR-skip stamp cap range [cap_top_row..cap_bot_row], 10 rows/call ─
; prep_row = 0..49 (offset within 50-row cap block).
;
; Stage 4 cleanup: stamp `$18 $03 0 0 0` per row instead of 5 NOPs. The JR
; stub costs 12T taken vs the 5-NOP fall-through at 20T (5*4); the bigger
; win is that the band can race through its 8 row-slots as 8 × 12T = 96T
; instead of NOP-sliding 68 zero bytes (~272T) before the trailer.
;
; The K_top and K_bot cap rows are stamped here too, but ps_phase6's
; cps_emit_body_bands later overwrites those bands entirely (positions +0..
; +48/+49) with the IX-walk cap-edge form, so the JR stubs at K_top's
; band_row 7 (+35) and K_bot's band_row 0 (+0) are clobbered. Only the
; 6 pure-skip bands (K_top+1..K_bot-1) keep the JR stubs into gameplay.
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
        ld      (ps_row_cursor), a
.p1_lp:
        push    bc                              ; save B = loop counter
        ld      a, (ps_row_cursor)
        call    ps_slot_addr_for_row            ; HL = slot[row][pipe]
        pop     bc                              ; restore B
        ; Stage 4 cleanup: stamp 5-byte JR-skip stub: $18 $03 0 0 0.
        ; JR e=3 from PC+2 lands on the next slot's first byte.
        ld      (hl), $18                       ; opcode: JR e
        inc     hl
        ld      (hl), $03                       ; displacement: +3 → next slot
        inc     hl
        xor     a
        ld      (hl), a                         ; pad byte 2
        inc     hl
        ld      (hl), a                         ; pad byte 3
        inc     hl
        ld      (hl), a                         ; pad byte 4
        ld      a, (ps_row_cursor)
        inc     a
        ld      (ps_row_cursor), a
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

; ─── Phase 2: body rows [cap_bot_row+8..159], 10 rows/call ───────────────────
; prep_row = 0..M-1 where M = 104 - prep_gap_y
; Target = line_table[actual_row]+34 (= byte_x=29 buffer col, invisible).
;
; Stage 4 cleanup: skip K_bot's 7 cap-edge body rows (band-rows 1..7) — they
; are emitted by ps_phase6's emit_capedge_band. Start at cap_bot_row + 8
; = 8*(K_bot+1), which is the first pure-body band below the K_bot cap-edge.
; New count = 152 - cap_bot_row = 104 - prep_gap_y (was 111 - prep_gap_y).
ps_phase2:
        ; total M = 104 - prep_gap_y
        ld      a, (prep_gap_y)
        ld      c, a
        ld      a, 104
        sub     c                               ; A = M (total pure-body rows below K_bot)
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
        ; actual row = cap_bot_row + 8 + prep_row = (prep_gap_y + PIPE_GAP + 8) + C
        ld      a, (prep_gap_y)
        add     a, PIPE_GAP + 8                 ; A = cap_bot_row + 8 = 8*(K_bot+1)
        add     a, c                            ; A += prep_row; A = actual_row
        ld      (ps_row_cursor), a
.p2_lp:
        push    bc                              ; save B = loop counter
        ld      a, (ps_row_cursor)
        call    ps_slot_addr_for_row            ; HL = slot[row][pipe]; A = row
        ex      de, hl                          ; DE = slot addr (Stage 3: no leading EXX)
        ; HL = screen_target_table_29 + row*2
        ld      a, (ps_row_cursor)
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2
        ld      bc, screen_target_table_29
        add     hl, bc
        pop     bc                              ; restore B
        ; Write 5-byte slot: $31 lo hi {D5|E5} C5
        ld      a, $31
        ld      (de), a
        inc     de
        ld      a, (hl)
        ld      (de), a                         ; target.lo = line_table[row]+32
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a                         ; target.hi
        inc     de
        ; Row parity selects A ($D5 push de) or B ($E5 push hl) variant.
        ld      a, (ps_row_cursor)
        rrca
        ld      a, $D5                          ; default A
        jr      nc, .p2_set_push
        ld      a, $E5                          ; odd row → B (push hl)
.p2_set_push:
        ld      (de), a
        inc     de
        ld      a, $C5                          ; push bc
        ld      (de), a
        ld      a, (ps_row_cursor)
        inc     a
        ld      (ps_row_cursor), a
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
        ; compute_next_slot reads cps_pipe — set to activate_pipe_idx (Phase 5: dynamic)
        ld      a, (activate_pipe_idx)
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
        ; ── Self-repair cap_*_target_imm_addrs tables FIRST ─────────────────
        ; Mirrors configure_pipe_slots' defensive re-stamp. An unidentified
        ; runtime corruption flips a bit in cap_top_target_imm_addrs, leaving
        ; one pipe's cap_top stuck on a bogus target (missing cap). This MUST
        ; run before the active-list build below reads cap_*_target_imm_addrs
        ; — otherwise a corrupt address gets baked into the ACTIVE_PIPE list
        ; and patch_pipe_targets decrements the wrong byte forever.
        ld      hl, cap_top_handler_pipe_0_target
        ld      (cap_top_target_imm_addrs), hl
        ld      hl, cap_top_handler_pipe_1_target
        ld      (cap_top_target_imm_addrs + 2), hl
        ld      hl, cap_top_handler_pipe_2_target
        ld      (cap_top_target_imm_addrs + 4), hl
        ld      hl, cap_top_handler_pipe_3_target
        ld      (cap_top_target_imm_addrs + 6), hl
        ld      hl, cap_bot_handler_pipe_0_target
        ld      (cap_bot_target_imm_addrs), hl
        ld      hl, cap_bot_handler_pipe_1_target
        ld      (cap_bot_target_imm_addrs + 2), hl
        ld      hl, cap_bot_handler_pipe_2_target
        ld      (cap_bot_target_imm_addrs + 4), hl
        ld      hl, cap_bot_handler_pipe_3_target
        ld      (cap_bot_target_imm_addrs + 6), hl

        ; Compute activate_pipe_idx * 6 into (ps_p6_pipe6) — retained for
        ; any downstream use; the band-interleaved code below uses
        ; slot_addr_lookup (C = pipe) instead of pipe*6 arithmetic.
        ld      a, (activate_pipe_idx)
        ld      e, a
        add     a, a                            ; *2
        add     a, e                            ; *3
        add     a, e                            ; *4
        add     a, e                            ; *5
        add     a, e                            ; *6
        ld      (ps_p6_pipe6), a

        ; ── Convert pure-body bands to IX-walk + build the active list ──
        ; prep_step phases 0-2 stamped this column per-row (with EXX) into
        ; the freshly JR-skipped grid. Now publish the cps_* state for the
        ; band-aware builders and run the same code configure_pipe_slots
        ; uses, so the recycled pipe ends up in the SAME band form.
        ld      a, (activate_pipe_idx)
        ld      (cps_pipe), a
        ld      a, (ps_cap_top_row)
        ld      (cps_cap_top_row), a
        ld      a, (ps_cap_bot_row)
        ld      (cps_cap_bot_row), a
        call    cps_emit_body_bands             ; pure-body bands → IX-walk (sets k_top/k_bot)
        call    cps_build_active_list           ; 112-entry per-band active list

        ; ── Arm incoming cap slots in PIPE_PROGRAM (relocated from do_swap) ──
        ; Runs once at build completion: after cps_emit_body_bands has stamped
        ; the IX-walk form (including the $C3 placeholder at each cap slot)
        ; and ps_phase1's NOP-fill of the cap range is done.
        ;
        ; Stage 4 cap slot positions are computed from cps_band_base (the
        ; per-row slot_addr_lookup formula no longer addresses IX-walk cap
        ; rows):
        ;   K_top cap slot: band_base + 46 (after 7 IX-walk rows)
        ;   K_bot cap slot: band_base + 4  (after the ld ix)
        ; The $C3 opcode is already in place from cps_emit_body_bands; here we
        ; only write the handler address at slot+1..+2. cps_pipe is published
        ; (and cps_k_top/k_bot set) above by cps_emit_body_bands/build_active_list.

        ; --- cap_top slot: band_base(K_top) + 47 (handler operand lo) ---
        ld      a, (cps_k_top)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_top band base
        ld      de, 47                          ; +46 cap slot, +1 to skip $C3
        add     hl, de                          ; HL = handler-addr operand lo
        ld      a, (activate_pipe_idx)
        add     a, a                            ; inc * 2
        ld      e, a
        ld      d, 0
        push    hl                              ; save operand-lo addr
        ld      hl, cap_top_handler_addrs
        add     hl, de                          ; HL = &cap_top_handler_addrs[inc]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = handler address
        pop     hl                              ; restore operand-lo addr
        ld      (hl), e                         ; write handler.lo
        inc     hl
        ld      (hl), d                         ; write handler.hi

        ; --- cap_bot slot: band_base(K_bot) + 5 (handler operand lo) ---
        ld      a, (cps_k_bot)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_bot band base
        ld      de, 5                           ; +4 cap slot, +1 to skip $C3
        add     hl, de                          ; HL = handler-addr operand lo
        ld      a, (activate_pipe_idx)
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

        ; Write ps_cap_top_target into cap_top_handler_pipe_<inc>_target
        ld      a, (activate_pipe_idx)
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
        ld      a, (activate_pipe_idx)
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
        ld      a, (activate_pipe_idx)
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
        ld      a, (activate_pipe_idx)
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

        ld      a, 7
        ld      (prep_phase), a
        ld      a, 255                          ; build done — unfreeze the activated pipe
        ld      (activate_pipe_idx), a
        ret

ps_p6_pipe6: db 0                              ; prep_pipe_idx * 6 scratch for phase 6

; ── Scratch for prep_step ────────────────────────────────────────
ps_cap_top_row:    db 0
ps_cap_bot_row:    db 0
ps_saved_sp:       dw 0
ps_count:          db 0                ; row count saved across djnz for prep_row update
ps_row_cursor:     db 0                ; Stage 2a: screen-row cursor for per-row table lookups
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
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        or      a                               ; activate_pipe_idx == 0?
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
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        cp      1                               ; activate_pipe_idx == 1?
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
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        cp      2                               ; activate_pipe_idx == 2?
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
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        cp      3                               ; activate_pipe_idx == 3?
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
;     If prep not ready (prep_phase != 7): defer — leave byte_x=1, retry next wrap.
; Tail-call patch_pipe_targets to decrement every active body slot's screen
; target by ROW_OFFSET (= 1) so they walk to the next column.
;
; Stage 3: column clearing is done by clear_vacated_columns (also called
; here) — the per-slot trailing-zero pair has been removed.
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
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        cp      c
        jr      z, .wbx_skip                   ; skip the activating pipe — build in progress
        ; active pipe: check byte_x
        ld      a, (iy+0)
        cp      1
        jr      z, .swap_with_prep
        dec     a
        jr      .wbx_save
.swap_with_prep:
        ; Pipe reached byte_x=1. Only swap if prep is fully ready (phase 7).
        ; Otherwise DEFER: leave byte_x=1 (no save), retry next wrap.
        ; patch_pipe_targets keeps decrementing the deferred pipe's targets,
        ; so it scrolls visibly off-screen left into buffer cols 0..3 then
        ; into ROM (silent writes). Next wrap re-evaluates when prep may be
        ; ready. Avoids fallback path's half-configured-OLD-prep corruption.
        ld      a, (prep_phase)
        cp      7
        jr      nz, .wbx_skip                   ; defer — prep not ready
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
        ; Stage 3: zero the column each active pipe just vacated (replaces the
        ; per-slot trailing-zero clear). Must run BEFORE patch_pipe_targets
        ; (which only walks active sublists — independent ordering, but doing
        ; the clear first keeps the wrap path's read of pipe_state consistent).
        call    clear_vacated_columns
        ; Run patch_pipe_targets so NEXT frame's PIPE_PROGRAM renders at NEW byte_x.
        call    patch_pipe_targets
        ret

;----------------------------------------------------------------
; clear_vacated_columns: for each active (non-prep, non-activating) pipe,
; zero the screen column it just scrolled out of, all 160 rows. Replaces
; the per-slot trailing-zero pair that used to clear it every frame.
;
; Vacated col (Stage 3, 2-push slot): byte_x_NEW + 3 = byte_x_OLD + 2 (R col).
; byte_x is already decremented by wrap_byte_x at this point.
;
; Per band (8 rows): compute screen address (line_table[8K] + col), then 8
; `ld (hl), a ; inc h` writes (high byte of screen addr stride = +256 per
; pixel-row inside a char cell — same trick as the renderer's `inc ixh`).
; Between bands the high byte / low byte both change, so per-band reload.
;
; Cost (rough): ~118 T per band × 20 bands × 3 pipes ≈ 7.2 k T per wrap frame.
; Clobbers: AF, BC, DE, HL, IY.
;----------------------------------------------------------------
clear_vacated_columns:
        ld      iy, pipe_state
        ld      b, NUM_PIPES
.cvc_outer:
        push    bc
        ld      a, NUM_PIPES
        sub     b
        ld      c, a                            ; C = pipe index 0..3
        ld      a, (prep_pipe_idx)
        cp      c
        jr      z, .cvc_skip                    ; skip preparing pipe
        ld      a, (activate_pipe_idx)
        cp      c
        jr      z, .cvc_skip                    ; skip activating pipe (build in progress)
        ; vacated_col = byte_x + 3
        ld      a, (iy+0)
        add     a, 3
        cp      32                              ; off-screen (col 32+) — skip
        jr      nc, .cvc_skip
        cp      4                               ; in buffer cols 0..3 — also harmless to skip
        jr      c, .cvc_skip
        ld      (cvc_col), a
        ; Walk 20 bands × 8 rows of single-byte clears.
        ; Each band: HL = line_table[8K] + col; then 8 × (ld (hl),0 ; inc h).
        ld      a, 0                            ; A = K = band index
        ld      (cvc_k), a
.cvc_band:
        ld      a, (cvc_k)
        add     a, a                            ; K*2
        add     a, a                            ; K*4
        add     a, a                            ; K*8 = first screen row of band
        ld      l, a
        ld      h, 0
        add     hl, hl                          ; row*2 (line_table is 2 B/entry)
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = line_addr[8K]
        ld      a, (cvc_col)
        add     a, e
        ld      l, a
        ld      a, d
        adc     a, 0
        ld      h, a                            ; HL = screen byte at (8K, col)
        xor     a
        ; 8 single-byte clears, walking +256 (inc h) per pixel row in the cell.
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        inc     h
        ld      (hl), a
        ; Advance K
        ld      a, (cvc_k)
        inc     a
        ld      (cvc_k), a
        cp      20
        jr      nz, .cvc_band
.cvc_skip:
        inc     iy
        inc     iy
        pop     bc
        djnz    .cvc_outer
        ret

cvc_col:        db 0
cvc_k:          db 0

;----------------------------------------------------------------
; do_swap: called when pipe A (departing) has reached byte_x=1.
;
; Only called from wrap_byte_x's .swap_with_prep, which is guarded by
; prep_phase==7, so do_swap always performs a full swap (~14 k T total).
;   - Set pipe_state[incoming].byte_x = 29 (gap_y left untouched — already correct).
;   - Cap arming (incoming $C3 + handler addrs + target/_next imms) is NOT done
;     here: it is relocated to ps_phase6's tail so it survives prep_step's
;     post-swap column rebuild (ps_phase1 NOP-fills the cap range).
;   - Dep column becomes JR-skip via write_jrskip_column (all 160 slots, full
;     6-byte overwrite — disarms old cap $C3 opcodes, no partial-rewrite hazard).
;   - Update prep_pipe_idx = dep. Set activate_pipe_idx = inc and reset prep
;     state to phase 0 so prep_step rebuilds the incoming column.
;   - Pick the departing pipe's next gap_y (random_gap_y) and store it into
;     pipe_state[dep].gap_y; consumed when dep next activates.
;   NOTE: incoming pipe's body slot targets are NOT written here. prep_step phases 0
;   and 2 stamp body slots with target=line_addr+34 (byte_x=29 buffer col, invisible).
;   After swap the newly-active pipe's body slots already point at byte_x=29.
;   patch_pipe_targets walks the new active pipe each wrap → targets decrement and
;   pipe scrolls leftward naturally.
;
; In:  A = departing pipe index (0..3; NOT prep_pipe_idx).
; Clobbers: AF, BC, DE, HL, HL' (saved and restored).
;----------------------------------------------------------------
do_swap:
        ld      (ds_dep), a                     ; save departing pipe index

        ; ── Full swap ────────────────────────────────────────────────────
        ; do_swap is only ever called from wrap_byte_x's .swap_with_prep,
        ; which guards the call with prep_phase==7. The historical fallback
        ; path (prep not ready) is therefore unreachable and was removed.
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

        ; 1. Set incoming pipe's byte_x=29 in pipe_state.
        ;    gap_y is NOT touched here — the incoming pipe's gap_y already holds
        ;    the correct value (chosen when it departed). prep_gap_y at do_swap
        ;    entry is a stale leftover; writing it would clobber the truth.
        ld      a, (ds_inc)
        add     a, a                            ; inc*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de                          ; HL = &pipe_state[inc*2]
        ld      (hl), 29                        ; byte_x = 29

        ; 2. (REMOVED) Incoming cap-slot arming relocated to ps_phase6 tail.
        ;    Arming at swap time was overwritten by prep_step's column rebuild
        ;    (ps_phase1 NOP-fills the cap range). ps_phase6 now arms the caps at
        ;    build completion, so the $C3 JP opcodes survive into gameplay.

        ; 3. (REMOVED) Cap target/_next imm writes relocated to ps_phase6 tail.

        ; 4. (REMOVED) Body-target-write for incoming pipe eliminated.
        ;    prep_step phases 0 and 2 now stamp body slots with target=line_addr+34
        ;    (= byte_x=29 buffer col) instead of $0000. After swap the incoming
        ;    pipe's body slots already point at byte_x=29. No per-swap rewrite needed.

        ; 5. Departing column becomes a no-op skip.
        ;    Stage 2b: write_jrskip_column NOP-fills the body (+0..67) of
        ;    all 20 of dep's bands. A NOP band falls through to the +68
        ;    trailer. Filling the WHOLE band (not a couple of bytes) is
        ;    essential: it erases the departing pipe's stale content so
        ;    prep_step's later incremental rebuild never executes a
        ;    half-stamped band's leftover IX-walk / per-row fragments.
        ;    write_jrskip_column clobbers AF,BC,DE,HL — do_swap holds no
        ;    live state in those registers at this point (ds_* scratch is in
        ;    memory; HL' is untouched). Nothing to preserve.
        ld      a, (ds_dep)
        call    write_jrskip_column

        ; 7. Update prep_pipe_idx, reset prep state, trigger post-swap build.
        ld      a, (ds_dep)
        ld      (prep_pipe_idx), a              ; departing pipe is now the prep pipe

        ; The incoming (just-activated) pipe's column is currently JR-skip
        ; (it was the prep pipe). prep_step must FULLY rebuild it post-swap.
        ; Trigger that build:
        ;   activate_pipe_idx = ds_inc  → makes prep_step start building
        ;   prep_phase = 0, prep_row = 0 → restart the build state machine
        ;   prep_gap_y = incoming gap_y → prep_step builds the column to this
        ;                                 gap_y. Step 1 stored prep_gap_y (as
        ;                                 it was on entry) into
        ;                                 pipe_state[ds_inc].gap_y, so re-read
        ;                                 it from there to be unambiguous.
        ld      a, (ds_inc)
        ld      (activate_pipe_idx), a          ; the pipe prep_step now builds

        ld      a, (ds_inc)
        add     a, a                            ; inc*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de                          ; HL = &pipe_state[ds_inc].gap_y
        ld      a, (hl)
        ld      (prep_gap_y), a                 ; gap_y of the column to build

        ; Pick the DEPARTING pipe's next gap_y now (it has just become the prep
        ; pipe). Stored into pipe_state[ds_dep].gap_y; consumed ~one cycle later
        ; when ds_dep next activates. random_gap_y clobbers AF and HL only —
        ; store its A-result before anything else uses A.
        call    random_gap_y                    ; A = fresh random gap_y for departing pipe
        ld      c, a                            ; preserve gap_y across address calc
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de                          ; HL = &pipe_state[ds_dep].gap_y
        ld      (hl), c                          ; store fresh random gap_y

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
;   4. Restores HL = body_b_de (the B-row dither pair); JPs to next slot.
;
; No CALL/RET — the slot emits JP $C3 so SP is never pushed with a
; return address while pointing into screen RAM.  The next slot's ld sp,target
; will set SP correctly, so the interim SP value doesn't matter.
;
; Stage 3: 2-push slot. Pipe at target-4..target-1; no trailing-zero pair.
; HL is the B-row dither pair (bytes 2,3 of variant B); the handler clobbers
; it during the cap stamp, then reloads from (body_b_de) before returning so
; subsequent B-rows in the band still render correctly.  DE and BC survive.
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
        ld      hl, (body_b_de)                 ; restore B-row dither pair (HL invariant)
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
        ld      hl, (body_b_de)
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
        ld      hl, (body_b_de)
cap_top_handler_pipe_2_next EQU $+1
        jp      $0000

cap_top_handler_pipe_3:                         ; Phase 3
cap_top_handler_pipe_3_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, (body_b_de)
cap_top_handler_pipe_3_next EQU $+1
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
        ld      hl, (body_b_de)
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
        ld      hl, (body_b_de)
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
        ld      hl, (body_b_de)
cap_bot_handler_pipe_2_next EQU $+1
        jp      $0000

cap_bot_handler_pipe_3:                         ; Phase 3
cap_bot_handler_pipe_3_target EQU $+1
        ld      sp, $0000
cap_bot_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, (body_b_de)
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
; Stage 3 register convention (no EXX; dither by push-order in slot):
;   BC  = M1 << 8 | L         (body bytes 0,1 — shared by A and B variants)
;   DE  = R_A << 8 | M2_A     (body bytes 2,3 of variant A; pushed on A-rows)
;   HL  = R_B << 8 | M2_B     (body bytes 2,3 of variant B; pushed on B-rows)
; pipe_bitmap   layout: db L, M1, M2, R per phase.
; pipe_bitmap_b layout: db L, M1, M2, R per phase. Bytes 0,1 (L,M1) match
;   pipe_bitmap; only bytes 2,3 (M2,R) differ — verified across all 8 phases.
;----------------------------------------------------------------
redraw_pipes_v2:
        ; --- Shared bytes 0,1 → BC; variant A bytes 2,3 → DE ---
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap
        add     hl, bc
        ld      c, (hl)                 ; C = L
        inc     hl
        ld      b, (hl)                 ; B = M1   → BC = M1<<8 | L
        inc     hl
        ld      e, (hl)                 ; E = M2_A
        inc     hl
        ld      d, (hl)                 ; D = R_A  → DE = R_A<<8 | M2_A
        ld      (body_a_bc), bc         ; shared L,M1 pair (kept for diag/cap update use)
        ld      (body_a_de), de

        ; --- Variant B bytes 2,3 → (body_b_de) scratch (also into HL below) ---
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      l, a
        ld      h, 0
        push    bc                      ; preserve BC (shared L/M1) across the load
        ld      bc, pipe_bitmap_b
        add     hl, bc
        inc     hl
        inc     hl                      ; HL → pipe_bitmap_b[phase*4 + 2]
        ld      e, (hl)                 ; E = M2_B
        inc     hl
        ld      d, (hl)                 ; D = R_B
        ld      (body_b_de), de         ; cap handler restores HL from here
        pop     bc                      ; BC = shared L/M1 again
        ld      h, d
        ld      l, e                    ; HL = R_B<<8 | M2_B (B-row push pair)
        ld      de, (body_a_de)         ; restore DE = R_A<<8 | M2_A (A-row push pair clobbered above)

        ; --- Enter PIPE_PROGRAM ---
        ; No EXX, no per-row dither setup. BC/DE/HL hold the three push pairs;
        ; A-rows execute `push de + push bc`, B-rows execute `push hl + push bc`.
        ld      a, 3                    ; MAGENTA = PIPE_PROGRAM
        out     ($fe), a
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
        call    sfx_trigger_chime
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

;----------------------------------------------------------------
; Sound engine — trigger routines + descriptor walking.
;----------------------------------------------------------------

; sfx_trigger_flap: start the flap effect, unless a chime is playing
; (chime beats flap). A flap fired mid-flap restarts cleanly.
; Clobbers A, HL.
sfx_trigger_flap:
        ld      a, (sound_active)
        or      a
        jr      z, .start
        ld      a, (sound_id)
        cp      1                       ; 1 = chime currently playing?
        ret     z                       ; yes → ignore the flap
.start:
        ld      hl, sfx_flap
        xor     a                       ; id = flap
        jr      sfx_begin

; sfx_trigger_chime: start the chime, interrupting any flap.
; Clobbers A, HL.
sfx_trigger_chime:
        ld      hl, sfx_chime
        ld      a, 1                    ; id = chime
        ; fall through into sfx_begin

; sfx_begin: HL = descriptor address, A = sound id. Arms the effect.
; sound_edges_left is zeroed so sfx_tick loads segment 0 on its next call.
; Clobbers A, HL.
sfx_begin:
        ld      (sound_id), a
        ld      (sound_descptr), hl
        ld      a, 1
        ld      (sound_active), a
        xor     a
        ld      (sound_edges_left), a
        ld      (sound_edges_left+1), a
        ret

; sfx_next_segment: read the next 6-byte segment at sound_descptr into the
; live state vars and advance sound_descptr. If the mode byte is $FF the
; effect is over → clear sound_active. Clobbers A, DE, HL.
sfx_next_segment:
        ld      hl, (sound_descptr)
        ld      a, (hl)                 ; mode byte
        cp      $FF
        jr      z, .end
        ld      (sound_mode), a
        inc     hl
        ld      e, (hl) : inc hl
        ld      d, (hl) : inc hl
        ld      (sound_half), de        ; half_period
        ld      e, (hl) : inc hl
        ld      d, (hl) : inc hl
        ld      (sound_edges_left), de  ; edge_count
        ld      a, (hl) : inc hl
        ld      (sound_sweep), a        ; sweep
        ld      (sound_descptr), hl
        ret
.end:
        xor     a
        ld      (sound_active), a
        ret

; sfx_slice: run the sound engine for this frame. Loads the per-frame budget
; (classified at main_loop top) into sound_budget, then runs the engine.
; Clobbers A, BC, DE, HL.
sfx_slice:
        ld      hl, (sound_slice_budget)
        ld      (sound_budget), hl
        ; fall through into sfx_tick

; sfx_tick: generate one frame's slice of the active effect. Runs under di in
; main_loop's idle region. Plays edges until sound_budget (delay-iters) is
; exhausted. Bounded → never overruns into the next interrupt.
; Clobbers A, BC, DE, HL.
sfx_tick:
        ld      a, (sound_active)
        or      a
        ret     z
        ld      bc, (sound_budget)      ; BC = budget remaining (delay-iters)
.edge_loop:
        ; ── ensure a live segment ───────────────────────────────
        ld      hl, (sound_edges_left)
        ld      a, h
        or      l
        jr      nz, .have_segment
        push    bc
        call    sfx_next_segment
        pop     bc
        ld      a, (sound_active)
        or      a
        ret     z                       ; effect finished
.have_segment:
        ; ── budget check: cost = sound_half + EDGE_FIXED_ITERS ───
        ld      hl, (sound_half)
        ld      de, EDGE_FIXED_ITERS
        add     hl, de                  ; HL = edge cost
        ld      a, c
        sub     l
        ld      a, b
        sbc     a, h
        ret     c                       ; cost > budget → stop, keep state
        ; BC -= HL  (budget -= cost)
        ld      a, c : sub l : ld c, a
        ld      a, b : sbc a, h : ld b, a
        ; ── produce the speaker bit ─────────────────────────────
        ld      a, (sound_mode)
        or      a
        jr      nz, .noise
        ld      a, (sound_speaker)      ; tone: toggle the bit
        xor     SPK_BIT
        jr      .emit
.noise:
        ld      hl, (sound_lfsr)        ; 16-bit Galois LFSR step
        srl     h
        rr      l
        jr      nc, .no_tap
        ld      a, h
        xor     $B4
        ld      h, a
.no_tap:
        ld      (sound_lfsr), hl
        ld      a, l
        and     1                       ; output bit → A = 0 or 1
        rlca : rlca : rlca : rlca       ; shift bit 0 → bit 4 (= SPK_BIT)
.emit:
        ld      (sound_speaker), a
        or      SOUND_BORDER
        out     ($fe), a
        ; ── delay sound_half iterations ─────────────────────────
        ld      de, (sound_half)
.delay:
        dec     de
        ld      a, d
        or      e
        jr      nz, .delay
        ; ── advance: edges_left-- ; half += sweep ───────────────
        ld      hl, (sound_edges_left)
        dec     hl
        ld      (sound_edges_left), hl
        ld      a, (sound_sweep)
        or      a
        jr      z, .edge_loop
        ld      e, a                    ; sign-extend sweep into DE
        rla
        sbc     a, a
        ld      d, a                    ; D = $00 or $FF
        ld      hl, (sound_half)
        add     hl, de
        ld      (sound_half), hl
        jr      .edge_loop

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
        ; call    sfx_trigger_flap        ; TEMP (Task 6): flap muted to tune the chime in isolation
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
