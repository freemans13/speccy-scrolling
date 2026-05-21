# Beeper Sound Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a flap "fwip" and a score "rising chime" to Speccy Flappy Bird using the 48K beeper, generated as a cycle-bounded frame-end idle slice that never causes a missed `halt`.

**Architecture:** A frame-sliced beeper engine (`sfx_tick`) runs in `main_loop`'s idle region under `di`. It plays speaker edges until a per-frame T-state budget (`sound_budget`) is exhausted, so it can never overrun into the next interrupt. Sound effects are data descriptors (segment tables) walked across many frames; persistent state lives in a small RAM block. Triggers in `read_input` and `update_score` only set state — all generation happens in the idle tick.

**Tech Stack:** Z80 assembly, sjasmplus, single-file project (`src/main.asm`). No unit-test harness exists.

---

## Verification model

This is Z80 assembly for a 50 Hz Spectrum game. There is **no automated test
framework**. Verification per task is:

1. **Build check (every task):** run `make` from the project root; it must
   report `Errors: 0, warnings: 0`.
2. **Human checkpoint (marked tasks only):** the human runs `make run` in Fuse
   and confirms behaviour. The assistant cannot run the emulator — at a
   CHECKPOINT, stop and ask the human to run and report back.

Initial timing constants are deliberately conservative (small budgets) so the
first runnable build cannot drop to 25 Hz; Task 6 calibrates them upward.

## File structure

Only one file changes: `src/main.asm`. The work adds three regions:

- **Constants** — EQU block near the existing EQU section (after line 35).
- **Sound state + descriptors** — `db`/`dw` declarations near the score state
  (after line 206).
- **Engine routines** — `sfx_trigger_*`, `sfx_begin`, `sfx_next_segment`,
  `sfx_tick` — inserted after `render_score`'s helpers (after line 3374,
  before `bird_attr_addr`).
- **Wiring** — small edits inside `read_input`, `update_score`, `main_loop`.

---

## Task 1: Constants, sound state block, descriptor tables

**Files:**
- Modify: `src/main.asm` (EQU section ~line 35; data section ~line 206)

- [ ] **Step 1: Add the constants**

Insert after line 35 (`SCORE_TOP EQU 168 ...`):

```
; ─── Beeper sound effects ────────────────────────────────────────
SPK_BIT           EQU $10                ; bit 4 of port $FE = speaker
SOUND_BORDER      EQU $01                ; blue profile band for the sound region
EDGE_FIXED_ITERS  EQU 6                  ; per-edge non-delay overhead in delay-iter units (CALIBRATE — Task 6)
SND_BUDGET_NORMAL EQU 300                ; sound delay-iters allowed on normal/wrap frames (CALIBRATE — Task 6)
SND_BUDGET_CONFIG EQU 40                 ; sound delay-iters allowed on swap/build frames (CALIBRATE — Task 6)
```

- [ ] **Step 2: Add the sound state block**

Insert after line 206 (`pipe_scored: db 0, 0, 0, 0 ...`):

```
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
```

- [ ] **Step 3: Add the descriptor tables**

Insert immediately after the sound state block from Step 2.

Segment format — 6 bytes: `db mode` (0=tone, 1=noise; $FF terminates),
`dw half_period`, `dw edge_count`, `db sweep` (signed).

```
; ─── SFX descriptors ─────────────────────────────────────────────
; Flap "fwip": noise burst, clock rate sweeps downward (darkens as it fades).
sfx_flap:
        db 1 : dw  90 : dw 70 : db  3
        db 1 : dw 160 : dw 55 : db  6
        db 1 : dw 280 : dw 40 : db 10
        db $FF
; Score chime: three ascending pure tones, last note held longest.
sfx_chime:
        db 0 : dw 150 : dw 48 : db 0
        db 0 : dw 120 : dw 52 : db 0
        db 0 : dw  95 : dw 80 : db 0
        db $FF
```

- [ ] **Step 4: Build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`. (Nothing references the new symbols yet,
so this only proves the declarations assemble.)

- [ ] **Step 5: Commit**

```bash
git add src/main.asm
git commit -m "feat: add beeper SFX constants, state block and descriptors"
```

---

## Task 2: Trigger routines and descriptor loading

**Files:**
- Modify: `src/main.asm` (insert engine routines after line 3374, before `bird_attr_addr`)

- [ ] **Step 1: Add the trigger and segment-load routines**

Insert after line 3374 (the `ret` ending `render_score`'s `.gd_done`), before
the `bird_attr_addr` comment at line 3376:

```
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
        ld      a, 0                    ; id = flap
        jr      sfx_begin

; sfx_trigger_chime: start the chime, interrupting any flap.
; Clobbers A, HL.
sfx_trigger_chime:
        ld      hl, sfx_chime
        ld      a, 1                    ; id = chime
        ; fall through into sfx_begin

; sfx_begin: HL = descriptor address, A = sound id. Arms the effect.
; sound_edges_left is zeroed so sfx_tick loads segment 0 on its next call.
; Clobbers A.
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
```

- [ ] **Step 2: Build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 3: Commit**

```bash
git add src/main.asm
git commit -m "feat: add beeper SFX trigger and segment-load routines"
```

---

## Task 3: The `sfx_tick` engine

**Files:**
- Modify: `src/main.asm` (append after `sfx_next_segment` from Task 2)

The engine plays speaker edges until the per-frame budget is spent. Each edge
costs `sound_half + EDGE_FIXED_ITERS` delay-iters; before playing an edge the
engine checks that cost fits in the remaining budget, guaranteeing it returns
before the next interrupt.

- [ ] **Step 1: Add `sfx_tick`**

Insert immediately after the `sfx_next_segment` routine:

```
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
```

- [ ] **Step 2: Build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`. (Engine still unreferenced — proves it
assembles.)

- [ ] **Step 3: Commit**

```bash
git add src/main.asm
git commit -m "feat: add cycle-bounded beeper SFX engine sfx_tick"
```

---

## Task 4: Wire triggers into input and scoring

**Files:**
- Modify: `src/main.asm` — `read_input` (~line 3418), `update_score` (~line 3300)

- [ ] **Step 1: Trigger the flap on a flap input**

In `read_input`, the accepted-flap path currently reads:

```
        ld      hl, FLAP_VY
        ld      (bird_vy), hl
        ret
```

Change it to call the flap trigger before returning:

```
        ld      hl, FLAP_VY
        ld      (bird_vy), hl
        call    sfx_trigger_flap
        ret
```

- [ ] **Step 2: Trigger the chime on a score increment**

In `update_score`, the score-bump path currently reads (lines ~3296-3302):

```
        push    hl
        push    bc
        ld      hl, (score)
        inc     hl
        ld      (score), hl
        pop     bc
        pop     hl
        jr      .next
```

Insert the chime trigger after the score store. `sfx_trigger_chime` clobbers
A and HL only; BC and the saved HL are restored by the existing `pop`s:

```
        push    hl
        push    bc
        ld      hl, (score)
        inc     hl
        ld      (score), hl
        call    sfx_trigger_chime
        pop     bc
        pop     hl
        jr      .next
```

- [ ] **Step 3: Build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 4: Commit**

```bash
git add src/main.asm
git commit -m "feat: trigger beeper SFX from flap input and score increment"
```

---

## Task 5: Wire `sfx_tick` and per-frame budget into `main_loop` — CHECKPOINT

**Files:**
- Modify: `src/main.asm` — `main_loop` (lines 100-154)

`main_loop` must (a) flag whether the current frame is a heavy "configure"
frame and (b) call `sfx_tick` with the right `sound_budget` in the idle
region. Wrap frames are treated as normal: `SND_BUDGET_NORMAL` is calibrated
in Task 6 against the wrap-frame idle (the smaller of the two), so a separate
wrap budget is not needed.

- [ ] **Step 1: Add the heavy-frame flag declaration**

Insert after the sound state block (after `sound_budget` from Task 1, Step 2):

```
sound_heavy_frame:  db 0                   ; 1 = configure/swap/build frame this frame
```

- [ ] **Step 2: Clear the flag at the top of each frame**

In `main_loop`, after the `out ($fe), a` at line 104 (the RED profile marker)
and before the `call restore_bird_bg` at line 109, insert:

```
        xor     a
        ld      (sound_heavy_frame), a
```

- [ ] **Step 3: Flag the swap frame**

In the `.swap_frame_skip` block (lines 147-149), which currently reads:

```
.swap_frame_skip:
        xor     a
        ld      (do_swap_fired), a
```

change it to also set the heavy flag:

```
.swap_frame_skip:
        xor     a
        ld      (do_swap_fired), a
        ld      a, 1
        ld      (sound_heavy_frame), a
```

- [ ] **Step 4: Flag build frames**

In the `.build_loop` block (lines 138-145), set the heavy flag whenever a
`prep_step` chunk actually runs. The block currently reads:

```
.build_loop:
        ld      a, (activate_pipe_idx)
        cp      255
        jr      z, .post_prep_step              ; idle, or build just finished
        push    bc
        call    prep_step
        pop     bc
        djnz    .build_loop
        jr      .post_prep_step
```

Change it to:

```
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
```

- [ ] **Step 5: Run the sound tick in the idle region**

The `.post_prep_step` block (lines 150-153) currently reads:

```
.post_prep_step:
        ld      a, 0                    ; PROFILE: BLACK = idle before halt
        out     ($fe), a
        ei
        jr      main_loop
```

Change it to select the budget, run the tick, then mark the leftover idle:

```
.post_prep_step:
        ld      hl, SND_BUDGET_NORMAL
        ld      a, (sound_heavy_frame)
        or      a
        jr      z, .snd_budget_set
        ld      hl, SND_BUDGET_CONFIG
.snd_budget_set:
        ld      (sound_budget), hl
        call    sfx_tick
        ld      a, 0                    ; PROFILE: BLACK = idle before halt
        out     ($fe), a
        ei
        jr      main_loop
```

- [ ] **Step 6: Build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 7: Commit**

```bash
git add src/main.asm
git commit -m "feat: drive beeper SFX from main_loop idle with per-frame budget"
```

- [ ] **Step 8: CHECKPOINT — human runs Fuse**

Stop here. Ask the human to run `make run` and confirm:
- Pressing SPACE to flap produces a short noisy "fwip".
- Scoring a point produces a three-note rising chime.
- Flapping during a chime does not cut the chime short.
- The game still runs smoothly with no visible stutter (no 25 Hz drop).

With the conservative initial budgets the effects will sound thin/quiet and
possibly chopped — that is expected and fixed in Task 6. The purpose of this
checkpoint is to confirm the wiring works and nothing crashes or stutters.
Wait for the human's report before starting Task 6.

---

## Task 6: Calibration — CHECKPOINT

**Files:**
- Modify: `src/main.asm` — the EQU constants from Task 1, and the descriptor
  tables if pitch/length need tuning.

Goal: raise `SND_BUDGET_NORMAL` / `SND_BUDGET_CONFIG` so the sound fills the
available idle time on each frame type, without ever crossing into the next
interrupt; verify `EDGE_FIXED_ITERS` reflects real per-edge overhead; tune the
descriptor pitches so the effects sound good.

- [ ] **Step 1: Profile the worst-case idle on each frame type**

The sound region renders as a blue band (`SOUND_BORDER = $01`); the next
frame's top blanking renders RED. Ask the human to run `make run` and watch
the border:
- On a **normal** frame the blue band must end with a black sliver before the
  RED band — that sliver is unused idle (safe margin).
- On a **configure** frame (every ~40th, brief) the blue band is much shorter;
  it must still end before RED.
- If the blue band ever touches/overruns RED, the budget for that frame type
  is too high — reduce it.

- [ ] **Step 2: Raise the budgets**

Increase `SND_BUDGET_NORMAL` and `SND_BUDGET_CONFIG` in the EQU block until
the blue band fills most of the idle on its frame type, leaving a small black
safety sliver before RED. Rebuild (`make`) and re-check in Fuse after each
change. Recommended procedure: double the value, rebuild, observe; back off
when the safety sliver gets thin. Keep ~10-15% of the idle as the sliver to
cover per-effect segment-load overhead not counted in `EDGE_FIXED_ITERS`.

- [ ] **Step 3: Tune `EDGE_FIXED_ITERS` if pitch is wrong**

If a chime tone sounds higher or lower than the descriptor's `half_period`
implies, the per-edge overhead is mis-estimated. `EDGE_FIXED_ITERS` only
affects budget accounting, not pitch — pitch comes from `sound_half`. If the
budget runs out noticeably earlier/later than the profiler predicts, adjust
`EDGE_FIXED_ITERS` so the budget math matches observed edge cost.

- [ ] **Step 4: Tune the descriptors**

Adjust `sfx_flap` and `sfx_chime` (Task 1, Step 3) so the effects sound right:
- Flap: a short, airy descending-noise "fwip" — adjust `half_period`, `sweep`
  and `edge_count` per segment.
- Chime: three clearly ascending notes — smaller `half_period` = higher pitch.
  Adjust until the rise is musical and the last note rings out.

- [ ] **Step 5: Final build check**

Run: `make`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 6: Commit**

```bash
git add src/main.asm
git commit -m "tune: calibrate beeper SFX budgets and descriptor pitches"
```

- [ ] **Step 7: CHECKPOINT — human final verification**

Ask the human to run `make run` and confirm:
- Flap "fwip" and score chime both sound good.
- Border profiling shows the blue sound band always ending before the RED
  band — on normal, wrap, AND configure frames. No 25 Hz drop, ever.
- Chime-beats-flap priority still holds.

---

## Self-review notes

- **Spec coverage:** slicing model + bounding (Task 3), no-click stop (Task 3
  — engine returns without snapping `sound_speaker`), flap noise + LFSR
  (Tasks 1, 3), chime tones (Tasks 1, 3), triggers + priority (Tasks 2, 4),
  per-frame budget + classification (Tasks 1, 5), blue profiling band
  (Tasks 1, 3), build/test (every task) — all covered.
- **Spec deviation:** the spec lists three budget constants
  (normal/wrap/configure); this plan uses two — `SND_BUDGET_NORMAL` is
  calibrated against the wrap-frame idle (the tighter of the two) so wrap
  frames are safe without a separate constant or wrap detection. The
  no-overrun guarantee and sound quality are unaffected.
- **Symbol consistency:** `sound_*` state names, `sfx_trigger_flap`,
  `sfx_trigger_chime`, `sfx_begin`, `sfx_next_segment`, `sfx_tick`,
  `sound_heavy_frame`, `SPK_BIT`, `SOUND_BORDER`, `EDGE_FIXED_ITERS`,
  `SND_BUDGET_NORMAL`, `SND_BUDGET_CONFIG` are used identically across tasks.
```
