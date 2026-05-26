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
SND_SLICE_NORMAL  EQU 0                  ; TEMP: zero to remove sound variance while flattening borders
SND_SLICE_WRAP    EQU 0                  ; wrap/swap frames already at ~70k — no room for sound
SND_SLICE_CONFIG  EQU 0                  ; build frames are ~67k already — no room for sound

; ─── Constant-budget padding (Joffa-style) ───────────────────────────
; Non-wrap frames pad with a deterministic busy-wait so every frame
; spends identical T-states in WHITE (do_white_work) and YELLOW→BLACK
; (.post_prep_step) regions. Without padding, the wrap-frame extras
; (wrap_byte_x ~1.5k T, apply+restore+clear ~10k T) make the colour
; OUTs land at different scanlines per frame → visibly flashing borders.
; Each busy-wait iter is `dec de ; ld a,d ; or e ; jr nz` = 26 T taken.
; Tune empirically with tools/snadump.py border R-delta variance.
WBX_PAD_ITERS     EQU 1                   ; effectively 0 — accept WHITE→CYAN wrap-vs-non-wrap variance for budget headroom

; clear_vacated_columns per-pipe pad — matches the cost of one pipe's
; 20-band clear loop so all 4 pipes contribute identical T-states whether
; eligible or skipped (~3920 T per active pipe).
CVC_PIPE_PAD_ITERS         EQU 1          ; effectively 0 — accept skip variance to free wrap-frame budget for contention
; (JRSKIP_IDLE_PAD_ITERS removed — write_jrskip_step is gone now that
; JR-skip stamping is fast enough to do all 20 bands in do_swap.)
; apply_pipe_attrs_wrap + restore_trailing_pipe_attrs edge-skip pads —
; match the paint cost (~500 T) so per-pipe edge skips (byte_x near 0
; or 28) don't shift BLACK position. Prep pipe still uses cheap skip.
APPLY_PIPE_PAD_ITERS       EQU 19         ; ~494 T
RESTORE_PIPE_PAD_ITERS     EQU 19         ; ~494 T
; render_score (4-digit ROM-font draw) costs ~1500 T per call. Pad
; non-render frames to match so score-change frames don't shift the
; BLACK PROFILE_OUT later by ~1.5 k T (visible band-height variance).
RENDER_SCORE_PAD_ITERS     EQU 1          ; effectively 0 — accept score-frame variance

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

; ─── Diagnostics ring buffer (border-profiler trace) ─────────────
; 256 entries × (color, frame_lo) = 512 bytes at $FE00..$FFFF.
; Lives in high RAM above all game data; stack at $8000 grows down,
; nowhere near. Read with tools/snadump.py border build/main.sna.
DIAG_BORDER_LOG        EQU $FE00         ; 256 entries × 2 B → $FE00..$FFFF inclusive
                                         ; After writing entry at $FFFE/$FFFF, the
                                         ; two `inc hl` push HL to $0000 → wrap.

; ─── PROFILE_OUT — border write + ring-buffer trace ──────────────
; Replaces every `ld a, color : out ($fe), a` profile marker. Writes
; (color, frame_counter_lo) to DIAG_BORDER_LOG, wraps the head pointer
; at the end of the buffer. ~50 T per call; budget into hot paths.
; The sound emitter at sfx_tick.emit does NOT use this — its `out`
; is a speaker pulse, not a profile marker.
; Entry: 4 bytes — (color, frame_lo, R, pad). Ring = 128 × 4 = 512 B.
; R is the Z80 instruction-fetch counter; deltas between consecutive
; entries' R values are a T-state proxy that lets snadump spot per-frame
; work-duration variance (= visible flashing borders) even when the
; sequence itself is clean.
PROFILE_OUT     MACRO color
        push    af
        push    hl
        ld      a, color
        out     ($fe), a
        ld      hl, (diag_border_log_ptr)
        ld      (hl), a
        inc     hl
        ld      a, (diag_frame_counter)
        ld      (hl), a
        inc     hl
        ld      a, r                    ; R = instruction-fetch counter (7-bit, wraps)
        ld      (hl), a
        inc     hl
        inc     hl                      ; pad byte (entry is 4 B for alignment)
        ld      a, h
        or      a                       ; H==0 ⇒ HL just wrapped past $FFFF
        jr      nz, $+5                 ; skip the wrap-load if H != 0
        ld      hl, DIAG_BORDER_LOG
        ld      (diag_border_log_ptr), hl
        pop     hl
        pop     af
        ENDM

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
        ld      a, (diag_frame_counter)
        inc     a
        ld      (diag_frame_counter), a
        di
        PROFILE_OUT 2                   ; RED = top blanking
        ; Wrap-frame screen/attr work (apply_pipe_attrs_wrap +
        ; restore_trailing_pipe_attrs + clear_vacated_columns) runs at the
        ; END of the wrap frame (after prep_step, in bottom blanking) — see
        ; that block below. Doing it in vblank ate too much top-blank budget,
        ; pushing the grid past row 0 and producing top-row pixel/attr
        ; misalignment on the wrap-pending frame.
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
        PROFILE_OUT 3                   ; MAGENTA = PIPE_PROGRAM
        call    frame_update
        PROFILE_OUT 7                   ; WHITE = state prep
        call    do_white_work
        PROFILE_OUT 5                   ; CYAN = update_cap_imm_v2
        call    update_cap_imm_v2
        PROFILE_OUT 6                   ; YELLOW = column build
        ; Patch-only renderer YELLOW dispatch — defers PART B to the
        ; frame AFTER the swap frame:
        ;   swap frame    : do_swap (in WHITE) sets activate_pipe_idx=inc
        ;                   AND do_swap_just_fired=1. YELLOW sees flag set
        ;                   → clears do_swap_just_fired, runs no PART B.
        ;                   Swap frame stays under budget (do_swap itself
        ;                   is only ~3k T of PART A + PART C work).
        ;   swap+1 frame  : YELLOW sees do_swap_just_fired=0 and
        ;                   activate_pipe_idx!=255 → runs do_swap_part_b
        ;                   (~15k T) and clears activate_pipe_idx to 255.
        ;                   Non-wrap frames have slack for PART B's cost.
        ld      a, (do_swap_just_fired)
        or      a
        jr      z, .yellow_check_part_b
        xor     a
        ld      (do_swap_just_fired), a
        jr      .post_prep_step
.yellow_check_part_b:
        ld      a, (activate_pipe_idx)
        cp      255
        jr      z, .post_prep_step              ; idle, no PART B
        ld      a, 1
        ld      (sound_heavy_frame), a
        call    do_swap_part_b                  ; clears activate_pipe_idx → 255
.post_prep_step:
        ; BLUE marker delimits the wrap post-prep work (apply attrs,
        ; restore trailing, clear vacated columns — together ~14 k T on
        ; wrap frames) from the YELLOW PART B work above. Without this
        ; split the YELLOW border band visually conflated the two and
        ; could reach ~21 k T on wrap+swap+1 frames; now YELLOW is
        ; bounded by do_swap_part_b cost (≤ ~10 k T).
        PROFILE_OUT 1                   ; BLUE = post_prep wrap work + sfx
        ; Wrap_pending gated: ULA contention makes always-run too costly to
        ; fit in budget. Non-wrap frames skip the ~14k T apply/restore/clear
        ; work. Borders show some flicker between wrap/non-wrap frames but
        ; the alternative is 25 Hz drops on wrap frames.
        ld      a, (wrap_pending)
        or      a
        jr      z, .no_wrap_pending
        xor     a
        ld      (wrap_pending), a
        call    apply_pipe_attrs_wrap
        call    restore_trailing_pipe_attrs
        call    clear_vacated_columns
.no_wrap_pending:
        call    sfx_slice               ; sound — single slice in the idle tail
        PROFILE_OUT 0                   ; BLACK = idle before halt
        ei
        jp      main_loop

;----------------------------------------------------------------
; do_white_work: state-prep work that used to be in frame_update's WHITE
; band. advance_phase × 2 + (wrap_byte_x — now WITHOUT clear) + restore_trailing.
;----------------------------------------------------------------
do_white_work:
        call    advance_phase
        call    advance_phase
        ; apply_pipe_attrs_wrap and restore_trailing_pipe_attrs both write
        ; to the ATTRS area for the pipe char rows. Running them here (WHITE
        ; band) races the raster — half the char-rows would see new attrs,
        ; half old, on the wrap frame's display. They are deferred to next
        ; frame's vblank (gated by wrap_pending) where the beam is in top
        ; blank and the writes are invisible until the new frame begins.
        ; Constant-budget: pad non-wrap frames to match the wrap_byte_x +
        ; patch_pipe_targets cost so the CYAN PROFILE_OUT lands at the
        ; same scanline every frame.
        ld      a, (wrap_pending)
        or      a
        ret     nz
        ld      de, WBX_PAD_ITERS
.wbx_pad:
        dec     de
        ld      a, d
        or      e
        jr      nz, .wbx_pad
        ret

;----------------------------------------------------------------
phase:      db 0
; ─── Diagnostics: border-profiler ring head + frame counter ──────
; Both consumed by tools/snadump.py (see CLAUDE.md Diagnostics
; workflow). The ring buffer itself lives at DIAG_BORDER_LOG ($FE00).
diag_frame_counter:  db 0                ; ++ each completed halt; 8-bit wrap is fine
diag_border_log_ptr: dw DIAG_BORDER_LOG  ; head pointer, advances by 2 per PROFILE_OUT
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
clear_pending: db 0                      ; set when clear_vacated_columns must run in next frame's vblank
prep_pipe_idx:   db 3                   ; pipe currently parked as the prep column (init: pipe 3)
; activate_pipe_idx — set to inc by do_swap (PART B pending signal); cleared
; back to 255 by do_swap_part_b in main_loop's YELLOW region. Also gates
; wrap_byte_x and patch_pipe_targets so the activating pipe's targets stay
; frozen between PART A and PART B.
activate_pipe_idx: db 255
; do_swap_just_fired — set to 1 by do_swap (in WHITE). main_loop's YELLOW
; region clears it WITHOUT running do_swap_part_b on the swap frame itself;
; the *next* frame's YELLOW sees do_swap_just_fired=0 + activate_pipe_idx!=255
; → runs do_swap_part_b. This defers the ~15k T PART B work to the next
; frame (which is non-wrap, has slack) so the swap frame stays under the
; 70k T-state budget.
do_swap_just_fired: db 0

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
        ; cap_bot (band-row 0): next = band_base + 10
        ; (body-aligned K_bot — body band row 1 starts at +10, not +7 like
        ;  the legacy K_bot capedge layout. cap_bot handler advances IX
        ;  with inc ixh before jumping here, so IX = row-1 on entry.)
        call    cps_band_base           ; HL = K_bot band base (uses cps_k)
        ld      de, 10
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

        ; Dummies eliminated — patch_pipe_targets walks the list to a
        ; $0000 sentinel emitted at the end by cps_build_active_list.
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
; cps_emit_body_bands: overwrite every band of pipe cps_pipe as a pure
; body band. Establishes the "every K carries body code" invariant that
; finalize_pipe_init relies on for its 3-byte cap-slot stamps.
;
; (Pre-refactor this routine dispatched on K to emit cap-edge bands at
; K_top/K_bot. Now K_top/K_bot start as body and finalize_pipe_init
; overlays the cap slot via a 3-byte $C3 stamp. K_bot uses the same
; body-aligned layout — IX target = row-0 address — so the band code
; from +10..+51 is body rows 1..7 in both states; the cap_bot handler
; advances IX with inc ixh before jumping back to band+10.)
;
; Sets cps_k_top / cps_k_bot first (still needed by finalize_pipe_init
; and downstream callers). Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
cps_emit_body_bands:
        call    cps_set_k_bounds
        xor     a
        ld      (cps_k), a
.cebb_lp:
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
        ld      d, (hl)                         ; DE = screen base (byte_x=29 row-0)
        pop     hl                              ; HL = grid band base
        call    emit_body_band
.cebb_next:
        ld      a, (cps_k)
        inc     a
        ld      (cps_k), a
        cp      20
        jr      nz, .cebb_lp
        ret

;----------------------------------------------------------------
; finalize_pipe_init: emit cap-edge bands for cps_k_top / cps_k_bot, build
; active sublist, patch cap target imms from CAP_TARGET_TABLE, arm cap
; slots in PIPE_PROGRAM, and stamp ps_cap_*_target / ps_cap_*_next into
; the cap handler imms for cps_pipe.
;
; Extracted from rebuild_step.rs_finalize so it can be called from
; init_pipes too (Phase 2 of the patch-only renderer refactor).
;
; In: cps_pipe (0..3), cps_gap_y, cps_cap_top_row, cps_cap_bot_row,
;     cps_k_top, cps_k_bot all published.
; Clobbers: AF, BC, DE, HL, IYL.
;----------------------------------------------------------------
finalize_pipe_init:
        ; Self-repair cap_*_target_imm_addrs (defensive — matches ps_phase6).
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

        ; Stamp 3-byte cap slots ($C3 lo hi at band+46..+48 for K_top, at
        ; band+4..+6 for K_bot) on top of body bands. Body band layout
        ; provides everything else — rows 0..6 for K_top, rows 1..7 for
        ; K_bot via the cap_bot handler's `inc ixh ; jp band+10` trick.
        ; The 2-byte handler operand is patched further down (cap arming
        ; step), so the band never executes $C3 jp $0000.
        ; --- K_top cap stamp at band+46..+48 ---
        ld      a, (cps_k_top)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_top band base
        ld      de, 46
        add     hl, de
        ld      (hl), $C3                       ; jp opcode
        inc     hl
        ld      (hl), 0                         ; operand lo (patched in arming)
        inc     hl
        ld      (hl), 0                         ; operand hi (patched in arming)
        ; --- K_bot cap stamp at band+4..+6 ---
        ld      a, (cps_k_bot)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_bot band base
        ld      de, 4
        add     hl, de
        ld      (hl), $C3                       ; jp opcode
        inc     hl
        ld      (hl), 0                         ; operand lo
        inc     hl
        ld      (hl), 0                         ; operand hi

        ; Build active list (cps_build_active_list uses cps_pipe/k_top/k_bot).
        ; ONLY runs from the full finalize_pipe_init entry point — the
        ; finalize_pipe_init_lite entry SKIPS this by jumping to finalize_pipe_init_post_list.
        ; The list contents are invariant per pipe — body IX-operand entries
        ; and cap-handler-target-imm entries reference fixed addresses
        ; regardless of which K is K_top/K_bot. Built once at init;
        ; rebuilding per activation wastes ~3-4 k T.
        call    cps_build_active_list
        jp      finalize_pipe_init_post_list

;----------------------------------------------------------------
; finalize_pipe_init_lite — entry point for do_swap_part_b. Same body
; as finalize_pipe_init (self-repair + cap-edge emit + cap arming +
; cap target/_next imm patching) but SKIPS cps_build_active_list.
; The active list is built once at init and never rebuilt.
;
; Saves ~3-4 k T per activation vs finalize_pipe_init.
;----------------------------------------------------------------
finalize_pipe_init_lite:
        ; Self-repair cap_*_target_imm_addrs (defensive).
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

        ; Stamp 3-byte cap slots on body bands. Same as finalize_pipe_init
        ; above — band already carries body code (init invariant +
        ; restore_capedges_to_body symmetry), we just overlay the cap
        ; slot.
        ld      a, (cps_k_top)
        ld      (cps_k), a
        call    cps_band_base
        ld      de, 46
        add     hl, de
        ld      (hl), $C3
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0

        ld      a, (cps_k_bot)
        ld      (cps_k), a
        call    cps_band_base
        ld      de, 4
        add     hl, de
        ld      (hl), $C3
        inc     hl
        ld      (hl), 0
        inc     hl
        ld      (hl), 0

finalize_pipe_init_post_list:
        ; Patch cap target imms from CAP_TARGET_TABLE.
        ld      a, (cps_gap_y)
        rrca
        rrca
        rrca                                    ; A = gap_y / 8
        and     $0F
        dec     a                               ; A = index (0..11)
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl                          ; index * 4
        ld      de, CAP_TARGET_TABLE
        add     hl, de                          ; HL → entry
        ld      a, (hl)
        ld      (ps_cap_top_target), a
        inc     hl
        ld      a, (hl)
        ld      (ps_cap_top_target + 1), a
        inc     hl
        ld      a, (hl)
        ld      (ps_cap_bot_target), a
        inc     hl
        ld      a, (hl)
        ld      (ps_cap_bot_target + 1), a

        ; Compute cap _next addresses via compute_next_slot.
        ld      a, (cps_cap_top_row)
        call    compute_next_slot               ; HL = next slot addr
        ld      a, l
        ld      (ps_cap_top_next), a
        ld      a, h
        ld      (ps_cap_top_next + 1), a
        ld      a, (cps_cap_bot_row)
        call    compute_next_slot
        ld      a, l
        ld      (ps_cap_bot_next), a
        ld      a, h
        ld      (ps_cap_bot_next + 1), a

        ; Arm cap slots in PIPE_PROGRAM (cap-handler addresses).
        ;   K_top cap slot: band_base + 46 ($C3 already stamped by emit_capedge_band)
        ;   K_bot cap slot: band_base + 4
        ; Write handler addr at +47 (K_top) and +5 (K_bot).
        ld      a, (cps_k_top)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_top band base
        ld      de, 47
        add     hl, de
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        push    hl
        ld      hl, cap_top_handler_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        pop     hl
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ld      a, (cps_k_bot)
        ld      (cps_k), a
        call    cps_band_base                   ; HL = K_bot band base
        ld      de, 5
        add     hl, de
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        push    hl
        ld      hl, cap_bot_handler_addrs
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        pop     hl
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; Write ps_cap_top_target into cap_top_handler_pipe_<inc>_target imm.
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_target_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        ld      hl, ps_cap_top_target
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_bot_target_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        ld      hl, ps_cap_bot_target
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ; Write ps_cap_top_next / ps_cap_bot_next into cap_*_next imms.
        ld      a, (cps_pipe)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, cap_top_next_imm_addrs
        add     hl, de
        ld      c, (hl)
        inc     hl
        ld      b, (hl)
        ld      hl, ps_cap_top_next
        ld      a, (hl)
        ld      (bc), a
        inc     bc
        inc     hl
        ld      a, (hl)
        ld      (bc), a

        ld      a, (cps_pipe)
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
        ex      de, hl                          ; DE = cursor advanced
        jr      .cbal_next
.cbal_capedge:
        call    cps_emit_capedge                ; 2 real entries, advances DE
.cbal_next:
        ld      a, (cps_k)
        inc     a
        ld      (cps_k), a
        cp      20
        jr      nz, .cbal_lp
        ; Emit $0000 sentinel — patch_pipe_targets walks until pop hl yields 0.
        xor     a
        ld      (de), a
        inc     de
        ld      (de), a
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
.spt_lp:
        ld      l, (ix+0)
        ld      h, (ix+1)                       ; HL = target imm addr (sentinel = $0000)
        ld      a, h
        or      l
        ret     z                               ; reached sentinel
        ld      a, (hl)
        sub     c                               ; (HL) -= C
        ld      (hl), a
        jr      nc, .spt_no_borrow
        inc     hl
        dec     (hl)                            ; borrow into hi byte
.spt_no_borrow:
        inc     ix
        inc     ix
        jr      .spt_lp

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
band_first_addr:        ds 40,  0       ; 20 entries × 2 bytes: line_table[8K] for K=0..19

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
        ; Stage 6: populate band_first_addr[20] = line_table[8K] for K=0..19.
        ; clear_vacated_columns walks this table — saves ~6 k T per wrap by
        ; eliminating the per-band line_table recompute (~150 T → ~50 T).
        ld      hl, line_table
        ld      de, band_first_addr
        ld      b, 20
.bfa_lp:
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        ; advance HL past 7 more line_table entries (= +14 bytes) to reach
        ; line_table[8(K+1)] for next iteration.
        ld      a, l
        add     a, 14
        ld      l, a
        jr      nc, .bfa_nc
        inc     h
.bfa_nc:
        djnz    .bfa_lp
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
; no-op skip. Used for the parked prep pipe (init) and to disarm the
; departing pipe in do_swap.
;
; Stamps `JR +66` (opcode $18 displacement $42) at each band's +0 byte.
; The displacement carries execution from +0 to +68, which is exactly
; the band trailer (a JP to the next band's base). The remaining bytes
; +2..+67 are left intact but never executed.
;
; Why JR-skip instead of NOP-fill:
;   - Writes 2 bytes per band instead of 68 → ~30 T per band vs ~1400 T
;     for LDIR. Cheap enough that do_swap can do the full 20 bands
;     synchronously — no amortisation needed, frees the YELLOW band
;     in main_loop from running write_jrskip_step every frame.
;   - At RUNTIME, a JR-skipped band costs 12 T (JR taken) + 10 T
;     (trailer JP) = 22 T instead of 68 NOPs × 4 T + JP = 282 T.
;     Saves ~260 T per skipped band × ~5 skipped bands × 3 pipes
;     = ~4 k T per frame of PIPE_PROGRAM render. Big.
;
; Note for prep_step: as it incrementally rebuilds a band's body, the
; bytes at +2..+67 may be partially stale. The JR at +0 still jumps to
; +68, so stale fragments are unreachable. When the rebuild stamps a
; new `ld ix, nnnn` at +0..+3 (overwriting the JR), the band is live.
; Therefore the rebuild ordering MUST stamp the body BEFORE replacing
; the +0 JR opcode — keep `ld ix` write last (matches existing emit_*).
;
; In:  A = pipe index (0..3).
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
write_jrskip_column:
        call    .jrskip_addr_for_pipe           ; HL = band base (K=0, pipe)
        ld      b, 20
        ld      de, 4 * BAND_STRIDE             ; +320 → next K, same pipe
.wjc_band:
        ld      (hl), $18                       ; JR opcode
        inc     hl
        ld      (hl), BAND_TRAILER_OFFSET - 2   ; displacement: from PC+2 (= band+2) to band+68 → 66
        dec     hl                              ; HL → band base again
        add     hl, de                          ; HL → next band base
        djnz    .wjc_band
        ret
.jrskip_addr_for_pipe:
        ; In: A = pipe index. Out: HL = SLOT_GRID_BASE + pipe*80.
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
        ret

;----------------------------------------------------------------
init_pipes:
        xor     a
        ld      (phase), a
        call    init_screen_target_table    ; precompute screen_target_table_29[160]
        call    init_pipe_program           ; emit fixed slot grid (trailers + epilogue)
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
        ; Patch-only renderer init: TWO-PASS emit so EVERY K band carries
        ; valid body code, including K positions that are gap for THIS
        ; pipe's initial gap_y. This invariant lets do_swap_part_b at
        ; activation skip the heavy cps_emit_body_bands call — it just
        ; toggles +0..+1 (un-JR non-gap, leave gap as JR-skip) and resets
        ; IX targets, while finalize_pipe_init handles K_top/K_bot.
        ;
        ;   Pass 1: cps_emit_body_bands with K_top=K_bot=21 (out-of-range)
        ;           → every K K<21 → body branch → emit_body_band stamps
        ;             all 20 bands as body.
        ;   Pass 2: real cap_top_row/cap_bot_row + finalize_pipe_init
        ;           → emit_capedge_band overwrites K_top, K_bot bands as
        ;             cap-edge; cap arming, active list, cap target imms.
        ld      (cps_pipe), a                ; A = pipe idx
        ld      a, e                         ; E = gap_y
        ld      (cps_gap_y), a
        ld      a, 168                       ; out-of-range cap rows → K=21
        ld      (cps_cap_top_row), a
        ld      (cps_cap_bot_row), a
        call    cps_emit_body_bands          ; Pass 1: all-body for every K
        ; Pass 2: real K bounds + finalize.
        ld      a, (cps_gap_y)
        dec     a
        ld      (cps_cap_top_row), a         ; gap_y - 1
        ld      a, (cps_gap_y)
        add     a, PIPE_GAP
        ld      (cps_cap_bot_row), a         ; gap_y + PIPE_GAP
        call    cps_set_k_bounds             ; sets cps_k_top/k_bot from cap_*_row
        call    finalize_pipe_init           ; K_top/K_bot capedges + cap arming + active list + cap target imms
        ; If byte_x < 29, shift this pipe's slot targets by (29 - byte_x).
        ; shift_pipe_targets walks the active sublist (Stage-6-format from
        ; cps_build_active_list) and decrements lo-bytes, shifting both IX
        ; targets and cap handler target imms.
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
        cp      3                            ; configure only pipes 0..2 (not pipe 3)
        jr      nz, .init_cps_lp

        ; Pipe 3 is the "prep" pipe at startup. Its column is held as a
        ; JR-skip column (cheap no-op) until the first do_swap activates it.
        ; pipe_state[3].byte_x = 29 — parked off-screen right, invisible.
        ; pipe_state[3].gap_y is left at its data default (a valid 8..96
        ; value); do_swap reads it when pipe 3 first activates.
        ;
        ; Patch-only renderer (Phase 3): the body bytes at band+4..+51 of
        ; every band must be valid IX-walk code BEFORE the first activation,
        ; because do_swap's un_jrskip_column + reset_ix_targets_to_29 +
        ; finalize_pipe_init patch only band+0..+3 (and the K_top/K_bot
        ; bands' cap-slot regions). Emit pipe 3 as ALL-body (out-of-range
        ; K_top/K_bot via cap_row=168 → K=21) so cps_emit_body_bands picks
        ; .cebb_body for every K and never tries to emit a cap-edge band
        ; (which would land outside the column).
        ld      a, 3
        ld      (cps_pipe), a
        ld      a, 168
        ld      (cps_cap_top_row), a         ; K_top = 21 (out-of-range)
        ld      (cps_cap_bot_row), a         ; K_bot = 21 (out-of-range)
        call    cps_emit_body_bands          ; emit body code for all 20 bands

        ld      a, 29
        ld      (pipe_state + 3*2), a        ; pipe 3 byte_x = 29
        ld      a, 3
        call    write_jrskip_column          ; pipe 3 column = JR-skip (body bytes preserved)

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

        call    update_cap_imm_v2       ; init cap imms for phase 0 (first render)
        call    redraw_pipes_v2
        ret

; ── Scratch ──────────────────────────────────────────────────────
; ps_cap_top_target / ps_cap_bot_target hold the per-activation cap
; screen-target addresses read from CAP_TARGET_TABLE; ps_cap_top_next /
; ps_cap_bot_next hold the post-cap `jp` addresses computed via
; compute_next_slot. finalize_pipe_init stamps both into the cap
; handler imms.
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
        PROFILE_OUT 1                   ; BLUE = ground/score region
        call    update_score
        PROFILE_OUT 4                   ; GREEN = ground
        call    draw_ground
        ; State prep (advance_phase × 2 with wrap-byte_x, restore_trailing)
        ; was here in the WHITE band. Moved to main_loop's CYAN region.
.no_regen:
        ; Constant-budget: pad non-render frames so BLUE→GREEN gap doesn't
        ; jump 1.5 k T on score-change frames (which otherwise causes a
        ; visible flash in the BLACK band position).
        ld      hl, (score)
        ld      de, (score_last)
        or      a
        sbc     hl, de
        jr      nz, .do_render
        ld      de, RENDER_SCORE_PAD_ITERS
.rsp_lp:
        dec     de
        ld      a, d
        or      e
        jr      nz, .rsp_lp
        ret
.do_render:
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
        ; Defer apply_pipe_attrs_wrap to next frame's vblank — running it
        ; here (WHITE band, T~30k) races the raster and leaves the pipe's
        ; attr block half-old / half-new on the wrap frame's display.
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
        ; SP-hijack walker. Each entry's 16-bit target lo-byte is decremented;
        ; on borrow, the hi-byte is also decremented. Iterates per pipe until
        ; a $0000 sentinel terminates the pipe's sublist.
        ;
        ; Stage 6: dummy entries (7 per body band, 6 per cap-edge) eliminated.
        ; Per pipe ~20 real entries; sentinel walk costs ~1 k T per pipe vs
        ; the old 4.6 k T (112 entries, 4-way unrolled). Saves ~10 k T per
        ; wrap frame — the dominant wrap-frame variance source.
        ld      (saved_sp_inner), sp
        ld      a, (prep_pipe_idx)              ; Phase 5: skip prep pipe, not recycled pipe

        ; Pipe 0
        or      a                               ; prep_pipe_idx == 0?
        jr      z, .pt_done_p0
        ld      a, (activate_pipe_idx)          ; freeze activating pipe (255 when idle)
        or      a                               ; activate_pipe_idx == 0?
        jr      z, .pt_done_p0
        ld      sp, ACTIVE_PIPE_0
.pt_lp_p0:
        pop     hl
        ld      a, h
        or      l
        jr      z, .pt_done_p0
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_lp_p0
        inc     hl
        dec     (hl)
        jr      .pt_lp_p0
.pt_done_p0:

        ; Pipe 1
        ld      a, (prep_pipe_idx)
        cp      1
        jr      z, .pt_done_p1
        ld      a, (activate_pipe_idx)
        cp      1
        jr      z, .pt_done_p1
        ld      sp, ACTIVE_PIPE_1
.pt_lp_p1:
        pop     hl
        ld      a, h
        or      l
        jr      z, .pt_done_p1
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_lp_p1
        inc     hl
        dec     (hl)
        jr      .pt_lp_p1
.pt_done_p1:

        ; Pipe 2
        ld      a, (prep_pipe_idx)
        cp      2
        jr      z, .pt_done_p2
        ld      a, (activate_pipe_idx)
        cp      2
        jr      z, .pt_done_p2
        ld      sp, ACTIVE_PIPE_2
.pt_lp_p2:
        pop     hl
        ld      a, h
        or      l
        jr      z, .pt_done_p2
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_lp_p2
        inc     hl
        dec     (hl)
        jr      .pt_lp_p2
.pt_done_p2:

        ; Pipe 3
        ld      a, (prep_pipe_idx)
        cp      3
        jr      z, .pt_done_p3
        ld      a, (activate_pipe_idx)
        cp      3
        jr      z, .pt_done_p3
        ld      sp, ACTIVE_PIPE_3
.pt_lp_p3:
        pop     hl
        ld      a, h
        or      l
        jr      z, .pt_done_p3
        ld      a, (hl)
        sub     1
        ld      (hl), a
        jr      nc, .pt_lp_p3
        inc     hl
        dec     (hl)
        jr      .pt_lp_p3
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
        ; Pipe reached byte_x=1. Phase 3 patch-only renderer: do_swap is
        ; synchronous and always ready — no defer-until-prep-ready guard.
        push    bc
        push    iy
        ld      a, c                            ; A = departing pipe index
        call    do_swap                         ; PART A + C in WHITE; PART B in YELLOW same frame
        pop     iy
        pop     bc
        jr      .wbx_skip                       ; do_swap wrote pipe_state directly; skip (iy+0) write
.wbx_save:
        ld      (iy+0), a
.wbx_skip:
        inc     iy
        inc     iy
        djnz    .outer
        ; Vacated-column clear is deferred to this frame's bottom blanking
        ; (after prep_step), gated by wrap_pending. Running it here (WHITE
        ; band, mid-beam) used to erase the OLD pipe's R col on rows the
        ; beam hadn't reached yet → right-edge flicker every wrap.
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
;----------------------------------------------------------------
; clear_old_cap_rows: at swap time, zero the dep pipe's OLD cap_top_row
; and OLD cap_bot_row across all visible cols (4..27). These rows had
; cap pixels written every frame while dep was active; when dep becomes
; prep and later re-activates with a different gap_y, those rows
; become BODY or SKIP rows in the new K layout and may never be
; overwritten — leaving 1-byte cap-pattern specks on screen.
;
; In: ds_old_gap_y (memory) — dep's OLD gap_y captured by do_swap.
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
clear_old_cap_rows:
        ld      a, (ds_old_gap_y)
        dec     a                               ; cap_top_row = old_gap_y - 1
        call    .clear_pixel_row
        ld      a, (ds_old_gap_y)
        add     a, PIPE_GAP                     ; cap_bot_row = old_gap_y + PIPE_GAP
        call    .clear_pixel_row
        ret
.clear_pixel_row:
        ; In: A = screen pixel row (0..159). Clears cols 4..27 (24 bytes) of that row.
        add     a, a                            ; row*2
        ld      l, a
        ld      h, 0
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = line_table[row]
        ld      h, d
        ld      a, e
        add     a, 4                            ; first visible col
        ld      l, a
        xor     a
        ld      b, 24                           ; 24 visible cols
.cpr_lp:
        ld      (hl), a
        inc     hl
        djnz    .cpr_lp
        ret

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
        jp      z, .cvc_skip                    ; prep pipe ALWAYS skipped — cheap skip (no pad). jp because grew past jr range.
        ld      a, (activate_pipe_idx)
        cp      c
        jp      z, .cvc_pad_skip                ; occasionally skipped → pad to keep T constant
        ; vacated_col = byte_x + 3
        ld      a, (iy+0)
        add     a, 3
        cp      32                              ; off-screen (col 32+) — pad to keep T constant
        jp      nc, .cvc_pad_skip
        cp      4                               ; in buffer cols 0..3 — pad to keep T constant
        jp      c, .cvc_pad_skip
        ld      (cvc_col), a
        jr      .cvc_do_work
.cvc_pad_skip:
        ; Pipe not eligible for clear; busy-wait the equivalent T-states so
        ; every frame's per-pipe slot costs the same → constant BLACK position.
        ld      de, CVC_PIPE_PAD_ITERS
.cvc_pad_lp:
        dec     de
        ld      a, d
        or      e
        jr      nz, .cvc_pad_lp
        jp      .cvc_skip
.cvc_do_work:
        ; Stage 6 (v2): skip the gap region (bands K_top+1..K_bot-1) entirely.
        ; Those bands hold the pipe's central gap → all-sky pixels, so clearing
        ; them is wasted work. For typical gap_y=48, K_top=5, K_bot=12, gap = 6
        ; bands → saves ~1 k T per pipe × 3 = ~3 k T per wrap.
        push    bc                              ; save outer NUM_PIPES counter
        push    iy                              ; CRITICAL: save outer IY (= pipe_state cursor) so .cvc_skip's inc iy operates on the right register
        ; Compute K_top, K_bot from this pipe's gap_y (= iy+1 at entry, still valid).
        ld      a, (iy+1)
        dec     a
        rrca
        rrca
        rrca
        and     $1F
        ld      (cvc_k_top), a                  ; K_top = (gap_y - 1) >> 3
        ld      a, (iy+1)
        add     a, PIPE_GAP
        rrca
        rrca
        rrca
        and     $1F
        ld      (cvc_k_bot), a                  ; K_bot = (gap_y + PIPE_GAP) >> 3
        ld      iy, band_first_addr
        ; ── Top region: bands 0..K_top inclusive ─────────────────────────
        ld      a, (cvc_k_top)
        inc     a                               ; band count = K_top + 1
        ld      b, a
.cvc_top:
        ld      l, (iy+0)
        ld      h, (iy+1)
        ld      a, (cvc_col)
        add     a, l
        ld      l, a
        jr      nc, .cvc_top_nc
        inc     h
.cvc_top_nc:
        xor     a
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a
        inc     iy
        inc     iy
        djnz    .cvc_top
        ; ── Skip the gap: advance IY by (K_bot - K_top - 1) × 2 bytes ────
        ld      a, (cvc_k_bot)
        ld      hl, cvc_k_top
        sub     (hl)
        dec     a                               ; A = gap bands (e.g. K_bot=12, K_top=5 → 6)
        add     a, a                            ; × 2 bytes per band entry
        push    iy
        pop     hl
        add     a, l
        ld      l, a
        jr      nc, .cvc_gap_nc
        inc     h
.cvc_gap_nc:
        push    hl
        pop     iy
        ; ── Bottom region: bands K_bot..19 inclusive ─────────────────────
        ld      a, 20
        ld      hl, cvc_k_bot
        sub     (hl)                            ; band count = 20 - K_bot
        ld      b, a
.cvc_bot:
        ld      l, (iy+0)
        ld      h, (iy+1)
        ld      a, (cvc_col)
        add     a, l
        ld      l, a
        jr      nc, .cvc_bot_nc
        inc     h
.cvc_bot_nc:
        xor     a
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a : inc h
        ld      (hl), a
        inc     iy
        inc     iy
        djnz    .cvc_bot
        pop     iy                              ; restore outer IY (pipe_state cursor)
        pop     bc                              ; restore outer NUM_PIPES counter
.cvc_skip:
        inc     iy
        inc     iy
        pop     bc
        dec     b
        jp      nz, .cvc_outer                  ; jp because djnz out of range after gap-skip work expanded the loop body
        ret

cvc_col:        db 0
cvc_k:          db 0
cvc_k_top:      db 0
cvc_k_bot:      db 0

;----------------------------------------------------------------
; column_base_for_pipe: HL = address of band 0 for pipe A in PIPE_PROGRAM.
;   = SLOT_GRID_BASE + pipe * BAND_STRIDE.
; In: A = pipe (0..3).  Clobbers: AF, DE, HL.
;----------------------------------------------------------------
column_base_for_pipe:
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
        add     hl, de
        ret

;----------------------------------------------------------------
; un_jrskip_visible — write `ld ix, nn` opcode (DD 21) at band+0..+1
; of every NON-gap band of pipe A. Gap bands (K_top < K < K_bot) are
; left JR-skipped from the previous write_jrskip_column.
;
; Pairs with write_jrskip_column. Used by do_swap_part_b when an
; incoming pipe re-activates. Skipping gap K is essential — every
; band carries valid body code (init invariant; restore_capedges_to_body
; preserves it at deactivation), so un-JRing a gap band would render
; pipe pixels in the visual gap.
;
; In: A = pipe (0..3); cps_k_top, cps_k_bot already published.
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
un_jrskip_visible:
        call    column_base_for_pipe            ; HL = band 0 base
        ld      de, 4 * BAND_STRIDE             ; +320 → next K, same pipe
        ld      b, 0                            ; B = K counter (0..19)
.ujv_lp:
        ld      a, (cps_k_top)
        cp      b
        jr      nc, .ujv_write                  ; K_top >= K → K <= K_top → un-JR
        ld      a, (cps_k_bot)
        cp      b
        jr      c, .ujv_write                   ; K_bot < K → K > K_bot → un-JR
        jr      .ujv_next                       ; K_top < K < K_bot → gap, leave JR-skipped
.ujv_write:
        ld      (hl), $DD                       ; ld ix, nn opcode byte 1
        inc     hl
        ld      (hl), $21                       ; ld ix, nn opcode byte 2
        dec     hl
.ujv_next:
        add     hl, de
        inc     b
        ld      a, b
        cp      20
        jr      nz, .ujv_lp
        ret

;----------------------------------------------------------------
; reset_ix_targets_to_29 — set every band's IX-target operand at
; band+2..+3 to screen_target_table_29[8K] (byte_x=29's band-row-0
; address) for K=0..19. All 20 bands written; gap bands' targets are
; harmless (band is JR-skipped). The K_bot band needs the [8K+2]
; entry instead, but finalize_pipe_init's emit_capedge_band rewrites
; that band's IX target afterwards.
;
; In: A = pipe (0..3).  Clobbers: AF, BC, DE, HL, IX.
;----------------------------------------------------------------
reset_ix_targets_to_29:
        call    column_base_for_pipe            ; HL = band 0 base
        push    hl
        pop     ix                              ; IX = dest cursor (band base)
        ld      hl, screen_target_table_29      ; HL = src (byte_x=29 base for K=0)
        ld      b, 20
.rixt_K:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = screen_target_table_29[8K] (byte_x=29 row-0)
        ld      (ix+2), e
        ld      (ix+3), d
        ; HL: consumed 1 byte of K's 16-byte block, advance +15 to next K.
        ld      a, l
        add     a, 15
        ld      l, a
        jr      nc, .rixt_hl_nc
        inc     h
.rixt_hl_nc:
        ; IX: +320 to reach next band of same pipe.
        push    de
        ld      de, 4 * BAND_STRIDE
        add     ix, de
        pop     de
        djnz    .rixt_K
        ret

;----------------------------------------------------------------
; restore_capedges_to_body — at dep deactivation, overwrite the dep
; pipe's OLD K_top and K_bot cap-edge bands' cap-slot bytes with the
; corresponding body-row IX-walk bytes, so the column is in a clean
; all-body state by the time write_jrskip_column parks it.
;
; This is needed so that when this same pipe reactivates after ~20
; frames, finalize_pipe_init only needs to install the NEW K_top/K_bot
; cap-edges — not also remove stale OLD ones at different K positions.
;
;   K_top cap-edge band: cap slot at band+46..+48 ($C3 lo hi).
;     Body row 7 of a body band is a B-row: DD F9 E5 C5 DD 24.
;     Overwrite band+46..+51 with the B-row pattern.
;
;   K_bot cap-edge band: cap slot at band+4..+6 ($C3 lo hi).
;     Body row 0 of a body band is an A-row: DD F9 D5 C5 DD 24.
;     Overwrite band+4..+9 with the A-row pattern.
;
; Body bytes at band+2..+3 (IX target) and elsewhere are not touched
; — write_jrskip_column then makes the whole column unreachable, and
; reactivation's reset_ix_targets_to_29 sets fresh IX targets.
;
; In: ds_dep (the dep pipe), ds_old_gap_y (its OLD gap_y).
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
restore_capedges_to_body:
        ld      a, (ds_old_gap_y)
        dec     a
        rrca
        rrca
        rrca
        and     $1F
        ld      b, a                            ; B = OLD K_top
        ld      a, (ds_old_gap_y)
        add     a, PIPE_GAP
        rrca
        rrca
        rrca
        and     $1F
        ld      c, a                            ; C = OLD K_bot

        ld      a, (ds_dep)
        push    bc
        call    column_base_for_pipe            ; HL = column base (K=0)
        pop     bc

        ; ── K_top band: write band+46..+51 with B-row pattern ──
        push    hl
        push    bc
        ld      a, b                            ; A = K_top
        call    .rcb_add_k_bands                ; HL += K * (4 * BAND_STRIDE)
        ld      de, 46
        add     hl, de                          ; HL = K_top band + 46
        ld      (hl), $DD
        inc     hl
        ld      (hl), $F9
        inc     hl
        ld      (hl), $E5                       ; push hl  (B-row variant)
        inc     hl
        ld      (hl), $C5                       ; push bc
        inc     hl
        ld      (hl), $DD
        inc     hl
        ld      (hl), $24                       ; inc ixh
        pop     bc
        pop     hl

        ; ── K_bot band: re-emit as body via emit_body_band (52-byte write).
        ; Body layout's rows 1..7 are at +10..+51, NOT +7..+48 like cap-edge
        ; K_bot, so a 6-byte cap-slot patch would misalign every row that
        ; follows. emit_body_band rewrites +0..+51 cleanly and sets the IX
        ; target to byte_x=29's band-row-0 address (vs cap-edge's row-1).
        ld      a, c                            ; A = K_bot
        call    .rcb_add_k_bands                ; HL += K * 320 → K_bot band base
        push    hl                              ; save band base
        ld      a, c                            ; A = K_bot
        ld      l, a
        ld      h, 0
        add     hl, hl
        add     hl, hl
        add     hl, hl
        add     hl, hl                          ; K_bot * 16
        ld      de, screen_target_table_29
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                         ; DE = byte_x=29 row-0 base for K_bot
        pop     hl                              ; HL = K_bot band base
        jp      emit_body_band                  ; rewrites +0..+51 (tail-call)

.rcb_add_k_bands:
        ; HL += A * (4 * BAND_STRIDE).  A=0..19.
        or      a
        ret     z
        push    de
        ld      de, 4 * BAND_STRIDE
.rcb_akb_lp:
        add     hl, de
        dec     a
        jr      nz, .rcb_akb_lp
        pop     de
        ret

;----------------------------------------------------------------
; do_swap: called when pipe A (departing) has reached byte_x=1.
;
; Patch-only refactor (Phase 3): split across two frames to stay
; inside the wrap-frame budget.
;
; Swap frame (this call, in WHITE phase):
;   PART A — dep deactivation:
;     restore_capedges_to_body — revert OLD K_top/K_bot bands to body form.
;     write_jrskip_column      — JR-skip the whole dep column (2 B/band).
;     clear_old_cap_rows       — pixel clear OLD cap rows.
;   PART C — prep rotation:
;     prep_pipe_idx = dep, pick fresh random gap_y for dep.
;   activate_pipe_idx = inc → signal that PART B is pending.
;
; Next frame (main_loop YELLOW, via do_swap_part_b):
;   PART B — inc activation:
;     un_jrskip_column          — restore DD 21 at band+0..+1 (2 B/band).
;     reset_ix_targets_to_29    — set IX target at band+2..+3 for byte_x=29.
;     finalize_pipe_init        — emit K_top/K_bot cap-edge bands, arm caps,
;                                 build active sublist, patch cap target imms.
;   activate_pipe_idx = 255 → PART B done; back to idle.
;
; Why the split: the full do_swap costs ~12 k T (mostly finalize_pipe_init
; at ~7 k T). Wrap frames already carry ~14 k T of apply/restore/clear
; (post-prep_step), so adding 12 k T to the wrap frame overruns the 70 k T
; per-frame budget. Frame swap+1 is non-wrap (~14 k T slack), absorbs PART B
; cleanly. Inc pipe stays JR-skipped one extra frame — invisible since it
; only just entered byte_x=29 (a buffer column) anyway.
;
; In:  A = departing pipe index (0..3; NOT prep_pipe_idx).
; Clobbers: AF, BC, DE, HL.
;----------------------------------------------------------------
do_swap:
        ld      (ds_dep), a                     ; save departing pipe index

        ; Capture dep's OLD gap_y for restore_capedges_to_body + clear_old_cap_rows.
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de
        ld      a, (hl)
        ld      (ds_old_gap_y), a

        ld      a, (prep_pipe_idx)
        ld      (ds_inc), a                     ; incoming = old prep_pipe_idx

        ; Set incoming pipe's byte_x = 29 in pipe_state.
        ; gap_y left untouched — it was set at the previous deactivation.
        ld      a, (ds_inc)
        add     a, a                            ; inc*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state
        add     hl, de
        ld      (hl), 29

        ; ── PART A: dep deactivation ──────────────────────────────
        call    restore_capedges_to_body        ; uses ds_dep, ds_old_gap_y
        ld      a, (ds_dep)
        call    write_jrskip_column             ; one-shot 2-byte stamp per band
        call    clear_old_cap_rows              ; pixel clear OLD cap rows

        ; ── PART C: prep rotation ─────────────────────────────────
        ld      a, (ds_dep)
        ld      (prep_pipe_idx), a              ; departing pipe is now the prep pipe
        call    random_gap_y                    ; A = fresh random gap_y for dep
        ld      c, a
        ld      a, (ds_dep)
        add     a, a                            ; dep*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1
        add     hl, de
        ld      (hl), c                         ; pipe_state[dep].gap_y = fresh random

        ; Signal PART B pending: activate_pipe_idx = inc (gates
        ; patch_pipe_targets + wrap_byte_x), do_swap_just_fired = 1
        ; (defers PART B to NEXT frame's YELLOW — keeps swap frame
        ; under budget).
        ld      a, (ds_inc)
        ld      (activate_pipe_idx), a
        ld      a, 1
        ld      (do_swap_just_fired), a
        ret

;----------------------------------------------------------------
; do_swap_part_b — finish the swap started by do_swap on the previous
; frame: activate the inc pipe (un-JR-skip its column, reset IX targets
; to byte_x=29, install new cap-edge bands and arm cap handlers).
;
; In:  activate_pipe_idx = inc pipe (must NOT be 255).
; Clobbers: AF, BC, DE, HL, IX.
;----------------------------------------------------------------
do_swap_part_b:
        ; Publish cps_* state.
        ld      a, (activate_pipe_idx)
        ld      (cps_pipe), a
        add     a, a                            ; inc*2
        ld      l, a
        ld      h, 0
        ld      de, pipe_state + 1              ; &pipe_state[0].gap_y
        add     hl, de
        ld      a, (hl)                         ; A = inc's gap_y
        ld      (cps_gap_y), a
        dec     a
        ld      (cps_cap_top_row), a            ; gap_y - 1
        ld      a, (cps_gap_y)
        add     a, PIPE_GAP
        ld      (cps_cap_bot_row), a            ; gap_y + PIPE_GAP
        call    cps_set_k_bounds                ; sets cps_k_top, cps_k_bot

        ; Lightweight activation — relies on the "every band carries body
        ; code" invariant (init_pipes Pass 1 + restore_capedges_to_body
        ; at deactivation). PART B was 15 k T when it called
        ; cps_emit_body_bands; this trio runs in ~3-4 k T and keeps the
        ; YELLOW border band proportionally smaller.
        ld      a, (activate_pipe_idx)
        call    un_jrskip_visible               ; DD 21 at +0..+1 for non-gap K only
        ld      a, (activate_pipe_idx)
        call    reset_ix_targets_to_29          ; byte_x=29 IX target at +2..+3 (all K)
        call    finalize_pipe_init_lite         ; K_top/K_bot capedges + cap arming + cap target imms (skips active list rebuild)

        ld      a, 255
        ld      (activate_pipe_idx), a          ; PART B complete
        ret

; ── Scratch variables for do_swap ────────────────────────────────
ds_dep:     db 0                               ; departing pipe index
ds_inc:     db 0                               ; incoming pipe index
ds_old_gap_y: db 0                             ; dep's OLD gap_y, captured at do_swap entry

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
        inc     ixh                             ; advance IX from K_bot row-0 → row-1 so body band's row-1 code at +10 finds IX at row-1
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
        inc     ixh                             ; advance IX from K_bot row-0 → row-1
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
        inc     ixh                             ; advance IX from K_bot row-0 → row-1
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
        inc     ixh                             ; advance IX from K_bot row-0 → row-1
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
        PROFILE_OUT 3                   ; MAGENTA = PIPE_PROGRAM
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

        ; ─── Zero the diagnostics ring at build time ────────────
        ; sjasmplus' ZXSPECTRUM48 device leaves some pages with non-zero
        ; "random" bytes (e.g. font data near $FF59). Force the ring to
        ; zero so a fresh snapshot has a clean baseline; tools/snadump.py
        ; relies on "(0,0) = unwritten" to distinguish real entries.
        ORG     DIAG_BORDER_LOG
        DS      512, 0

        SAVESNA "build/main.sna", start
