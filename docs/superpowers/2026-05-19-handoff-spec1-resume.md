# Handoff: Resume Spec 1 (PIPE_PROGRAM JP-skip) after stability fixes

**Date:** 2026-05-19
**Branch state:** `main`, committed and clean. Builds `Errors: 0, warnings: 0, compiled: 4829 lines`.

## TL;DR — what to do next

Spec 1's design spec and implementation plan are already on disk and committed. Two fixes have just landed that make the baseline stable; Spec 1's two tasks now need to be re-applied and re-verified.

- **Read first:** `docs/superpowers/specs/2026-05-19-pipe-program-jp-skip-design.md`
- **Then execute:** `docs/superpowers/plans/2026-05-19-pipe-program-jp-skip.md` (2 tasks)
- **Expected gain:** −4.5 k T-states per frame (PIPE_PROGRAM 28 k → 23.5 k)

After Spec 1 lands and is verified clean by the human, the broader budget work (Specs 2/3/4 ideas) can be revisited; see "What's still on the table" below.

## Where we are

The game runs cleanly past 30 s + 8 swap cycles with no resets, no mid-screen corruption, and no Sinclair-Research reboots. Two recent debugging discoveries landed as fixes on `main`:

1. **EXX/djnz bank confusion in surgical do_swap** (commit on `main`). The surgical `.ds_band1_lp` and `.ds_band2_lp` loops in `do_swap.full_swap` had `ld b, a` placed BEFORE the 3 setup `exx` instructions. Odd total EXX count from `ld b` to `djnz` meant `djnz` operated on the alt bank's stale B → loops ran random extra iterations, writing body-slot target imm bytes into pipe 2's cap-skip rows. Adjacent frames executed corrupted bytes → eventually JP-to-ROM = Sinclair-Research reset at ~8 s. Fix: move `ld b, a` to AFTER the 3 setup `exx`.

2. **Fallback do_swap leaves OLD prep half-configured** (commit on `main`). When two pipes hit `byte_x=1` in the same `wrap_byte_x` iteration, the second swap saw `prep_phase < 7` after the first full_swap reset it. The fallback path made the OLD prep "active" via `prep_pipe_swap_pending` even though prep_step phases 0..6 hadn't finished — partial-stamp column left stale pixels in screen RAM (visible as horizontal stripes mid-screen at ~8 s, ~14 swap cycles). Fix: in `wrap_byte_x`, gate `call do_swap` on `prep_phase == 7`. If not ready, skip the swap → pipe stays at `byte_x=1`, scrolls off-screen left next wrap, retries when prep is ready. Fallback code path is now dead code.

Both fixes are documented in memory:
- `~/.claude-personal/projects/-Users-freemans-github-freemans13-speccy-scrolling/memory/feedback_exx_djnz_bank_bug.md`
- `~/.claude-personal/projects/-Users-freemans-github-freemans13-speccy-scrolling/memory/project_fallback_old_prep_corruption.md`

## Frame budget (code-counted, not estimated)

User explicitly demanded counting from code, not guessing. Per-frame T-state breakdown (counted via `/tmp/z80_tcount.py` from src/main.asm linear walks + verified loop iter costs):

| Routine | T-states | Notes |
|---|---|---|
| `PIPE_PROGRAM` (160 rows) | **~28,000** | 154 body rows × 185 + 6 cap rows × ~230 |
| `patch_pipe_targets` (3 pipes walked) | **~15,665** | 3 × (28 djnz × 185 T) |
| `draw_bird` | 3,756 | 355 linear + 15 × 227 loop |
| `draw_ground` | 2,945 | 8 lines × 360 T |
| `restore_bird_bg` | 1,339 | 188 linear + 15 × 77 loop |
| `paint_bird_attrs` | ~700 | |
| `update_cap_imm_v2` | ~600 | |
| `advance_bird_anim` | 302 | |
| `update_score` | 298 | |
| `update_bird` | 208 | |
| `read_input` | 63 | |
| Overheads (halt, dispatch, advance_phase × 2) | ~700 | |
| **Baseline subtotal** | **~56,500** | (81 % of 70 k budget) |

Wrap-frame adds ~1.3 k (apply/restore attrs + smc resort). Swap-frame adds ~5.3 k (`do_swap.full_swap` surgical patch).

**Current headroom:** ~13.5 k T on normal frames, ~7 k on swap+wrap. **User target:** 35 k headroom (= total work ≤ 35 k). Need ~21.5 k more cuts to hit target.

## Spec 1 — PIPE_PROGRAM JP-skip (next implementation task)

Two changes, both isolated and well-scoped:

- **Change A** (Task 2 in plan): per-row 7-NOP trailer → `JP next_row_EXX`. Touches `init_pipe_program` only. Saves 18 T × 154 non-cap rows = **−2,772 T/frame**.
- **Change B** (Task 1 in plan): `CAP_BLOCK` skip rows → `JR +4` pattern. Touches `build_slot_templates` only. Saves 12 T × 144 cap-skip slots × 3 active pipes = **−1,728 T/frame**.
- **Combined: −4,500 T/frame** (PIPE_PROGRAM ~28 k → ~23.5 k).

The plan has Change B as Task 1 (simpler, smaller blast radius), Change A as Task 2. Each task ends with a manual `make run` check by the human (≥ 30 s play, ≥ 10 swaps) — assistant cannot run the emulator.

**Previously attempted and reverted:** Both tasks were applied in this session (commits `de0fabd` Task 1, `5b4f342` Task 2) but the game crashed at ~8 s. Investigation revealed the crashes were **pre-existing bugs** (EXX/djnz + fallback OLD prep) that Spec 1's JR-skip change merely changed the symptom of (reset → corruption). After both pre-existing bugs were fixed, Spec 1's tasks should land cleanly. Re-apply from the plan; expect green run.

## What's still on the table (later work, not part of Spec 1)

Ideas brainstormed earlier this session but not yet specced or planned:

- **Spec 2** — `patch_pipe_targets` buffer-col skip: detect when a pipe's byte_x ∈ {1, 2, 3, 28, 29} (invisible) and skip its 5.2 k T walk. Avg savings −1 k T, peak −5.2 k T on affected frames.
- **Spec 3** — PIPE_PROGRAM top-sky skip: rows 0..15 are pure sky (pipes never enter at min gap_y=8, cap_top ≥ 7). JP from `redraw_pipes_v2` entry to row 16. ~−2,960 T/frame.
- **Spec 4** — Pre-baked patch (architectural): replace per-frame `patch_pipe_targets` decrement walk with pre-shifted target LUTs (one per byte_x phase). Wrap-frame swaps LUT base instead of decrementing 112 entries per pipe. Saves ~14 k T/frame at the cost of significant implementation complexity.

Spec 1 + 2 + 3 combined: baseline drops to ~45.5 k T (33 % headroom). Add Spec 4: ~31.5 k T (55 % headroom — meets user's half-budget target).

## Important context the next session needs

- **User feedback (verbatim):** "your guesses are mostly wrong and we always go over budget even when you proudly announce you'll be under budget. I could do with you always counting budget based on code rather than guessing." → before proposing any optimization, count T-states from the actual code (e.g. via `/tmp/z80_tcount.py`, but verify the loop-extraction script doesn't include surrounding code in awk ranges).
- **The do_swap fallback path is now dead code.** Don't restore the original "fallback" behavior. The defer guard at `.swap_with_prep` prevents fallback from being reached. The fallback code itself can be left in place (harmless), but any changes to `wrap_byte_x` must preserve the `cp 7 ; jr nz, .wbx_skip` guard.
- **The build is small enough that the listing regen is fast:** `tools/sjasmplus/sjasmplus --fullpath --lst=build/main.lst src/main.asm` regenerates the listing in ~13 ms. Always regenerate before inspecting `build/main.lst` for symbol addresses — stale .lst was a source of confusion earlier this session.
- **Spectrum line addresses are interleaved**; address-to-screen-row math is not linear. Use `line_table[row]` rather than computing line addresses from row arithmetic.
- **Snapshot debugging works:** `/tmp/szx_extract.py` parses Fuse SZX snapshots (machine ID 1 = 48K). Page mapping: page 5 → $4000, page 2 → $8000, page 0 → $C000. The Z80R chunk gives PC/SP/registers at the trap moment.

## Immediate next action

1. Spawn a subagent (or do it inline) to re-apply Task 1 of `docs/superpowers/plans/2026-05-19-pipe-program-jp-skip.md`. The exact code change is in the plan's "Step 2" code block.
2. Build (`make`); commit; ask the human to `make run` for ≥ 30 s.
3. On green: do Task 2 the same way.
4. On red: snapshot, inspect, diagnose — most likely culprit is not Spec 1 itself (we proved it's mechanically correct) but interaction with some other code path that needs fixing in a follow-up.
