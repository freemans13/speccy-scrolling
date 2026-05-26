# Patch-Only Pipe Renderer — Design Spec

**Status:** proposed
**Branch target:** new branch off `beeper-sfx`
**Motivation:** free ~13–16 k T per frame of render budget for future game features (bird animation upgrades, sound, scoreboard polish, extra render passes). Current `rebuild_step` amortisation rewrites identical body-slot bytes ~20 times per swap cycle for no reason — pure waste.

---

## 1. Goal

Replace the amortised `rebuild_step` machinery with a **one-shot patch-only `do_swap`** that touches only the bytes that actually change. Body-slot bytes are baked once at init and never rewritten.

### Success criteria

- Headless CMIO sim (`tools/runsim.py`): **0 overruns** over 3000 frames.
- Visual: pipes scroll smoothly, no trails / no 1-byte specks, score works.
- BLACK position spread: ≤ 5 k T (down from current ~3.7 k T spread we already have — should be no worse).
- Per-frame headroom: **≥ 13 k T below 70 k budget** on the heaviest wrap+swap frame.
- All `rebuild_step` / `prep_step` / `activate_pipe_idx` / `rebuild_band_cursor` machinery deleted.
- Code line count reduction in `src/main.asm`: ≥ 300 lines.

### Non-goals

- Changing visual pipe rendering (pixels, dither, cap shapes).
- Changing `clear_vacated_columns` — still needed for scroll trails.
- Changing sound budget — separate concern.
- Re-architecting how `apply_pipe_attrs_wrap` / `restore_trailing_pipe_attrs` work.

---

## 2. Current state (as of 2026-05-26, commit a08c755)

### What the renderer does each frame

```
main_loop:
  halt; di; OUT RED
  bird ops (~5 k T uncontended in vblank)
  PIPE_PROGRAM (~14 k T after JR-skip win; contended)
  update_score / render_score (~700 T)
  draw_ground (~4 k T)
  do_white_work:
    advance_phase × 2
    on phase-wrap: wrap_byte_x → patch_pipe_targets (and maybe do_swap)
  update_cap_imm_v2 (~2.4 k T)
  if activate_pipe_idx != 255:
    rebuild_step × 2   ← amortised pipe build, 2 bands per frame
  if wrap_pending:
    apply_pipe_attrs_wrap (~2 k T)
    restore_trailing_pipe_attrs (~2 k T)
    clear_vacated_columns (~10 k T with gap-skip)
  sfx_slice (cheap; sound budget = 0 currently)
  OUT BLACK; ei; jp main_loop
```

### Slot layout — Stage 6 (`emit_body_band`, used by `rebuild_step`)

Each band in PIPE_PROGRAM is **52 bytes** of body code + a 3-byte trailer at `+68`:

```
+0..3   DD 21 lo hi              ld ix, screen_target
+4..51  8 rows × 6 bytes:
          DD F9   ld sp, ix       (band-row N's screen address)
          D5 or E5  push de/hl    (A/B dither phase)
          C5      push bc
          DD 24   inc ixh         (+256 → next pixel row)
+52..67 NOP padding (16 bytes)
+68..70 C3 lo hi  jp next_band_base   ← stitched together at init
```

### Slot layout — Stage 2 (`configure_pipe_slots` + `BODY_TEMPLATE`, used by init)

Each ROW is a separate 5-byte slot scattered across PIPE_PROGRAM at addresses given by `slot_addr_table[row][pipe]`:

```
31 lo hi      ld sp, target_row     ← per-row screen address
D5 or E5      push de/hl
C5            push bc
```

160 rows × 5 bytes = 800 bytes per pipe. Different memory layout than Stage 6.

**Crucial observation:** the two formats produce identical pixel output (both do `ld sp ; push de/hl ; push bc`) but at different addresses in the slot grid. Currently:
- Pipes 0-2 init as Stage 2 (`configure_pipe_slots`)
- Pipe 3 inits as JR-skipped over NOP-fill (no real body bytes)
- After first swap, every pipe re-emits as Stage 6 via `rebuild_step`

### What changes per swap

| Item | Reason it changes | Bytes to patch |
|---|---|---|
| `byte_x` of inc resets to 29 | inc moves to right edge | (none — pipe_state byte) |
| 20 IX-target operands of inc's column | inc is back at byte_x=29 | 20 × 2 = 40 bytes |
| OLD K_top / K_bot of inc revert to body | inc's previous gap_y is replaced | 2 × 3 = 6 bytes |
| NEW K_top / K_bot of inc become cap-edge | inc has fresh random gap_y | 2 × 3 = 6 bytes |
| `cap_top_handler[inc].next` (SMC) | new K_bot position to jump to | 2 bytes |
| dep's column → JR-skip | dep parked | 20 × 2 = 40 bytes |
| dep's cap pixels on screen | gap_y will be different next time | screen pixel clear (already done) |
| cap-target imms (`cap_top_handler[inc]_target`, etc.) | new cap row screen addresses | 4 bytes |
| Active list for inc | new K layout | 16 × 2 = 32 bytes + sentinel |
| `pipe_state[dep].gap_y` ← fresh random | next activation | 1 byte |

**Total: ~140 bytes of patches per swap.** At ~11 T per byte write + addr setup ≈ ~2.5 k T.

### What `rebuild_step` does currently (wasted work)

For each of 20 bands, re-writes all 52 bytes of body code (or 49 bytes for cap-edge — emit_capedge_band). That's `20 × 52 = 1040 bytes` per swap, **most of which is identical to what was already there**.

Amortised over 10 frames → ~3 k T per frame during the build window + per-frame `rebuild_step` dispatch overhead in main_loop's YELLOW region.

---

## 3. Proposed architecture

### 3.1 Slot grid is Stage 6 for all 4 pipes at init

`init_pipes` is rewritten to produce Stage 6 layout uniformly:

```
init_pipes:
  init_pipe_program            ; trailer chain + epilogue at SLOT_GRID_END
  for each pipe N in 0..3:
    set cps_pipe = N
    if pipe is active (0..2):
      set cps_cap_top_row = gap_y - 1
      set cps_cap_bot_row = gap_y + PIPE_GAP
      call cps_emit_body_bands       ; emits body + cap-edge for this pipe
      call finalize_pipe_init        ; cap arming + active list + cap target imms
      if byte_x < 29:
        call shift_ix_targets        ; new helper: walks the 20 band IX operands
    else (prep pipe 3):
      set cps_cap_top_row = 255      ; out of band → all bands become body
      set cps_cap_bot_row = 255
      call cps_emit_body_bands       ; emits 20 body bands, no cap-edge
      call write_jrskip_column 3     ; stamp JR-skip over body bytes
```

`shift_ix_targets` replaces `shift_pipe_targets` — walks the 20 IX-operand positions (`band+2..+3`) instead of the active sublist.

`finalize_pipe_init` is the existing `rs_finalize` work, extracted into its own callable routine.

### 3.2 `do_swap` is one-shot patch-only

```
do_swap (A = dep pipe index):
  save ds_old_gap_y (= pipe_state[dep].gap_y)
  read prep_pipe_idx → ds_inc

  ; PART A: dep deactivation
  call restore_capedges_to_body(ds_dep, ds_old_gap_y)   ; 6 bytes patched
  ld A = ds_dep
  call write_jrskip_column                              ; 40 bytes patched
  call clear_old_cap_rows                               ; pixel clear (existing)

  ; PART B: inc activation
  pipe_state[ds_inc].byte_x = 29
  read pipe_state[ds_inc].gap_y → new_gap_y (set when inc was last dep)
  prep_gap_y = new_gap_y
  compute new K_top, K_bot

  call unjr_skip_column(ds_inc)                         ; 40 bytes patched (DD 21)
  call reset_ix_targets_to_29(ds_inc)                   ; 40 bytes patched
  call install_capedges(ds_inc, new K_top, K_bot)       ; 6 bytes patched + handler addrs
  call patch_cap_top_handler_next(ds_inc, K_bot+0)      ; 2 bytes
  call patch_cap_target_imms(ds_inc, new_gap_y)         ; uses CAP_TARGET_TABLE
  call cps_build_active_list                            ; ~3 k T (kept as-is)

  ; PART C: prep state rotation
  prep_pipe_idx = ds_dep
  call random_gap_y → pipe_state[ds_dep].gap_y = fresh random

  ret
```

**Estimated cost:** ~3.5 k T total, one-shot, on the swap frame.

Swap frame budget impact (with contention):
- Base frame work: ~30 k T
- do_swap: ~3.5 k T (vs ~14 k T sync rebuild we tried, which overran)
- apply/restore/clear: ~14 k T
- = ~47.5 k T → **22 k T headroom under 70 k budget**

### 3.3 What gets deleted

- `rebuild_step` and all its labels (`.rs_body`, `.rs_capedge_top`, `.rs_capedge_bot`, `.rs_advance`, `.rs_done`, `.rs_finalize`)
- `prep_step` (already dead code)
- `activate_pipe_idx` (and all uses in `patch_pipe_targets`, `wrap_byte_x`, etc.)
- `rebuild_band_cursor`, `rebuild_k_top`, `rebuild_k_bot`
- `do_swap_fired`
- main_loop YELLOW region's rebuild dispatch (3.4k T saved per frame avg)
- `REBUILD_IDLE_PAD_ITERS`, `REBUILD_FINALIZE_PAD_ITERS`, `REBUILD_2BAND_PAD_ITERS`
- `prep_phase`, `prep_row` (if no other consumers)
- `configure_pipe_slots` (replaced by `cps_emit_body_bands` + finalize at init)
- `BODY_TEMPLATE`, `CAP_BLOCK`, `slot_addr_table`, `init_slot_addr_table`, `slot_addr_lookup` (Stage 2 leftovers)
- `build_slot_templates` (the BODY_TEMPLATE / CAP_BLOCK init)
- `shift_pipe_targets` (replaced by `shift_ix_targets`)

**Conservative estimate: 300-400 lines of code deleted.** Several memory-trap pitfalls also become impossible (no Stage 2 / Stage 6 format mismatch, no half-emitted bands, no activate_pipe_idx state machine to mismanage).

---

## 4. Risk areas (from auto-memory)

These previous bugs lived in the area we're refactoring:

- **`split-configure cap-handler race`** — splitting `configure_pipe_slots` across frames left stale cap-edge bands that caused infinite loops. Mitigation: do all of do_swap in one shot, no splitting.
- **`do_swap partial-rewrite bug`** — `do_swap` step 5 rewriting only target bytes turned dep's cap-skip NOP rows into JP-to-ROM opcodes. Mitigation: write_jrskip_column writes all 20 bands' `+0..+1`, body bytes at `+2..+67` are well-defined Stage 6.
- **`ACTIVE_PIPE_X stale entries`** — patch_pipe_targets walking a stale active list corrupted slot bytes. Mitigation: rebuild the active list fully at activation time (cps_build_active_list is one-shot, not amortised).
- **`GRID_B unconfigured trap`** — pre-Stage 6 design had a second grid that was never fully configured. Not applicable (single grid).
- **`fallback OLD prep stale-pixel corruption`** — fallback path activated half-configured OLD prep. Mitigation: no fallback path (do_swap is unconditional).
- **`prep_step EXX-write clobbers row`** — bug specific to `prep_step` which we're deleting.

The conversion at init from Stage 2 to Stage 6 needs care:

- **Cap-handler addresses** in the SMC slots must match what cap_top_handler / cap_bot_handler routines expect (target imm + next imm).
- **Active list** must point at the actual Stage 6 IX-operand positions (band+2..+3), not at Stage 2 per-row slot addresses.
- **patch_pipe_targets** is already Stage-6-aware (reads addresses from the active sublist), so it should still work — but verify post-refactor that the sublist entries point at Stage 6 IX operands not Stage 2 ld-sp operands.

---

## 5. Implementation phases

Each phase commits separately for bisect.

### Phase 0: Spec + scaffold (no behaviour change)

- Commit this spec doc.
- Write a regression test: visual screenshot + frame timing summary after 600 sim frames. Save baseline.
- Tag commit `patch-only-baseline`.

### Phase 1: Extract `finalize_pipe_init` from `rebuild_step.rs_finalize`

- Move the cap-arming + cap-target-imm + active-list-build code out of `rebuild_step` into a callable routine.
- `rebuild_step.rs_finalize` becomes `call finalize_pipe_init ; ret`.
- Behaviour unchanged — verify visually + sim.

### Phase 2: Switch init to Stage 6

- Replace `configure_pipe_slots` call in `init_pipes` with:
  - `cps_emit_body_bands` (emits body + cap-edge for the pipe's current gap_y)
  - `finalize_pipe_init` (cap arming + active list + cap target imms)
  - new `shift_ix_targets` for byte_x < 29
- For pipe 3 (prep): emit body bands with cap_top_row=255 (no cap-edge), then `write_jrskip_column`.
- Verify pipes look identical to before. Active list addresses now point at Stage 6 IX operands.

### Phase 3: Replace `do_swap`'s rebuild trigger with patch-only

- Remove `do_swap`'s setting of `activate_pipe_idx`, `rebuild_band_cursor`, K bounds.
- Add the PART A / PART B / PART C calls from §3.2.
- New helpers: `restore_capedges_to_body`, `unjr_skip_column`, `reset_ix_targets_to_29`, `install_capedges`, `patch_cap_top_handler_next`, `patch_cap_target_imms`.
- Verify swap works (no visual regression after a few cycles).

### Phase 4: Strip rebuild_step from main_loop

- Remove the `rebuild_step` call + the `do_swap_fired` and `activate_pipe_idx == 255` checks from main_loop's YELLOW region.
- YELLOW region just becomes `PROFILE_OUT 6 ; (cap-imm v2 region) ; jr .post_prep_step`.
- Remove the REBUILD_*_PAD_ITERS EQUs.
- Verify still 0 overruns.

### Phase 5: Delete dead code

- Remove `rebuild_step`, `prep_step` and labels.
- Remove `activate_pipe_idx` and all references.
- Remove `configure_pipe_slots`, `BODY_TEMPLATE`, `CAP_BLOCK`, `slot_addr_table`, `build_slot_templates`, `init_slot_addr_table`, `slot_addr_lookup`, `shift_pipe_targets`.
- Remove `prep_phase`, `prep_row`, `prep_gap_y`, `prep_pipe_idx` (verify each isn't a load-bearing state).
- Final line count reduction check.

### Phase 6: Re-tune frame budget

- With ~13–16 k T per frame freed, can re-enable some Joffa pads for steadier borders OR re-enable sound. User's call.

---

## 6. Verification

Each phase must pass:

1. **Build clean:** `make` shows `Errors: 0, warnings: 0`.
2. **Headless sim 0 overruns:** `runsim.py` 1000 frames with CMIOSimulator → `awk` overrun-count = 0.
3. **Visual:** `snadump.py screen` PNG shows pipes scrolling cleanly, no trails, no specks, score increments.
4. **No regressions on existing memory pitfalls:** at least 30 simulated swap cycles before claiming success (because some bugs only manifest after the swap cycle goes around).

---

## 7. Estimated session time

- Phase 0: 15 min (spec + baseline)
- Phase 1: 30 min (extract finalize)
- Phase 2: 60 min (init refactor + verify)
- Phase 3: 90 min (do_swap refactor + verify)
- Phase 4: 30 min (strip main_loop)
- Phase 5: 30 min (delete dead code)
- Phase 6: 15 min (commit + push)

**Total: ~4-5 hours focused work.** Should be done in one fresh session, not interleaved with other tasks.

---

## 8. Open questions to resolve before starting

- **Does `apply_pipe_attrs_wrap` rely on Stage 2 vs Stage 6?** It reads from `pipe_state`, paints `ATTRS` — independent of slot grid format. ✓ Safe.
- **Does `update_cap_imm_v2` rely on a specific slot grid format?** It patches `cap_top_handler[N]_de`, `cap_bot_handler[N]_de`, etc. — the SMC operands inside the cap-handler routines, not the slot grid. ✓ Safe.
- **Does `clear_vacated_columns` care?** No — clears screen RAM cells, not slot bytes. ✓ Safe.
- **Does `patch_pipe_targets` work for the new active list?** It walks the sublist and decrements target lo-bytes with borrow into hi. Works on any 16-bit address. The sublist will point at Stage 6 IX-operand byte addresses → patch decrements those. **Verify in Phase 2** that the sublist points correctly.
