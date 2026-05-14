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
FLAP_VY     EQU $FD80                   ; signed -640 — single flap rises ~14 px (was -1024 / 34 px, overshot 48 px pipe gap)

ATTRS           EQU $5800
BG_BUFFER       EQU $C000
BACKUP_ATTRS    EQU $D800               ; mirror of ATTRS without pipe overlay (768 B)

ATTR_SKY        EQU $28                 ; paper cyan + ink black
ATTR_CITY       EQU $38                 ; paper white + ink black (skyscraper windows)
ATTR_GROUND     EQU $20                 ; paper green + ink black (ground band, row 20)
ATTR_SCOREBOARD EQU $07                 ; paper black + ink white (rows 21..23)
ATTR_PIPE       EQU $20                 ; paper green + ink black (dynamic, inner pipe cells)
ATTR_BIRD       EQU $70                 ; bright yellow paper + black ink — bird's main char rows
ATTR_BUFFER     EQU $2D                 ; paper cyan + ink cyan — invisible buffer cols (0-3, 28-31)
GROUND_TOP      EQU 160                 ; first scan line of ground band — pipes stop here
SCORE_TOP       EQU 168                 ; first scan line of scoreboard band (= ground+8)

CITY_TOP        EQU 128                 ; first scan line of cityscape band
CITY_BOTTOM     EQU 160                 ; first scan line below cityscape

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
TARGET_TABLE           EQU $F080       ; 3 pipes × 320 B  (LEGACY)
TARGET_TABLE_END       EQU $F440
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
paint_LMMR_start_line: db 0             ; scratch — start line saved across SP-hijack

; Cached city-tile L/R byte values for the current phase. update_smc and
; update_cap_smc fill these at end-of-frame; the line loop in redraw_pipes_
; linemajor patches its body+cap L/R SMC slots from these caches as each
; pipe crosses its column's building-top row (per-pipe city transition).
;   _a slots = A variant (even rows, $FF solid-bar bg, A pipe pattern)
;   _b slots = B variant (odd rows,  $99 windows  bg, B pipe pattern)
city_aL_cache:  db 0
city_aR_cache:  db 0
city_bL_cache:  db 0
city_bR_cache:  db 0
city_cL_cache:  db 0
city_cR_cache:  db 0

; ── Joffa-style SMC-unrolled per-cell city transitions ───────────────
; SIX pre-compiled patch blocks — one per (pipe, cell) — at fixed code
; addresses (patch_block_PXY below). At wrap, patch_pipe_smc:
;   1. Computes each cell's row (CITY_BOTTOM - cityscape_heights[col]).
;   2. Bubble-sorts the (row, block_addr) pairs ASC.
;   3. SMC-patches each block's chain links (next row, next block addr)
;      and exit links, so block #0 falls through to block #1 if their rows
;      match the current B, etc. Last sorted block has next row=$FF.
;   4. Stores the FIRST sorted block's (row, addr) in dispatch_first_*_init.
;
; Per-frame, at B==CITY_TOP, the arming code copies dispatch_first_*_init
; into the line loop's SMC check (`cp <row>` and `jp <block_addr>`).
;
; Each block runs ~91 T-st of direct-SMC patches (4 slot writes from cached
; phase bytes) + ~21 T-st chain check + (one block only) ~80 T-st exit code.
; Total dispatch when all 4 visible cells fire at same row: ~504 T-st vs
; ~1500 T-st for the indirect-dispatch design. No BC clobber → no SP swap.

NUM_DISPATCH_BLOCKS   EQU 6

; (row, block_addr) tuples to sort. Each entry: 1 byte row, 2 bytes addr.
; Sentinel at index 6 keeps the sort+chain finalisation simple — the LAST
; sorted block's chain points HERE so a "miss" never reads garbage.
dispatch_sort:
        db $FF                          ; row (patched at runtime)
        dw patch_block_P1L
        db $FF
        dw patch_block_P1R
        db $FF
        dw patch_block_P2L
        db $FF
        dw patch_block_P2R
        db $FF
        dw patch_block_P3L
        db $FF
        dw patch_block_P3R
dispatch_sort_sentinel:
        db $FF                          ; row that never matches B in [0,158]
        dw dispatch_sentinel_block      ; harmless target if ever JPed to

; First sorted (row, addr) — line loop's arming reads these on each frame.
dispatch_first_row_init:    db $FF
dispatch_first_block_init:  dw dispatch_sentinel_block

; Bubble-sort early-exit flag. Set by each inner pass when a swap happens;
; if a full pass completes with zero swaps, the array is already sorted.
dispatch_sort_swapped:      db 0

pipe_state:
        ; 3 pipes distributed around the 29-step byte_x cycle (byte_x ∈ [1,29]).
        ; byte_x always uses paint_LMMR variant — buffer cols 0-3 and 28-31
        ; have attr with ink=paper so pipe parts there are invisible.
        ; Spacing ~10 cells. Initial gap_y values arbitrary (randomised on wrap).
        db 29, 64                       ; pipe just entering from right buffer
        db 19, 40
        db  9, 88

pipe_target_base:
        dw      TARGET_TABLE + 0 * 320
        dw      TARGET_TABLE + 1 * 320
        dw      TARGET_TABLE + 2 * 320

pipe_slot_base:
        dw      SLOT_ADDR_TABLE + 0 * 320
        dw      SLOT_ADDR_TABLE + 1 * 320
        dw      SLOT_ADDR_TABLE + 2 * 320

; cap_slot_table: addresses of bc-imm and de-imm slots per cap-row per pipe.
; Layout per cap-row (4 bytes): [bc_imm_lo_addr, bc_imm_hi_addr, de_imm_lo_addr, de_imm_hi_addr]
; Per pipe: 2 cap-rows × 4 bytes = 8 bytes (cap_top at +0, cap_bot at +4)
; Per 3 pipes: 24 bytes total. Zero = cap row not present.
cap_slot_table: ds 24

; Scratch words for cap_bot's BC/DE restore. Populated by redraw_pipes_v2 at frame entry.
body_a_bc:      dw 0
body_a_de:      dw 0
body_b_bc:      dw 0
body_b_de:      dw 0

; Scratch bytes for update_cap_imm's phase-shifted cap values
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
pending_regen: db 0                      ; set when a recycle happened; gen_pipe_program deferred

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

; Cityscape pattern bg bytes that appear beneath pipes in rows 128..159.
; cityscape_pattern alternates $FF (solid bar, even rows) and $99 (windows,
; odd rows). The dual-row line loop renders A variant on even rows and B
; variant on odd rows; each variant carries the matching bg so the pipe
; edges read identical to the cityscape buildings flanking them.
PIPE_CITY_BG_A  EQU $FF                 ; even-row bg = solid bar (matches $FF row)
PIPE_CITY_BG_B  EQU $99                 ; odd-row bg  = windows  (matches $99 row)

; Pre-rendered "pipe-on-cityscape" tiles. Each byte is `pipe | (mask & bg)`
; where mask is l_out_mask / r_out_mask for L / R cells and bg picks the
; appropriate row-parity cityscape pattern. M1, M2 stay as sky values
; because the 24-px pipe fully covers those cells.
;
; A variant (even body rows, A pipe pattern, $FF bg):
pipe_bitmap_city_a:
        ; phase, L_city, M1, M2, R_city (4 bytes/phase, parallel to pipe_bitmap)
        db $00 | ($FF & PIPE_CITY_BG_A), $EA, $00, $57 | ($00 & PIPE_CITY_BG_A)
        db $01 | ($FE & PIPE_CITY_BG_A), $D4, $00, $AE | ($01 & PIPE_CITY_BG_A)
        db $03 | ($FC & PIPE_CITY_BG_A), $A8, $01, $5C | ($03 & PIPE_CITY_BG_A)
        db $07 | ($F8 & PIPE_CITY_BG_A), $50, $02, $B8 | ($07 & PIPE_CITY_BG_A)
        db $0E | ($F0 & PIPE_CITY_BG_A), $A0, $05, $70 | ($0F & PIPE_CITY_BG_A)
        db $1D | ($E0 & PIPE_CITY_BG_A), $40, $0A, $E0 | ($1F & PIPE_CITY_BG_A)
        db $3A | ($C0 & PIPE_CITY_BG_A), $80, $15, $C0 | ($3F & PIPE_CITY_BG_A)
        db $75 | ($80 & PIPE_CITY_BG_A), $00, $0B, $80 | ($7F & PIPE_CITY_BG_A)

; B variant (odd body rows, B pipe pattern, $99 bg):
pipe_bitmap_city_b:
        db $00 | ($FF & PIPE_CITY_BG_B), $EA, $00, $AB | ($00 & PIPE_CITY_BG_B)
        db $01 | ($FE & PIPE_CITY_BG_B), $D4, $01, $56 | ($01 & PIPE_CITY_BG_B)
        db $03 | ($FC & PIPE_CITY_BG_B), $A8, $02, $AC | ($03 & PIPE_CITY_BG_B)
        db $07 | ($F8 & PIPE_CITY_BG_B), $50, $05, $58 | ($07 & PIPE_CITY_BG_B)
        db $0E | ($F0 & PIPE_CITY_BG_B), $A0, $0A, $B0 | ($0F & PIPE_CITY_BG_B)
        db $1D | ($E0 & PIPE_CITY_BG_B), $40, $15, $60 | ($1F & PIPE_CITY_BG_B)
        db $3A | ($C0 & PIPE_CITY_BG_B), $80, $2A, $C0 | ($3F & PIPE_CITY_BG_B)
        db $75 | ($80 & PIPE_CITY_BG_B), $00, $55, $80 | ($7F & PIPE_CITY_BG_B)

; Cap rim — single variant; cap rows are sparse so we use the A-style bg.
cap_rounded_bitmap_city:
        db $00 | ($FF & PIPE_CITY_BG_A), $7F, $FF, $FE | ($00 & PIPE_CITY_BG_A)
        db $00 | ($FE & PIPE_CITY_BG_A), $FF, $FF, $FC | ($01 & PIPE_CITY_BG_A)
        db $01 | ($FC & PIPE_CITY_BG_A), $FF, $FF, $F8 | ($03 & PIPE_CITY_BG_A)
        db $03 | ($F8 & PIPE_CITY_BG_A), $FF, $FF, $F0 | ($07 & PIPE_CITY_BG_A)
        db $07 | ($F0 & PIPE_CITY_BG_A), $FF, $FF, $E0 | ($0F & PIPE_CITY_BG_A)
        db $0F | ($E0 & PIPE_CITY_BG_A), $FF, $FF, $C0 | ($1F & PIPE_CITY_BG_A)
        db $1F | ($C0 & PIPE_CITY_BG_A), $FF, $FF, $80 | ($3F & PIPE_CITY_BG_A)
        db $3F | ($80 & PIPE_CITY_BG_A), $FF, $FF, $00 | ($7F & PIPE_CITY_BG_A)

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
; Body silhouette has inv_mask=0 (interior cleared then OR'd) so cityscape /
; pipe pixels don't bleed through — bird interior reads as paper (yellow in
; the ATTR_BIRD char row, sky cyan above/below). Beak bars and tail stripes
; use inv_mask=1 so they OR onto the background as floating black lines.

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

; Skyline silhouette — building height (in scan lines, multiples of 8) per col.
; Each value / 8 = number of 8-row skyscraper tiles. Multiples of 8 keep tiles
; aligned to char-row boundaries so the per-cell ATTR_CITY (white paper) only
; covers the building cells, not the whole row.
cityscape_heights:
        ; Cols 0-3 and 28-31 are buffer cols (invisible attr) — no city there.
        db  0,  0,  0,  0, 16, 24, 16, 32, 16, 16, 24, 16, 32, 16, 32, 24
        db 16, 24, 16, 16, 32, 16, 16, 24, 16, 32, 24, 16,  0,  0,  0,  0

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

;----------------------------------------------------------------
; init_pipe_program: emit the initial slot grid into PIPE_PROGRAM
; memory ($DB00+).  Caller must call init_slot_addr_table first
; (this routine assumes the table is already populated).
;
; Walks rows 0..159.  For each row:
;   - Reads slot[row][0] address from SLOT_ADDR_TABLE (entry index
;     row*3, 2-byte little-endian address).
;   - Writes $D9 (EXX) at (slot[row][0] - 1).
;   - Writes 3 body templates (5 B normal / 10 B city) for pipes 0-2.
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

        ; ── Dispatch on band ─────────────────────────────────────
        ld      a, b
        cp      CITY_TOP                ; 128
        jp      nc, .ipp_city_row

        ; ──────────────────────────────────────────────────────────
        ; Normal row (0..127): 3 × 5-byte body template
        ;   $31 lo hi $D5 $C5  =  ld sp,target ; push de ; push bc
        ; ──────────────────────────────────────────────────────────
        ld      c, 0                    ; pipe index
.ipp_normal_pipe_lp:
        ; Compute screen_target = line_table[B] + byte_x[C] + 3
        ; Step 1: line_addr = line_table[B]  (B preserved on stack)
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de                  ; HL → line_table[row]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr

        ; Step 2: byte_x = ipp_byte_x[C]
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

        ; Emit 5 bytes at IY
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $D5             ; push de
        ld      (iy+4), $C5             ; push bc
        ld      de, NORMAL_SLOT_STRIDE  ; = 5
        add     iy, de                  ; advance cursor to next slot

        inc     c
        ld      a, c
        cp      NUM_PIPES               ; 3
        jr      nz, .ipp_normal_pipe_lp
        jp      .ipp_row_done

        ; ──────────────────────────────────────────────────────────
        ; City row (128..159): 3 × 10-byte city body template
        ;   $31 cache_lo cache_hi $C1 $D1 $31 screen_lo screen_hi $D5 $C5
        ; ──────────────────────────────────────────────────────────
.ipp_city_row:
        ld      c, 0                    ; pipe index
.ipp_city_pipe_lp:
        ; Compute cache_addr = CITY_CACHE + (row - CITY_TOP)*12 + pipe*4
        ld      a, b
        sub     CITY_TOP                ; A = row - 128 (0..31)
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        ld      d, h
        ld      e, l                    ; DE = (row-CITY_TOP)*4
        add     hl, hl                  ; *8
        add     hl, de                  ; *12
        ld      de, CITY_CACHE
        add     hl, de                  ; HL = CITY_CACHE + (row-CITY_TOP)*12
        ld      a, c
        add     a, a
        add     a, a                    ; pipe*4
        add     a, l
        ld      l, a
        jr      nc, .ipp_cache_nc
        inc     h
.ipp_cache_nc:
        ; HL = cache_addr for (row, pipe)
        ; Emit first 5 bytes: ld sp,cache_addr ; pop bc ; pop de
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $C1             ; pop bc
        ld      (iy+4), $D1             ; pop de

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
        jr      nc, .ipp_cp_nc
        inc     h
.ipp_cp_nc:
        ld      a, (hl)                 ; A = byte_x[C]
        add     a, 3
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = screen_target

        ; Emit last 5 bytes at IY+5: ld sp,screen_target ; push de ; push bc
        ld      (iy+5), $31
        ld      (iy+6), l
        ld      (iy+7), h
        ld      (iy+8), $D5             ; push de
        ld      (iy+9), $C5             ; push bc
        ld      de, CITY_SLOT_STRIDE    ; = 10
        add     iy, de                  ; advance cursor to next slot

        inc     c
        ld      a, c
        cp      NUM_PIPES               ; 3
        jr      nz, .ipp_city_pipe_lp

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

ipp_byte_x: ds 3, 0                    ; scratch: byte_x per pipe (3 bytes)

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
; Scratch memory: cps_pipe, cps_gap_y, cps_byte_x, cps_cap_top_row,
;   cps_cap_bot_row, cps_cap_top_handler_addr, cps_cap_bot_handler_addr.
;----------------------------------------------------------------
configure_pipe_slots:
        ; ── Save args ────────────────────────────────────────────
        ld      (cps_pipe), a
        ld      a, e
        ld      (cps_gap_y), a

        ; ── Cache byte_x for this pipe ───────────────────────────
        ; pipe_state layout: db byte_x, gap_y  (2B per pipe)
        ld      a, (cps_pipe)
        add     a, a                    ; pipe*2
        ld      hl, pipe_state
        add     a, l
        ld      l, a
        jr      nc, .cps_bx_nc
        inc     h
.cps_bx_nc:
        ld      a, (hl)                 ; A = byte_x for this pipe
        ld      (cps_byte_x), a

        ; ── Pre-compute cap rows ──────────────────────────────────
        ld      a, (cps_gap_y)
        dec     a
        ld      (cps_cap_top_row), a    ; cap_top_row = gap_y - 1
        ld      a, (cps_gap_y)
        add     a, PIPE_GAP
        ld      (cps_cap_bot_row), a    ; cap_bot_row = gap_y + 48

        ; ── Load cap_top handler address ─────────────────────────
        ld      a, (cps_pipe)
        add     a, a                    ; pipe*2
        ld      hl, cap_top_handler_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_th_nc
        inc     h
.cps_th_nc:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      (cps_cap_top_handler_addr), de

        ; ── Load cap_bot handler address ─────────────────────────
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_bot_handler_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_bh_nc
        inc     h
.cps_bh_nc:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      (cps_cap_bot_handler_addr), de

        ; ── Load active sublist base ──────────────────────────────
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
        ld      d, (hl)                 ; DE = active sublist write cursor

        ; ── Main row loop: B = row 0..159 ────────────────────────
        ld      b, 0
.cps_row_lp:
        push    bc                      ; save B=row
        push    de                      ; save active-list cursor

        ; ── Look up slot address: SLOT_ADDR_TABLE[(row*3+pipe)*2] ──
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      d, h
        ld      e, l                    ; DE_tmp = row*2
        add     hl, hl                  ; row*4
        add     hl, de                  ; row*6
        ld      a, (cps_pipe)
        add     a, a                    ; pipe*2
        add     a, l
        ld      l, a
        jr      nc, .cps_tbl_nc
        inc     h
.cps_tbl_nc:
        ld      de, SLOT_ADDR_TABLE
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = slot address
        push    de
        pop     iy                      ; IY = slot base

        ; ── Determine slot type via clean comparisons ─────────────
        ; Priority: cap_top → cap_bot → skip (gap range) → body
        ld      a, (cps_cap_top_row)
        cp      b
        jp      z, .cps_do_cap_top

        ld      a, (cps_cap_bot_row)
        cp      b
        jp      z, .cps_do_cap_bot

        ; skip if gap_y <= row < cap_bot_row
        ld      a, b                    ; A = row
        ld      c, a                    ; C = row (saved for compare)
        ld      a, (cps_gap_y)
        cp      c                       ; gap_y vs row
        jp      z, .cps_do_skip         ; row == gap_y → skip
        jp      c, .cps_do_body         ; gap_y > row → body (carry: gap_y < row false)
        ; gap_y < row; skip if row < cap_bot_row
        ld      a, (cps_cap_bot_row)
        cp      c                       ; cap_bot_row vs row
        jp      c, .cps_do_body         ; cap_bot_row < row → body
        jp      .cps_do_skip            ; cap_bot_row >= row → skip (row in gap)

        ; ── cap_top template ─────────────────────────────────────
.cps_do_cap_top:
        ld      a, b
        cp      CITY_TOP
        jr      nc, .cps_ct_city
        ld      hl, (cps_cap_top_handler_addr)
        ld      (iy+0), $CD
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $00
        ld      (iy+4), $00
        jr      .cps_ct_emit_active
.cps_ct_city:
        ld      hl, (cps_cap_top_handler_addr)
        ld      (iy+0), $CD
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $00
        ld      (iy+4), $00
        ld      (iy+5), $00
        ld      (iy+6), $00
        ld      (iy+7), $00
        ld      (iy+8), $00
        ld      (iy+9), $00
.cps_ct_emit_active:
        ; Active entry = cap_top_target_imm_addrs[pipe] (2 bytes)
        pop     de                      ; restore sublist cursor
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_top_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_ct_imm_nc
        inc     h
.cps_ct_imm_nc:
        ld      a, (hl)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a
        inc     de
        push    de
        jp      .cps_row_done

        ; ── cap_bot template ─────────────────────────────────────
.cps_do_cap_bot:
        ld      a, b
        cp      CITY_TOP
        jr      nc, .cps_cb_city
        ld      hl, (cps_cap_bot_handler_addr)
        ld      (iy+0), $CD
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $00
        ld      (iy+4), $00
        jr      .cps_cb_emit_active
.cps_cb_city:
        ld      hl, (cps_cap_bot_handler_addr)
        ld      (iy+0), $CD
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $00
        ld      (iy+4), $00
        ld      (iy+5), $00
        ld      (iy+6), $00
        ld      (iy+7), $00
        ld      (iy+8), $00
        ld      (iy+9), $00
.cps_cb_emit_active:
        pop     de
        ld      a, (cps_pipe)
        add     a, a
        ld      hl, cap_bot_target_imm_addrs
        add     a, l
        ld      l, a
        jr      nc, .cps_cb_imm_nc
        inc     h
.cps_cb_imm_nc:
        ld      a, (hl)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a
        inc     de
        push    de
        jp      .cps_row_done

        ; ── skip template ────────────────────────────────────────
.cps_do_skip:
        ld      a, b
        cp      CITY_TOP
        jr      nc, .cps_skip_city
        ld      (iy+0), $00
        ld      (iy+1), $00
        ld      (iy+2), $00
        ld      (iy+3), $00
        ld      (iy+4), $00
        jr      .cps_skip_done
.cps_skip_city:
        ld      (iy+0), $00
        ld      (iy+1), $00
        ld      (iy+2), $00
        ld      (iy+3), $00
        ld      (iy+4), $00
        ld      (iy+5), $00
        ld      (iy+6), $00
        ld      (iy+7), $00
        ld      (iy+8), $00
        ld      (iy+9), $00
.cps_skip_done:
        pop     de                      ; no active list entry for skip
        push    de
        jp      .cps_row_done

        ; ── body template ────────────────────────────────────────
.cps_do_body:
        ld      a, b
        cp      CITY_TOP
        jp      nc, .cps_body_city

        ; Normal body: 31 lo hi D5 C5
        ; screen_target = line_table[row] + byte_x + 3
        ld      l, b
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      a, (cps_byte_x)
        add     a, 3
        add     a, e
        ld      l, a
        ld      h, d
        jr      nc, .cps_nb_nc
        inc     h
.cps_nb_nc:
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $D5
        ld      (iy+4), $C5
        ; Active entry: slot_addr + 1 (target imm lo byte)
        pop     de
        push    iy
        pop     hl                      ; HL = slot base
        inc     hl                      ; HL = slot_addr + 1
        ld      a, l
        ld      (de), a
        inc     de
        ld      a, h
        ld      (de), a
        inc     de
        push    de
        jp      .cps_row_done

.cps_body_city:
        ; City body: 31 cache_lo cache_hi C1 D1 31 screen_lo screen_hi D5 C5
        ; cache_addr = CITY_CACHE + (row - CITY_TOP)*12 + pipe*4
        ld      a, b
        sub     CITY_TOP                ; A = row - 128
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        ld      d, h
        ld      e, l                    ; DE = (row-CITY_TOP)*4
        add     hl, hl                  ; *8
        add     hl, de                  ; *12
        ld      de, CITY_CACHE
        add     hl, de                  ; HL = CITY_CACHE + (row-CITY_TOP)*12
        ld      a, (cps_pipe)
        add     a, a
        add     a, a                    ; pipe*4
        add     a, l
        ld      l, a
        jr      nc, .cps_cbc_nc
        inc     h
.cps_cbc_nc:
        ; HL = cache_addr
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $C1             ; pop bc
        ld      (iy+4), $D1             ; pop de
        ; screen_target = line_table[row] + byte_x + 3
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      a, (cps_byte_x)
        add     a, 3
        add     a, e
        ld      l, a
        ld      h, d
        jr      nc, .cps_cbs_nc
        inc     h
.cps_cbs_nc:
        ld      (iy+5), $31
        ld      (iy+6), l
        ld      (iy+7), h
        ld      (iy+8), $D5
        ld      (iy+9), $C5
        ; Active entry: slot_addr + 6 (screen target lo byte)
        pop     de
        push    iy
        pop     hl                      ; HL = slot base
        ld      a, l
        add     a, 6
        ld      l, a
        jr      nc, .cps_cba_nc
        inc     h
.cps_cba_nc:
        ld      a, l
        ld      (de), a
        inc     de
        ld      a, h
        ld      (de), a
        inc     de
        push    de

.cps_row_done:
        pop     de                      ; restore sublist cursor
        pop     bc                      ; restore B=row
        inc     b
        ld      a, b
        cp      GROUND_TOP              ; 160
        jp      nz, .cps_row_lp

        ; ── Patch cap_top handler target imm ─────────────────────
        ; target = line_table[cap_top_row] + byte_x + 3
        ld      a, (cps_cap_top_row)
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      a, (cps_byte_x)
        add     a, 3
        add     a, e
        ld      l, a
        ld      h, d
        jr      nc, .cps_ct_patch_nc
        inc     h
.cps_ct_patch_nc:
        ; HL = screen target; write to cap_top_target_imm_addrs[pipe]
        push    hl                      ; save target
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_top_target_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_ctw_nc
        inc     d
.cps_ctw_nc:
        ld      a, (de)
        ld      c, a
        inc     de
        ld      a, (de)
        ld      b, a                    ; BC = address of imm lo byte in handler
        pop     hl                      ; restore target
        ld      a, l
        ld      (bc), a                 ; write lo byte
        inc     bc
        ld      a, h
        ld      (bc), a                 ; write hi byte

        ; ── Patch cap_bot handler target imm ─────────────────────
        ld      a, (cps_cap_bot_row)
        ld      l, a
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      a, (cps_byte_x)
        add     a, 3
        add     a, e
        ld      l, a
        ld      h, d
        jr      nc, .cps_cb_patch_nc
        inc     h
.cps_cb_patch_nc:
        push    hl
        ld      a, (cps_pipe)
        add     a, a
        ld      de, cap_bot_target_imm_addrs
        add     a, e
        ld      e, a
        jr      nc, .cps_cbw_nc
        inc     d
.cps_cbw_nc:
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

        ; ── Store new_gap_y → pipe_state[pipe*2 + 1] ─────────────
        ld      a, (cps_pipe)
        add     a, a                    ; pipe*2
        inc     a                       ; pipe*2 + 1
        ld      hl, pipe_state
        add     a, l
        ld      l, a
        jr      nc, .cps_store_nc
        inc     h
.cps_store_nc:
        ld      a, (cps_gap_y)
        ld      (hl), a
        ret

; ── Scratch variables for configure_pipe_slots ───────────────────
cps_pipe:               db 0
cps_gap_y:              db 0
cps_byte_x:             db 0
cps_cap_top_row:        db 0
cps_cap_bot_row:        db 0
cps_cap_top_handler_addr: dw 0
cps_cap_bot_handler_addr: dw 0

; ── Per-pipe active sublist base table ───────────────────────────
cps_sublist_base_table:
        dw      ACTIVE_PIPE_0
        dw      ACTIVE_PIPE_1
        dw      ACTIVE_PIPE_2

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
        call    update_city_cache
        call    gen_pipe_program
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
        ; Deferred full regen: if a pipe recycled this frame, regenerate the
        ; flat program now (after pipe_state is fully updated by wrap_byte_x).
        ld      a, (pending_regen)
        or      a
        jr      z, .no_regen
        xor     a
        ld      (pending_regen), a
        call    gen_pipe_program
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
        jr      z, .wrap
        ; Non-wrap: busy-wait so frame_update has UNIFORM total cycle count,
        ; otherwise the WHITE end-of-frame band appears at different border
        ; rows across frames (the flashing the user is seeing).
        ; wrap_byte_x + apply_pipe_attrs cost ~3500 T-st. Match with djnz nops.
        push    bc
        ld      b, 130
.wait_lp:
        nop                             ; 4
        nop                             ; 4
        nop                             ; 4
        djnz    .wait_lp                ; 13/8 (130 × 25 ≈ 3250)
        pop     bc
        ret
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
; update_cap_smc: load pre-shifted rounded-rim bytes into all 7 cap variants.
;----------------------------------------------------------------
; update_cap_smc: only LMMR / LMMR_city slots, since byte_x ∈ [1, 29] always.
;----------------------------------------------------------------
update_cap_smc:
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, cap_rounded_bitmap
        add     hl, bc
        ld      a, (hl)                  ; byte 0 → L
        ld      (paint_cap_rounded_LMMR.smc_l + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_l + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_cL), a
        ld      (redraw_pipes_linemajor.lm_p2_cL), a
        ld      (redraw_pipes_linemajor.lm_p3_cL), a
        ld      (redraw_pipes_linemajor.lm_p1_cL_b), a
        ld      (redraw_pipes_linemajor.lm_p2_cL_b), a
        ld      (redraw_pipes_linemajor.lm_p3_cL_b), a
        inc     hl
        ld      a, (hl)                  ; byte 1 → M1
        ld      (paint_cap_rounded_LMMR.smc_m1 + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_m1 + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_cM1), a
        ld      (redraw_pipes_linemajor.lm_p2_cM1), a
        ld      (redraw_pipes_linemajor.lm_p3_cM1), a
        ld      (redraw_pipes_linemajor.lm_p1_cM1_b), a
        ld      (redraw_pipes_linemajor.lm_p2_cM1_b), a
        ld      (redraw_pipes_linemajor.lm_p3_cM1_b), a
        inc     hl
        ld      a, (hl)                  ; byte 2 → M2
        ld      (paint_cap_rounded_LMMR.smc_m2 + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_m2 + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_cM2), a
        ld      (redraw_pipes_linemajor.lm_p2_cM2), a
        ld      (redraw_pipes_linemajor.lm_p3_cM2), a
        ld      (redraw_pipes_linemajor.lm_p1_cM2_b), a
        ld      (redraw_pipes_linemajor.lm_p2_cM2_b), a
        ld      (redraw_pipes_linemajor.lm_p3_cM2_b), a
        inc     hl
        ld      a, (hl)                  ; byte 3 → R
        ld      (paint_cap_rounded_LMMR.smc_r + 1), a
        ld      (paint_cap_rounded_LMMR_city.smc_r + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_cR), a
        ld      (redraw_pipes_linemajor.lm_p2_cR), a
        ld      (redraw_pipes_linemajor.lm_p3_cR), a
        ld      (redraw_pipes_linemajor.lm_p1_cR_b), a
        ld      (redraw_pipes_linemajor.lm_p2_cR_b), a
        ld      (redraw_pipes_linemajor.lm_p3_cR_b), a

        ; Outmasks for cap city variant.
        ld      a, (phase)
        ld      c, a
        ld      b, 0
        ld      hl, l_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_cap_rounded_LMMR_city.smc_l_outmask + 1), a
        ld      hl, r_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_cap_rounded_LMMR_city.smc_r_outmask + 1), a

        ; Cache "cap-on-cityscape" L and R tile bytes for this phase.
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      c, a
        ld      b, 0
        ld      hl, cap_rounded_bitmap_city
        add     hl, bc                  ; HL → city cap L byte for this phase
        ld      a, (hl)
        ld      (city_cL_cache), a
        inc     hl
        inc     hl
        inc     hl                      ; skip M1, M2 → R byte
        ld      a, (hl)
        ld      (city_cR_cache), a
        ret

;----------------------------------------------------------------
; patch_pipe_targets: called after wrap_byte_x. For each of 3 pipes,
; walks 160 rows; for each row whose slot_addr_table entry is non-zero,
; decrements target_table[row] (since byte_x dropped by 1) and writes
; the new 16-bit target into the ld sp,nn immediate slot at slot_addr.
;
; ~11 k T-states amortized over 4 frames = 2.7 k per frame.
;----------------------------------------------------------------
patch_pipe_targets:
        ; Walk ACTIVE_LIST_NEW (built by gen_pipe_program). Uses 16-bit counter
        ; in BC since active count can exceed 255 (~339 entries for 3 pipes).
        ld      bc, (ACTIVE_COUNT_NEW)
        ld      a, b
        or      c
        ret     z
        ld      hl, ACTIVE_LIST_NEW
.lp:
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        inc     hl
        ; DE = slot addr; decrement 16-bit value at DE
        ld      a, (de)
        sub     1
        ld      (de), a
        inc     de
        ld      a, (de)
        sbc     a, 0
        ld      (de), a
        dec     bc
        ld      a, b
        or      c
        jp      nz, .lp
        ret

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
        ; Emit prologue: ld (saved_sp), sp  (4 bytes: ED 73 lo hi)
        ld      (iy+0), $ED
        ld      (iy+1), $73
        ld      (iy+2), low saved_sp
        ld      (iy+3), high saved_sp
        ld      de, 4
        add     iy, de
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
        ; Cap-top check: row B == gap_y D - 1
        ld      a, d                    ; D = gap_y
        dec     a
        cp      b
        jp      z, .emit_cap_top
        ; Cap-bot check: row B == gap_y D + PIPE_GAP
        ld      a, d
        add     a, PIPE_GAP
        cp      b
        jp      z, .emit_cap_bot
        ; Otherwise: sky-body row — check for city band first
.emit_sky_body:
        ld      a, b
        cp      CITY_TOP
        jp      nc, .emit_city_body     ; row >= 128 → city template
        ; --- Emit: ld sp, line_table[row]+byte_x+3 ; push de ; push bc ---
        ;   ld sp, nn       opcode = $31, then nn lo, nn hi (3 bytes)
        ;   push de         opcode = $D5                    (1 byte)
        ;   push bc         opcode = $C5                    (1 byte)
        ;
        ; Even row uses BC/DE (sky-A); odd row prepends exx + appends exx (sky-B).
        ld      a, b
        and     1
        jr      z, .emit_a
        ld      (iy+0), $D9             ; exx (prepend)
        inc     iy
.emit_a:
        ; Record slot addr → slot_addr_table[pipe][row] = address of "ld sp" immediate (= IY+1)
        push    iy
        pop     hl
        inc     hl                      ; HL = address of nn-lo byte of "ld sp,nn"
        push    hl                      ; save slot-immediate addr
        ld      a, c
        add     a, a                    ; pipe * 2 (16-bit entry stride)
        ld      l, a
        ld      h, 0
        ld      de, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = SLOT_ADDR_TABLE base for this pipe
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit, no overflow)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = slot-immediate addr (= original IY+1)
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Compute screen_target = line_table[row] + byte_x + 3 ---
        ld      a, b
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de                  ; HL → line_table[row]
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ; Reload byte_x for pipe C (E was clobbered earlier inside this row)
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
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit, no overflow)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = target
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Emit the actual 5 bytes at IY ---
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
        jp      z, .pipe_done
        ld      (iy+0), $D9             ; exx
        inc     iy
        jp      .pipe_done

.emit_cap_top:
        xor     a                       ; cap_idx_within_pipe = 0 (cap_top)
        jp      .do_cap
.emit_cap_bot:
        ld      a, 4                    ; cap_idx_within_pipe = 4 (cap_bot)
.do_cap:
        ld      (.cap_idx_temp), a      ; remember which cap this is for restore decision

        ; --- Emit "ld bc, 0, 0" at IY+0..IY+2 (cap L/M1 placeholder) ---
        ld      (iy+0), $01             ; ld bc, nn
        ld      (iy+1), 0
        ld      (iy+2), 0
        ; bc-imm slot address = IY+1. Record into cap_slot_table[pipe*8 + cap_idx + 0..1].
        ld      a, c                    ; pipe (0..2)
        add     a, a
        add     a, a
        add     a, a                    ; pipe * 8
        ld      l, a
        ld      h, 0
        ld      de, cap_slot_table
        add     hl, de                  ; HL → cap_slot_table[pipe*8]
        ld      a, (.cap_idx_temp)
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → cap_slot_table[pipe*8 + cap_idx]
        push    iy
        pop     de
        inc     de                      ; DE = IY+1 = bc-imm slot
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl                      ; HL → de-imm slot ptr position

        ; --- Emit "ld de, 0, 0" at IY+3..IY+5 (cap M2/R placeholder) ---
        ld      (iy+3), $11             ; ld de, nn
        ld      (iy+4), 0
        ld      (iy+5), 0
        ; de-imm slot address = IY+4. Record at HL.
        push    iy
        pop     de
        inc     de
        inc     de
        inc     de
        inc     de                      ; DE = IY+4 = de-imm slot
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Compute screen_target = line_table[row] + byte_x + 3 ---
        ld      a, b                    ; row
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      hl, pipe_state
        ld      a, c
        add     a, a
        add     a, l
        ld      l, a
        ld      a, (hl)                 ; A = byte_x
        add     a, 3                    ; +3 for stack-blast offset
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = line_addr + byte_x + 3 = target
        push    hl                      ; save target

        ; --- Save target to target_table[pipe][row] ---
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
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = target
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Emit "ld sp, target ; push de ; push bc" at IY+6..IY+10 ---
        ld      (iy+6), $31             ; ld sp, nn
        ld      (iy+7), e               ; lo
        ld      (iy+8), d               ; hi
        ld      (iy+9), $D5             ; push de
        ld      (iy+10), $C5            ; push bc

        ; --- Record slot_addr_table[pipe][row] = address of ld sp imm (= IY+7) ---
        push    iy
        pop     hl
        ld      de, 7
        add     hl, de                  ; HL = IY+7
        push    hl                      ; save slot-imm addr
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = slot_addr_table base for pipe
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = IY+7
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Advance IY past the 11 emitted bytes ---
        ld      de, 11
        add     iy, de

        ; --- ALWAYS emit BC/DE restore (8 bytes) for both cap_top and cap_bot. ---
        ; The cap emit clobbered BC and DE. Subsequent pipes' body emits on the
        ; SAME row use BC/DE (push de/push bc); without this restore they would
        ; push cap bytes instead of body bytes, producing the visible artifact
        ; where pipes after a clobbering pipe show cap pixels in their body.
        ld      (iy+0), $ED
        ld      (iy+1), $4B
        ld      (iy+2), low body_a_bc
        ld      (iy+3), high body_a_bc
        ld      (iy+4), $ED
        ld      (iy+5), $5B
        ld      (iy+6), low body_a_de
        ld      (iy+7), high body_a_de
        ld      de, 8
        add     iy, de
        jp      .pipe_done

.cap_idx_temp:  db 0

.emit_city_body:
        ; City template (10 bytes total):
        ;   ld sp, $imm_city_cache_slot   ; $31 + 2 bytes (3 bytes)
        ;   pop bc                        ; $C1           (1)
        ;   pop de                        ; $D1           (1)
        ;   ld sp, $imm_screen_target     ; $31 + 2 bytes (3)
        ;   push de                       ; $D5           (1)
        ;   push bc                       ; $C5           (1)

        ; Compute city_cache slot addr = CITY_CACHE + (row - CITY_TOP) * 12 + pipe * 4
        ld      a, b
        sub     CITY_TOP
        ; A = row offset (0..31). Multiply by 12.
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; *2
        add     hl, hl                  ; *4
        ld      d, h
        ld      e, l                    ; DE = row_offset * 4
        add     hl, hl                  ; *8
        add     hl, de                  ; *12
        ld      de, CITY_CACHE
        add     hl, de                  ; HL = CITY_CACHE + row_offset * 12
        ld      a, c                    ; A = pipe
        add     a, a
        add     a, a                    ; pipe * 4
        add     a, l
        ld      l, a
        jr      nc, .city_nc1
        inc     h
.city_nc1:
        ; HL = city_cache slot addr for (row, pipe)
        ; Emit "ld sp, HL" at IY+0..IY+2
        ld      (iy+0), $31
        ld      (iy+1), l
        ld      (iy+2), h
        ld      (iy+3), $C1             ; pop bc
        ld      (iy+4), $D1             ; pop de

        ; --- Compute screen_target = line_table[row] + byte_x + 3 ---
        ld      a, b                    ; row
        ld      l, a
        ld      h, 0
        add     hl, hl                  ; row*2
        ld      de, line_table
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = line_addr
        ld      hl, pipe_state
        ld      a, c
        add     a, a
        add     a, l
        ld      l, a
        ld      a, (hl)
        add     a, 3
        ld      l, a
        ld      h, 0
        add     hl, de                  ; HL = target
        push    hl                      ; save target

        ; --- Save target to target_table[pipe][row] ---
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
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = target
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Record slot_addr_table[pipe][row] = IY+6 (the screen-target imm) ---
        push    iy
        pop     hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl                      ; HL = IY+6
        push    hl                      ; save IY+6 addr
        ld      a, c
        add     a, a
        ld      l, a
        ld      h, 0
        ld      de, pipe_slot_base
        add     hl, de
        ld      a, (hl)
        inc     hl
        ld      h, (hl)
        ld      l, a                    ; HL = slot_addr_table base for pipe
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit)
        add     hl, de                  ; HL = base + row*2
        pop     de                      ; DE = IY+6 = screen-target imm addr
        ld      (hl), e
        inc     hl
        ld      (hl), d

        ; --- Reload target from target_table[pipe][row] and emit IY+5..IY+9 ---
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
        ex      de, hl                  ; DE = base
        ld      h, 0
        ld      l, b
        add     hl, hl                  ; HL = row*2 (16-bit)
        add     hl, de                  ; HL = base + row*2
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                 ; DE = target

        ld      (iy+5), $31
        ld      (iy+6), e
        ld      (iy+7), d
        ld      (iy+8), $D5
        ld      (iy+9), $C5
        ld      de, 10
        add     iy, de

        ; --- Emit BC/DE restore (8 bytes) after city emit. ---
        ; City emit's pop bc / pop de clobbers BC/DE. Subsequent pipes' body
        ; emits on the SAME row would push cache bytes; restore here so the
        ; main register set holds sky-A body bytes again.
        ld      (iy+0), $ED
        ld      (iy+1), $4B
        ld      (iy+2), low body_a_bc
        ld      (iy+3), high body_a_bc
        ld      (iy+4), $ED
        ld      (iy+5), $5B
        ld      (iy+6), low body_a_de
        ld      (iy+7), high body_a_de
        ld      de, 8
        add     iy, de
        jp      .pipe_done

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

        ; Emit "ld sp, (saved_sp) ; ret" — restores caller SP (which was
        ; clobbered by the last row's ld sp,target) before the RET pops the
        ; real return address. 5 bytes total.
        ld      (iy+0), $ED
        ld      (iy+1), $7B
        ld      (iy+2), low saved_sp
        ld      (iy+3), high saved_sp
        ld      (iy+4), $C9

        ; Build ACTIVE_LIST_NEW from non-zero slot_addr_table entries.
        ; This lets patch_pipe_targets walk only active rows (~120) instead of
        ; all 480 slots, cutting wrap-frame cost from ~25k to ~6k T-states.
        ; Cost runs only on gen (init + recycle), not on per-wrap patch.
        call    build_active_list_new
        ret

build_active_list_new:
        ; Walk SLOT_ADDR_TABLE (480 entries). For each non-zero entry, append
        ; its 16-bit value to ACTIVE_LIST_NEW and bump ACTIVE_COUNT_NEW (16-bit).
        xor     a
        ld      (ACTIVE_COUNT_NEW), a
        ld      (ACTIVE_COUNT_NEW + 1), a
        ld      c, NUM_PIPES
        ld      hl, SLOT_ADDR_TABLE
        ld      iy, ACTIVE_LIST_NEW
.bal_pipe:
        ld      b, 160
.bal_row:
        ld      a, (hl)
        inc     hl
        ld      e, a
        ld      a, (hl)
        inc     hl
        ld      d, a
        or      e
        jr      z, .bal_skip
        ld      (iy+0), e
        ld      (iy+1), d
        inc     iy
        inc     iy
        ; 16-bit increment of ACTIVE_COUNT_NEW
        push    hl
        ld      hl, (ACTIVE_COUNT_NEW)
        inc     hl
        ld      (ACTIVE_COUNT_NEW), hl
        pop     hl
.bal_skip:
        djnz    .bal_row
        dec     c
        jp      nz, .bal_pipe
        ret

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
        ld      a, 1
        ld      (pending_regen), a      ; defer gen_pipe_program to end of frame_update
        ld      a, 29
.save:
        ld      (iy+0), a
        inc     iy
        inc     iy
        pop     bc
        djnz    .outer
        jp      patch_pipe_targets      ; tail-call: replaces fall-through to patch_pipe_smc

patch_pipe_smc:
        ; Patch ALL variant slots — sky A, sky B, city A, city B — for each
        ; pipe's offb/offc/capt/capb/capb_plus_1. Pipe state is identical
        ; across all four physical emit blocks; we just have four copies.
        ld      a, (pipe_state + 0)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p1_offb), a
        ld      (redraw_pipes_linemajor.lm_p1_offc), a
        ld      (redraw_pipes_linemajor.lm_p1_offb_b), a
        ld      (redraw_pipes_linemajor.lm_p1_offc_b), a
        ld      a, (pipe_state + 1)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p1_capt), a
        ld      (redraw_pipes_linemajor.lm_p1_capt_b), a
        add     a, PIPE_GAP + 1
        ld      (redraw_pipes_linemajor.lm_p1_capb), a
        ld      (redraw_pipes_linemajor.lm_p1_capb_b), a
        inc     a
        ld      (redraw_pipes_linemajor.lm_p1_capb_plus_1), a
        ld      (redraw_pipes_linemajor.lm_p1_capb_plus_1_b), a

        ld      a, (pipe_state + 2)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p2_offb), a
        ld      (redraw_pipes_linemajor.lm_p2_offc), a
        ld      (redraw_pipes_linemajor.lm_p2_offb_b), a
        ld      (redraw_pipes_linemajor.lm_p2_offc_b), a
        ld      a, (pipe_state + 3)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p2_capt), a
        ld      (redraw_pipes_linemajor.lm_p2_capt_b), a
        add     a, PIPE_GAP + 1
        ld      (redraw_pipes_linemajor.lm_p2_capb), a
        ld      (redraw_pipes_linemajor.lm_p2_capb_b), a
        inc     a
        ld      (redraw_pipes_linemajor.lm_p2_capb_plus_1), a
        ld      (redraw_pipes_linemajor.lm_p2_capb_plus_1_b), a

        ld      a, (pipe_state + 4)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p3_offb), a
        ld      (redraw_pipes_linemajor.lm_p3_offc), a
        ld      (redraw_pipes_linemajor.lm_p3_offb_b), a
        ld      (redraw_pipes_linemajor.lm_p3_offc_b), a
        ld      a, (pipe_state + 5)
        dec     a
        ld      (redraw_pipes_linemajor.lm_p3_capt), a
        ld      (redraw_pipes_linemajor.lm_p3_capt_b), a
        add     a, PIPE_GAP + 1
        ld      (redraw_pipes_linemajor.lm_p3_capb), a
        ld      (redraw_pipes_linemajor.lm_p3_capb_b), a
        inc     a
        ld      (redraw_pipes_linemajor.lm_p3_capb_plus_1), a
        ld      (redraw_pipes_linemajor.lm_p3_capb_plus_1_b), a

        ; ── Per-cell SMC-block dispatch setup ─────────────────────────
        ; Compute each cell's transition row, write into dispatch_sort entry
        ; (entries are pre-laid out with their patch_block_PXY addresses, in
        ; pipe order). After computing all 6 rows, bubble-sort by row ASC,
        ; then walk the sorted list to SMC-link each block's chain row /
        ; chain block / exit row / exit block to the NEXT sorted block.
        ;
        ; Column for cell:
        ;   L cell column = byte_x - 1
        ;   R cell column = byte_x + 2

        ld      a, (pipe_state + 0)
        dec     a
        call    .compute_row
        ld      (dispatch_sort + 0 * 3), a

        ld      a, (pipe_state + 0)
        add     a, 2
        call    .compute_row
        ld      (dispatch_sort + 1 * 3), a

        ld      a, (pipe_state + 2)
        dec     a
        call    .compute_row
        ld      (dispatch_sort + 2 * 3), a

        ld      a, (pipe_state + 2)
        add     a, 2
        call    .compute_row
        ld      (dispatch_sort + 3 * 3), a

        ld      a, (pipe_state + 4)
        dec     a
        call    .compute_row
        ld      (dispatch_sort + 4 * 3), a

        ld      a, (pipe_state + 4)
        add     a, 2
        call    .compute_row
        ld      (dispatch_sort + 5 * 3), a

        ; ── Bubble-sort with early-exit. Most wraps leave row order
        ; unchanged (byte_x decreases by 1, heights at new col are often
        ; the same as old col since cityscape_heights has long runs of
        ; identical values), so the first pass typically finds the array
        ; already sorted → bail in ~75 T-st instead of ~2500.
        ld      b, 5                    ; outer pass count
.sort_outer:
        ld      c, 5                    ; inner pair count
        ld      hl, dispatch_sort
        xor     a
        ld      (dispatch_sort_swapped), a  ; clear "any-swap-this-pass" flag
.sort_inner:
        ld      e, l
        ld      d, h
        inc     de
        inc     de
        inc     de                       ; DE → entry[k+1].row
        ld      a, (de)
        cp      (hl)                     ; entry[k+1].row vs entry[k].row
        jr      nc, .sort_no_swap        ; >= → in order
        ; Out of order — swap 3 bytes (HL) ↔ (DE)
        ld      a, 1
        ld      (dispatch_sort_swapped), a
        ld      a, (hl)
        ex      af, af'
        ld      a, (de)
        ld      (hl), a
        ex      af, af'
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ex      af, af'
        ld      a, (de)
        ld      (hl), a
        ex      af, af'
        ld      (de), a
        inc     hl
        inc     de
        ld      a, (hl)
        ex      af, af'
        ld      a, (de)
        ld      (hl), a
        ex      af, af'
        ld      (de), a
        inc     hl                       ; HL → entry[k+1].row (= original position)
        jr      .sort_inner_continue
.sort_no_swap:
        inc     hl
        inc     hl
        inc     hl
.sort_inner_continue:
        dec     c
        jr      nz, .sort_inner
        ; Check early-exit flag — if no swaps this pass, array is sorted.
        ld      a, (dispatch_sort_swapped)
        or      a
        jr      z, .sort_done
        djnz    .sort_outer
.sort_done:

        ; ── Link the sorted blocks into a chain via SMC ────────────────
        ; For each sorted entry i (0..5): block_i's chain links point to
        ; entry i+1 (next sorted block / sentinel). HL walks dispatch_sort;
        ; IX is loaded with each block's base address so (ix+nn) addressing
        ; can SMC-patch the four chain/exit slots in one shot.
        ld      hl, dispatch_sort        ; HL → entry 0 row
        ld      b, NUM_DISPATCH_BLOCKS
.link_lp:
        inc     hl                       ; skip current entry's row
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        inc     hl                       ; DE = block_i addr; HL → entry i+1's row
        push    de
        pop     ix                       ; IX = block_i addr
        ld      a, (hl)                  ; A = row of entry i+1
        inc     hl
        ld      e, (hl)
        inc     hl
        ld      d, (hl)                  ; DE = addr of entry i+1's block
        dec     hl
        dec     hl                       ; HL back at entry i+1's row (= next iter's start)
        ld      (ix+patch_block_P1L.smc_chain_row - patch_block_P1L), a
        ld      (ix+patch_block_P1L.smc_chain_block - patch_block_P1L), e
        ld      (ix+patch_block_P1L.smc_chain_block - patch_block_P1L + 1), d
        ld      (ix+patch_block_P1L.smc_exit_row - patch_block_P1L), a
        ld      (ix+patch_block_P1L.smc_exit_block - patch_block_P1L), e
        ld      (ix+patch_block_P1L.smc_exit_block - patch_block_P1L + 1), d
        djnz    .link_lp

        ; First sorted (row, addr) → arming initialisers.
        ld      a, (dispatch_sort + 0)
        ld      (dispatch_first_row_init), a
        ld      hl, (dispatch_sort + 1)
        ld      (dispatch_first_block_init), hl
        ret

.compute_row:
        ; in: A = column index (0..31)
        ; out: A = transition row (CITY_BOTTOM - height, rounded up to even),
        ;      or $FF if column has no cityscape (height = 0).
        ; clobbers: HL, DE
        ld      h, 0
        ld      l, a
        ld      de, cityscape_heights
        add     hl, de
        ld      a, (hl)                 ; A = height
        or      a
        jr      nz, .compute_has_city
        ld      a, $FF
        ret
.compute_has_city:
        ld      e, a
        ld      a, CITY_TOP + 32        ; = CITY_BOTTOM = GROUND_TOP = 160
        sub     e
        inc     a                       ; round up to next even — A-iter only
        and     $FE
        ret

;----------------------------------------------------------------
; SMC-unrolled per-cell patch blocks. Each is reached by direct JP from the
; line loop's cursor check (no CALL → no SP-swap needed; no BC clobber →
; B/C survive intact). On entry, B holds the current line, smc_cursor_row
; already matched it.
;
; Layout per block (≈30 bytes):
;   1. Four direct-SMC writes: body_A, body_B, cap_A, cap_B
;      (cap_A and cap_B share the same source byte — one ld a, then two writes)
;   2. Chain check: ld a, b / cp <next_row> / jp z, <next_block> — falls
;      through to the next sorted cell if its row also matches B.
;   3. Exit path: arm smc_cursor_row and smc_first_block for the NEXT
;      dispatch call, then jp back to the line loop.
;
; patch_pipe_smc SMC-patches the chain row/block immediates on wrap so the
; blocks are linked in row-ascending order. The last sorted block's chain
; target is the sentinel block (row=$FF, jp z never fires).
;----------------------------------------------------------------

; Sentinel block — JPed at "no next" exits. Just arms the line loop's
; cursor for next frame (row=$FF) and returns to the loop.
dispatch_sentinel_block:
        ld      a, $FF
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P1L:
        ld      a, (city_aL_cache)
        ld      (redraw_pipes_linemajor.lm_p1_aL), a
        ld      a, (city_bL_cache)
        ld      (redraw_pipes_linemajor.lm_p1_aL_b), a
        ld      a, (city_cL_cache)
        ld      (redraw_pipes_linemajor.lm_p1_cL), a
        ld      (redraw_pipes_linemajor.lm_p1_cL_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P1R:
        ld      a, (city_aR_cache)
        ld      (redraw_pipes_linemajor.lm_p1_aR), a
        ld      a, (city_bR_cache)
        ld      (redraw_pipes_linemajor.lm_p1_aR_b), a
        ld      a, (city_cR_cache)
        ld      (redraw_pipes_linemajor.lm_p1_cR), a
        ld      (redraw_pipes_linemajor.lm_p1_cR_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P2L:
        ld      a, (city_aL_cache)
        ld      (redraw_pipes_linemajor.lm_p2_aL), a
        ld      a, (city_bL_cache)
        ld      (redraw_pipes_linemajor.lm_p2_aL_b), a
        ld      a, (city_cL_cache)
        ld      (redraw_pipes_linemajor.lm_p2_cL), a
        ld      (redraw_pipes_linemajor.lm_p2_cL_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P2R:
        ld      a, (city_aR_cache)
        ld      (redraw_pipes_linemajor.lm_p2_aR), a
        ld      a, (city_bR_cache)
        ld      (redraw_pipes_linemajor.lm_p2_aR_b), a
        ld      a, (city_cR_cache)
        ld      (redraw_pipes_linemajor.lm_p2_cR), a
        ld      (redraw_pipes_linemajor.lm_p2_cR_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P3L:
        ld      a, (city_aL_cache)
        ld      (redraw_pipes_linemajor.lm_p3_aL), a
        ld      a, (city_bL_cache)
        ld      (redraw_pipes_linemajor.lm_p3_aL_b), a
        ld      a, (city_cL_cache)
        ld      (redraw_pipes_linemajor.lm_p3_cL), a
        ld      (redraw_pipes_linemajor.lm_p3_cL_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

patch_block_P3R:
        ld      a, (city_aR_cache)
        ld      (redraw_pipes_linemajor.lm_p3_aR), a
        ld      a, (city_bR_cache)
        ld      (redraw_pipes_linemajor.lm_p3_aR_b), a
        ld      a, (city_cR_cache)
        ld      (redraw_pipes_linemajor.lm_p3_cR), a
        ld      (redraw_pipes_linemajor.lm_p3_cR_b), a
        ld      a, b
        cp      $FF
.smc_chain_row: equ $-1
        jp      z, dispatch_sentinel_block
.smc_chain_block: equ $-2
        ld      a, $FF
.smc_exit_row: equ $-1
        ld      (redraw_pipes_linemajor.smc_cursor_row), a
        ld      hl, dispatch_sentinel_block
.smc_exit_block: equ $-2
        ld      (redraw_pipes_linemajor.smc_first_block), hl
        jp      redraw_pipes_linemajor.dispatch_back

;----------------------------------------------------------------
; update_smc: load pre-shifted pipe bytes into the SMC slots actually used.
; With byte_x always in [1, 29], every pipe uses paint_LMMR / paint_LMMR_city —
; so only those routines' slots need updating. Edge variants (paint_L, _LM,
; _LMM, _MMR, _MR, _R + city versions) are dead code paths now.
;----------------------------------------------------------------
update_smc:
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      c, a
        ld      b, 0

        ; Pattern A → A variant body slots (lm_pN_aXXX, used on EVEN rows)
        ld      hl, pipe_bitmap
        add     hl, bc
        ld      a, (hl)                  ; A byte 0 (L cell)
        ld      (paint_LMMR.smc_l + 1), a
        ld      (paint_LMMR.smc_tail_l + 1), a
        ld      (paint_LMMR_city.smc_l + 1), a
        ld      (paint_LMMR_city.smc_tail_l + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aL), a
        ld      (redraw_pipes_linemajor.lm_p2_aL), a
        ld      (redraw_pipes_linemajor.lm_p3_aL), a
        ; L is same byte in A and B pipe patterns — propagate to B slots too
        ld      (redraw_pipes_linemajor.lm_p1_aL_b), a
        ld      (redraw_pipes_linemajor.lm_p2_aL_b), a
        ld      (redraw_pipes_linemajor.lm_p3_aL_b), a
        ; City-section emit slots start with SKY values; per-pipe transitions
        ; flip them to city values as the line counter reaches each pipe's
        ; building top during the cityscape pass.
        inc     hl
        ld      a, (hl)                  ; A byte 1 (M1)
        ld      (paint_LMMR.smc_m1 + 1), a
        ld      (paint_LMMR.smc_tail_m1 + 1), a
        ld      (paint_LMMR_city.smc_m1 + 1), a
        ld      (paint_LMMR_city.smc_tail_m1 + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aM1), a
        ld      (redraw_pipes_linemajor.lm_p2_aM1), a
        ld      (redraw_pipes_linemajor.lm_p3_aM1), a
        ld      (redraw_pipes_linemajor.lm_p1_aM1_b), a
        ld      (redraw_pipes_linemajor.lm_p2_aM1_b), a
        ld      (redraw_pipes_linemajor.lm_p3_aM1_b), a
        inc     hl
        ld      a, (hl)                  ; A byte 2 (M2)
        ld      (paint_LMMR.smc_m2 + 1), a
        ld      (paint_LMMR.smc_tail_m2 + 1), a
        ld      (paint_LMMR_city.smc_m2 + 1), a
        ld      (paint_LMMR_city.smc_tail_m2 + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aM2), a
        ld      (redraw_pipes_linemajor.lm_p2_aM2), a
        ld      (redraw_pipes_linemajor.lm_p3_aM2), a
        inc     hl
        ld      a, (hl)                  ; A byte 3 (R)
        ld      (paint_LMMR.smc_r + 1), a
        ld      (paint_LMMR.smc_tail_r + 1), a
        ld      (paint_LMMR_city.smc_r + 1), a
        ld      (paint_LMMR_city.smc_tail_r + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aR), a
        ld      (redraw_pipes_linemajor.lm_p2_aR), a
        ld      (redraw_pipes_linemajor.lm_p3_aR), a

        ; Pattern B → B variant body slots (used on ODD rows for right-side
        ; checker dither; M2 and R differ from A pattern, L and M1 same)
        ld      hl, pipe_bitmap_b
        add     hl, bc
        ld      a, (hl)                  ; B byte 0
        ld      (paint_LMMR.smc_b_l + 1), a
        ld      (paint_LMMR.smc_pre_b_l + 1), a
        ld      (paint_LMMR_city.smc_b_l + 1), a
        ld      (paint_LMMR_city.smc_pre_b_l + 1), a
        inc     hl
        ld      a, (hl)                  ; B byte 1
        ld      (paint_LMMR.smc_b_m1 + 1), a
        ld      (paint_LMMR.smc_pre_b_m1 + 1), a
        ld      (paint_LMMR_city.smc_b_m1 + 1), a
        ld      (paint_LMMR_city.smc_pre_b_m1 + 1), a
        inc     hl
        ld      a, (hl)                  ; B byte 2
        ld      (paint_LMMR.smc_b_m2 + 1), a
        ld      (paint_LMMR.smc_pre_b_m2 + 1), a
        ld      (paint_LMMR_city.smc_b_m2 + 1), a
        ld      (paint_LMMR_city.smc_pre_b_m2 + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aM2_b), a
        ld      (redraw_pipes_linemajor.lm_p2_aM2_b), a
        ld      (redraw_pipes_linemajor.lm_p3_aM2_b), a
        inc     hl
        ld      a, (hl)                  ; B byte 3
        ld      (paint_LMMR.smc_b_r + 1), a
        ld      (paint_LMMR.smc_pre_b_r + 1), a
        ld      (paint_LMMR_city.smc_b_r + 1), a
        ld      (paint_LMMR_city.smc_pre_b_r + 1), a
        ld      (redraw_pipes_linemajor.lm_p1_aR_b), a
        ld      (redraw_pipes_linemajor.lm_p2_aR_b), a
        ld      (redraw_pipes_linemajor.lm_p3_aR_b), a

        ; Phase-indexed outside-pixel masks (only LMMR_city needs these).
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
        ld      hl, r_out_masks
        add     hl, bc
        ld      a, (hl)
        ld      (paint_LMMR_city.smc_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_b_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_pre_b_r_outmask + 1), a
        ld      (paint_LMMR_city.smc_tail_r_outmask + 1), a

        ; Cache "pipe-on-cityscape" L and R tile bytes for both variants of
        ; this phase. At CITY_TOP transition, A-variant slots get patched
        ; from city_aL/R_cache ($FF bg = solid-bar rows) and B-variant slots
        ; get patched from city_bL/R_cache ($99 bg = window rows), matching
        ; the cityscape pattern's per-row parity.
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap_city_a
        add     hl, bc                  ; HL → city A.L byte for this phase
        ld      a, (hl)
        ld      (city_aL_cache), a
        inc     hl
        inc     hl
        inc     hl                      ; skip M1, M2 → R byte
        ld      a, (hl)
        ld      (city_aR_cache), a
        ld      hl, pipe_bitmap_city_b
        add     hl, bc                  ; HL → city B.L byte for this phase
        ld      a, (hl)
        ld      (city_bL_cache), a
        inc     hl
        inc     hl
        inc     hl                      ; skip M1, M2 → R byte
        ld      a, (hl)
        ld      (city_bR_cache), a
        ret

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
        ; DIAGNOSTIC v3: BC/DE setup re-enabled. update_cap_imm and update_city_cache STILL SKIPPED.
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
        ; Refresh cap and city byte values for current phase
        call    update_cap_imm          ; clobbers BC, DE
        call    update_city_cache       ; clobbers BC, DE
        ; Reload BC/DE from scratch so PIPE_PROGRAM sees correct body bytes
        ld      bc, (body_a_bc)
        ld      de, (body_a_de)
        ; PIPE_PROGRAM has its own prologue (save SP) and epilogue (restore SP + ret)
        call    PIPE_PROGRAM
        ret

seed_pipe_program_with_ret:
        ld      a, $C9                  ; RET
        ld      (PIPE_PROGRAM), a
        ret

;----------------------------------------------------------------
;----------------------------------------------------------------
; Line-major rendering (Joffa-style). For each scan line L from 0 to
; GROUND_TOP-1, emit all NUM_PIPES pipes' content at line L, then advance
; to L+1. Writer stays just ahead of the raster: per-line cost (~210 T-st
; for 3 pipes) is under the raster's 224 T-st/line so once we start ahead
; we stay ahead all the way down.
;
; Per-pipe state stored in pipe_lm_state[NUM_PIPES]:
;   +0: byte_x
;   +1: cap_top_line   (= gap_y - 1)
;   +2: cap_bot_line   (= gap_y + PIPE_GAP)
;   +3: body_bot_start (= gap_y + PIPE_GAP + 1)
;----------------------------------------------------------------
; redraw_pipes_linemajor: TIGHT inline per-pipe emit, direct SMC bytes.
; Per pipe per line ~55 T-st (body); 3 pipes per line ~190 T-st total. Under
; raster's 224 T-st/line so writer stays ahead of the beam all the way down.
;
; SMC slots (per pipe, 13 slots × 3 pipes = 39 patched per frame at setup):
;   byte_x offset (= byte_x - 1, added to line addr low byte to get L cell)
;   capt_smc      (cap_top_line for line-vs-state dispatch)
;   capb_smc      (cap_bot_line)
;   A pattern body bytes × 4
;   B pattern body bytes × 4
;   cap pattern bytes × 4

redraw_pipes_linemajor:
        ; ── Dual-loop "Joffa-style" pipe renderer. Two inline emit blocks
        ; alternate: A variant on even rows (A pipe bitmap + $FF cityscape
        ; bg), B variant on odd rows (B pipe bitmap + $99 cityscape bg).
        ; This gets the right-side checker dither AND makes the cityscape
        ; pattern match perfectly behind the pipes (the band alternates the
        ; same $FF/$99 bytes per row, so pipe edges read identical to the
        ; buildings flanking them).
        ; Pair counter C counts pairs (1 pair = 1 A line + 1 B line). Each
        ; pass through .line_lp_a + .line_lp_b draws 2 lines and decrements C.
        ld      (saved_sp), sp
        ld      hl, line_table
        ld      sp, hl

        ld      b, 0                    ; B = line counter (for pipe decisions)
        ld      c, CITY_TOP / 2         ; first phase: CITY_TOP/2 = 64 pairs
                                        ; of sky lines, then mid-loop SMC
                                        ; swap to city slots for 16 pairs.

.line_lp_a:
        ; SMC-unrolled per-cell city-transition gate. ONE check replaces 3
        ; per-pipe checks. When B matches smc_cursor_row, JP directly to
        ; the next sorted patch block (smc_first_block); the block (and any
        ; same-row chained blocks) flip body+cap slots from sky→city tile
        ; bytes for that cell, then JP back to .dispatch_back. No SP-swap,
        ; no BC clobber — patches use direct ld a, (nn) / ld (nn), a only.
        ld      a, b
        cp      $FF
.smc_cursor_row: equ $-1
        jr      nz, .dispatch_back
        jp      dispatch_sentinel_block
.smc_first_block: equ $-2
.dispatch_back:
        pop     de                      ; DE = line addr (SP advances in line_table)
        ld      h, d                    ; HOIST: H = line_addr_high once per line.

        ; ────── Pipe 1, A variant ──────
        ld      a, b
        cp      0                       ; A vs capb+1
.lm_p1_capb_plus_1: equ $-1
        jr      nc, .p1_body
        cp      0                       ; A vs capt
.lm_p1_capt: equ $-1
        jr      c, .p1_body
        jr      z, .p1_cap
        cp      0                       ; A vs capb
.lm_p1_capb: equ $-1
        jr      z, .p1_cap
        jp      .p1_done
.p1_cap:
        ld      a, 0
.lm_p1_offc: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p1_cL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cR: equ $-1
        jp      .p1_done
.p1_body:
        ld      a, 0
.lm_p1_offb: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p1_aL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aR: equ $-1
.p1_done:

        ; ────── Pipe 2, A variant ──────
        ld      a, b
        cp      0
.lm_p2_capb_plus_1: equ $-1
        jr      nc, .p2_body
        cp      0
.lm_p2_capt: equ $-1
        jr      c, .p2_body
        jr      z, .p2_cap
        cp      0
.lm_p2_capb: equ $-1
        jr      z, .p2_cap
        jp      .p2_done
.p2_cap:
        ld      a, 0
.lm_p2_offc: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p2_cL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cR: equ $-1
        jp      .p2_done
.p2_body:
        ld      a, 0
.lm_p2_offb: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p2_aL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aR: equ $-1
.p2_done:

        ; ────── Pipe 3, A variant ──────
        ld      a, b
        cp      0
.lm_p3_capb_plus_1: equ $-1
        jr      nc, .p3_body
        cp      0
.lm_p3_capt: equ $-1
        jr      c, .p3_body
        jr      z, .p3_cap
        cp      0
.lm_p3_capb: equ $-1
        jr      z, .p3_cap
        jp      .p3_done
.p3_cap:
        ld      a, 0
.lm_p3_offc: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p3_cL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cR: equ $-1
        jp      .p3_done
.p3_body:
        ld      a, 0
.lm_p3_offb: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p3_aL: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aM1: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aM2: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aR: equ $-1
.p3_done:

        inc     b                       ; advance to odd line (the B iter below)
        ; Fall through to B variant (no dec c here — counter ticks per pair)

.line_lp_b:
        pop     de
        ld      h, d

        ; ────── Pipe 1, B variant ──────
        ld      a, b
        cp      0
.lm_p1_capb_plus_1_b: equ $-1
        jr      nc, .p1b_body
        cp      0
.lm_p1_capt_b: equ $-1
        jr      c, .p1b_body
        jr      z, .p1b_cap
        cp      0
.lm_p1_capb_b: equ $-1
        jr      z, .p1b_cap
        jp      .p1b_done
.p1b_cap:
        ld      a, 0
.lm_p1_offc_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p1_cL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_cR_b: equ $-1
        jp      .p1b_done
.p1b_body:
        ld      a, 0
.lm_p1_offb_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p1_aL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p1_aR_b: equ $-1
.p1b_done:

        ; ────── Pipe 2, B variant ──────
        ld      a, b
        cp      0
.lm_p2_capb_plus_1_b: equ $-1
        jr      nc, .p2b_body
        cp      0
.lm_p2_capt_b: equ $-1
        jr      c, .p2b_body
        jr      z, .p2b_cap
        cp      0
.lm_p2_capb_b: equ $-1
        jr      z, .p2b_cap
        jp      .p2b_done
.p2b_cap:
        ld      a, 0
.lm_p2_offc_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p2_cL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_cR_b: equ $-1
        jp      .p2b_done
.p2b_body:
        ld      a, 0
.lm_p2_offb_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p2_aL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p2_aR_b: equ $-1
.p2b_done:

        ; ────── Pipe 3, B variant ──────
        ld      a, b
        cp      0
.lm_p3_capb_plus_1_b: equ $-1
        jr      nc, .p3b_body
        cp      0
.lm_p3_capt_b: equ $-1
        jr      c, .p3b_body
        jr      z, .p3b_cap
        cp      0
.lm_p3_capb_b: equ $-1
        jr      z, .p3b_cap
        jp      .p3b_done
.p3b_cap:
        ld      a, 0
.lm_p3_offc_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p3_cL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_cR_b: equ $-1
        jp      .p3b_done
.p3b_body:
        ld      a, 0
.lm_p3_offb_b: equ $-1
        add     a, e
        ld      l, a
        ld      (hl), 0
.lm_p3_aL_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aM1_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aM2_b: equ $-1
        inc     l
        ld      (hl), 0
.lm_p3_aR_b: equ $-1
.p3b_done:

        inc     b                       ; advance to next even line
        dec     c                       ; one pair done
        jp      nz, .line_lp_a
        ; Sky pairs exhausted. Check section boundary (B==CITY_TOP) or end.
        ld      a, b
        cp      GROUND_TOP
        jp      nc, .restore
        ; B == CITY_TOP. Arm cursor: copy first sorted (row, block) from
        ; the wrap-time initialisers into the line loop's SMC slots.
        ld      hl, (dispatch_first_block_init)
        ld      (.smc_first_block), hl
        ld      a, (dispatch_first_row_init)
        ld      (.smc_cursor_row), a
        ld      c, (GROUND_TOP - CITY_TOP) / 2
        jp      .line_lp_a

.restore:
        ld      sp, (saved_sp)
        ret

lm_line_addr: dw 0
lm_line_num:  db 0

;----------------------------------------------------------------
; Pipe drawing — split into two passes for race-the-beam:
;   draw_pipe_body_top: tops of pipes (rendered first across all pipes so the
;     last-drawn pipe's top still beats the raster).
;   draw_pipe_rest:     caps + body_bot (raster reaches those rows later).
; byte_x always in [1, 29] — pipe always uses paint_LMMR / paint_LMMR_city.
;----------------------------------------------------------------
; draw_pipe_body_top: paint pipe body_top (lines 0..gap_y-2). Always sky band
; since random_gap_y caps gap_y at 96 < CITY_TOP=128, so body_top is always
; entirely above the city band → only paint_LMMR needed.
; in: C = byte_x, E = gap_y
draw_pipe_body_top:
        ld      a, e
        cp      2
        ret     c                       ; gap_y < 2 → no body_top to draw
        sub     1
        ld      b, a
        xor     a
        jp      paint_LMMR

; draw_pipe_rest: cap_top + cap_bot + body_bot.
; in: C = byte_x, E = gap_y
draw_pipe_rest:
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
        call    paint_cap_rounded_LMMR_city
        jr      .cap_top_done
.cap_top_normal:
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
        call    paint_cap_rounded_LMMR_city
        jr      .cap_bot_done
.cap_bot_normal:
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
        call    paint_LMMR
        ; City portion: start=CITY_TOP, count=32 (constant)
        ld      b, CITY_BOTTOM - CITY_TOP
        ld      a, CITY_TOP
        jp      paint_LMMR_city
.body_bot_city_only:
        ; D >= CITY_TOP. count = GROUND_TOP - D.
        ld      a, GROUND_TOP
        sub     d
        ld      b, a
        ld      a, d
        jp      paint_LMMR_city


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
; update_city_cache: refresh 384-byte cache at CITY_CACHE.
;   slot[(row - CITY_TOP) * 12 + pipe * 4 + cell] =
;     if cityscape_heights[col_cell] >= (CITY_BOTTOM - row):
;       L/R: pipe_bitmap_city_X[phase*4 + cell] OR bg_buffer[col_cell][row]
;       M1/M2: pipe_bitmap_city_X[phase*4 + cell]
;     else:
;       pipe_bitmap[phase*4 + cell]
;
; X = 'a' for even rows, 'b' for odd rows.
; col_cell = byte_x_pipe + cell - 1 (cell in {0=L, 1=M1, 2=M2, 3=R}).
;
; Cost target: ~5 k T-states/frame.
;----------------------------------------------------------------

;----------------------------------------------------------------
; update_cap_imm: for each (pipe, cap-row) recorded in cap_slot_table,
; write the current phase's cap byte values into the bc-imm and de-imm
; slots inside pipe_program.
;
; cap_slot_table layout per cap-row entry (4 bytes):
;   [bc_imm_lo_addr, bc_imm_hi_addr, de_imm_lo_addr, de_imm_hi_addr]
; The bc-imm slot expects (lo=L, hi=M1). The de-imm slot expects (lo=M2, hi=R).
; Cap bytes source: cap_rounded_bitmap[phase*4 + 0..3] = [L, M1, M2, R].
;----------------------------------------------------------------
update_cap_imm:
        ld      hl, cap_rounded_bitmap
        ld      a, (phase)
        add     a, a
        add     a, a                    ; phase * 4
        ld      e, a
        ld      d, 0
        add     hl, de                  ; HL → cap_rounded_bitmap[phase*4]
        ld      a, (hl)                 ; L
        ld      (cap_L_temp), a
        inc     hl
        ld      a, (hl)                 ; M1
        ld      (cap_M1_temp), a
        inc     hl
        ld      a, (hl)                 ; M2
        ld      (cap_M2_temp), a
        inc     hl
        ld      a, (hl)                 ; R
        ld      (cap_R_temp), a

        ld      ix, cap_slot_table
        ld      b, 6                    ; 6 cap-rows worst case (3 pipes × 2 caps)
.lp:
        ld      l, (ix+0)
        ld      h, (ix+1)
        ld      a, h
        or      l
        jr      z, .skip                ; slot=0 means cap row not present
        ; (HL) = L slot, (HL+1) = M1 slot
        ld      a, (cap_L_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_M1_temp)
        ld      (hl), a
        ; Now the de-imm slot
        ld      l, (ix+2)
        ld      h, (ix+3)
        ld      a, (cap_M2_temp)
        ld      (hl), a
        inc     hl
        ld      a, (cap_R_temp)
        ld      (hl), a
.skip:
        ld      de, 4
        add     ix, de                  ; advance to next cap-row entry (4 bytes)
        djnz    .lp
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

city_row_temp:   db 0                  ; current row
city_pipe_temp:  db 0                  ; current pipe index
city_bx_temp:    db 0                  ; current pipe byte_x
city_cell_temp:  db 0                  ; current cell index 0..3

; Phase-dependent values, hoisted once per call out of the per-cell loop.
sky_a_L:         db 0
sky_a_M1:        db 0
sky_a_M2:        db 0
sky_a_R:         db 0
sky_b_L:         db 0
sky_b_M1:        db 0
sky_b_M2:        db 0
sky_b_R:         db 0
lmask_temp:      db 0
rmask_temp:      db 0
; Hoisted per-(pipe) interleaved data (8 bytes per pipe: heights+col_cells).
;   pipe*8 + 0..3 = heights[L, M1, M2, R]
;   pipe*8 + 4..7 = col_cells[L, M1, M2, R]
pipe_hoist_data: ds 24             ; 3 pipes × 8 bytes
sky_row:         ds 4              ; active variant's L M1 M2 R for current row
threshold_temp:  db 0
bg_row_lo:       db 0
bg_row_hi:       db 0

update_city_cache:
        ; --- HOIST 1: phase byte values for sky-A and sky-B ---
        ld      a, (phase)
        add     a, a
        add     a, a                    ; A = phase * 4
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap
        add     hl, bc
        ld      de, sky_a_L
        ldi
        ldi
        ldi
        ldi
        ld      a, (phase)
        add     a, a
        add     a, a
        ld      c, a
        ld      b, 0
        ld      hl, pipe_bitmap_b
        add     hl, bc
        ld      de, sky_b_L
        ldi
        ldi
        ldi
        ldi
        ; --- HOIST 2: masks for phase ---
        ld      a, (phase)
        ld      l, a
        ld      h, 0
        ld      de, l_out_masks
        add     hl, de
        ld      a, (hl)
        ld      (lmask_temp), a
        ld      a, (phase)
        ld      l, a
        ld      h, 0
        ld      de, r_out_masks
        add     hl, de
        ld      a, (hl)
        ld      (rmask_temp), a

        ; --- HOIST 3: heights and col_cells per (pipe, cell) into pipe_hoist_data
        ;       layout: [h_L, h_M1, h_M2, h_R, c_L, c_M1, c_M2, c_R] per pipe (8 bytes)
        ld      iy, pipe_hoist_data
        ld      b, 0                    ; pipe index (0..2)
.hp_lp:
        ld      hl, pipe_state
        ld      a, b
        add     a, a
        add     a, l
        ld      l, a
        ld      a, (hl)                 ; A = byte_x
        ld      d, a                    ; D = byte_x
        ld      e, 0                    ; E = cell index
.hc_lp:
        ld      a, d
        add     a, e
        dec     a                       ; A = col_cell
        ld      (iy+4), a               ; store col_cell at offset +4..+7
        ld      l, a
        ld      h, 0
        push    de
        ld      de, cityscape_heights
        add     hl, de
        pop     de
        ld      a, (hl)
        ld      (iy+0), a               ; store height at offset +0..+3
        inc     iy
        inc     e
        ld      a, e
        cp      4
        jr      c, .hc_lp
        ; iy advanced 4 (past heights). Advance 4 more (past col_cells of this pipe).
        push    de
        ld      de, 4
        add     iy, de
        pop     de
        inc     b
        ld      a, b
        cp      NUM_PIPES
        jr      c, .hp_lp

        ; --- WALK ROWS: flat, hoisted, HL=cache cursor, IX=pipe data ---
        ld      hl, CITY_CACHE          ; HL = cache cursor (fast ld (hl),a writes)
        ld      b, CITY_TOP             ; B = row
.row_lp:
        ; threshold = CITY_BOTTOM - row
        ld      a, CITY_BOTTOM
        sub     b
        ld      (threshold_temp), a

        ; bg_buffer row base
        push    hl                      ; save cache cursor
        ld      l, b
        ld      h, 0
        add     hl, hl
        ld      de, line_table
        add     hl, de
        ld      a, (hl)
        ld      (bg_row_lo), a
        inc     hl
        ld      a, (hl)
        or      $80
        ld      (bg_row_hi), a

        ; Pick sky variant by row parity, copy 4 bytes into sky_row
        ld      a, b
        and     1
        jr      nz, .pick_b
        ld      hl, sky_a_L
        jr      .have_pick
.pick_b:
        ld      hl, sky_b_L
.have_pick:
        ld      de, sky_row
        push    bc                      ; LDI clobbers BC; save B (row)
        ldi
        ldi
        ldi
        ldi
        pop     bc
        pop     hl                      ; restore cache cursor

        ; Walk 3 pipes inline; IX walks pipe_hoist_data in 8-byte strides
        push    ix
        ld      ix, pipe_hoist_data
        ld      c, 0                    ; C = pipe (0..2)
.r_pipe_lp:
        ; --- Cell 0 (L) ---
        ld      a, (threshold_temp)
        cp      (ix+0)
        jr      nc, .c0_sky
        ; city L: col_cell at (ix+4)
        ld      a, (ix+4)
        push    hl
        ld      l, a
        ld      h, 0
        ld      de, (bg_row_lo)
        add     hl, de
        ld      a, (hl)
        ld      d, a
        ld      a, (lmask_temp)
        and     d
        ld      d, a
        ld      a, (sky_row+0)
        or      d
        pop     hl
        ld      (hl), a
        jr      .c0_done
.c0_sky:
        ld      a, (sky_row+0)
        ld      (hl), a
.c0_done:
        inc     hl

        ; --- Cell 1 (M1): always sky byte ---
        ld      a, (sky_row+1)
        ld      (hl), a
        inc     hl

        ; --- Cell 2 (M2): always sky byte ---
        ld      a, (sky_row+2)
        ld      (hl), a
        inc     hl

        ; --- Cell 3 (R) ---
        ld      a, (threshold_temp)
        cp      (ix+3)
        jr      nc, .c3_sky
        ; city R: col_cell at (ix+7)
        ld      a, (ix+7)
        push    hl
        ld      l, a
        ld      h, 0
        ld      de, (bg_row_lo)
        add     hl, de
        ld      a, (hl)
        ld      d, a
        ld      a, (rmask_temp)
        and     d
        ld      d, a
        ld      a, (sky_row+3)
        or      d
        pop     hl
        ld      (hl), a
        jr      .c3_done
.c3_sky:
        ld      a, (sky_row+3)
        ld      (hl), a
.c3_done:
        inc     hl

        ; Advance IX by 8 (next pipe's interleaved data)
        push    de
        ld      de, 8
        add     ix, de
        pop     de

        inc     c
        ld      a, c
        cp      NUM_PIPES
        jp      c, .r_pipe_lp
        pop     ix

        inc     b
        ld      a, b
        cp      GROUND_TOP
        jp      c, .row_lp

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
; is laid on top — cityscape/pipe pixels behind the bird don't bleed through.
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
        call    paint_city_attrs
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
