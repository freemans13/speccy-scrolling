# Uniform-Cost Pipe Renderer — Design

Date: 2026-05-21

## Why

The pipe renderer is fast on average but **spiky**. Per-frame cost swings from
~25k T-states (normal) to ~32k+ (wrap) to ~67k (configure/recycle). The spikes
come from one root cause: the SMC slot grid bakes screen geometry into the
instruction stream, so when geometry changes the baked values must be
re-synced — and that re-sync is dumped into a single frame.

Two spikes result:

- **The 4-frame wrap spike** — `patch_pipe_targets` re-syncs ~336 baked screen
  addresses each time `byte_x` steps one byte.
- **The ~40-frame recycle spike** — `do_swap` (~14k T rewriting a pipe's whole
  slot column) plus the amortised column rebuild, on the ~67k configure frames.

The spikes leave no consistent T-state headroom — which is why the beeper
sound has nowhere to live on wrap/build frames. They also concentrate in the
most bug-prone code in the project (the auto-memory records ~6 distinct
historical bugs in the `do_swap` / `configure` / active-list machinery).

The SMC grid and amortisation are sound techniques and stay. What changes is
that the re-sync work becomes **uniform per frame** instead of spiky.

## Goal

Every frame costs roughly the same — no spikes — so headroom is consistent.
Target: a flat ~44–46k T-states/frame, peak well under the 70k ceiling.

## Architecture — double-buffered grid with a rolling rebuild

### Two grids

There are **two identical slot grids**, A and B, each 160 rows × 32-byte
stride (5120 bytes). At any moment one is **live** (rendered this frame) and
one is **shadow** (being rebuilt for the next byte position). Two pointers,
`live_grid` and `shadow_grid`, track which is which. Each grid's row JP-trailers
point within its own rows.

### Render

`redraw_pipes_v2` is unchanged in spirit — it jumps into `live_grid` instead
of a fixed `$DB00` address. ~16k T-states, as today. The phase / pre-shifted
sub-byte mechanism is untouched and orthogonal to this redesign.

### Rolling rebuild

Each frame rebuilds **one pipe's entire slot column** into the shadow grid.
With 4 pipe columns and a 4-frame byte window, every column is refreshed once
per window on a rolling cursor.

A column rebuild is **band-structured** — no per-row `cp` dispatch. For the
pipe's `gap_y`, it stamps:

1. body slots for rows `[0 .. cap_top_row − 1]`
2. the cap-top slot at `cap_top_row`
3. skip slots through the gap
4. the cap-bot slot at `cap_bot_row`
5. body slots for rows `[cap_bot_row + 1 .. 159]`

Each band is a stamp-from-template loop writing the 6-byte slot plus the
target address derived from the pipe's shadow `byte_x`. A full 160-row column
rebuild costs ~18–20k T-states (the same work the old `prep_step` spread over
many frames); done once per frame this is affordable — see Cost budget below.

Because a full column is rebuilt every time, the rebuild does not care whether
a pipe just scrolled one byte or just recycled to `byte_x = 29` with a new
`gap_y` — it stamps whatever the current geometry says. **Recycle costs
exactly the same as scrolling.**

### Swap

On a byte-boundary crossing (the old "wrap"), the `live_grid` and
`shadow_grid` pointers are exchanged and each pipe's shadow `byte_x` is
recomputed — decrement, or recycle to 29 with a fresh `gap_y`. That is the
entire wrap-frame grid cost now: two pointer swaps and a few byte updates. The
~11k T `patch_pipe_targets` spike is gone.

The 4-frame byte window and the 4-frame rebuild cycle are the same length by
design: the shadow finishes rebuilding for window V−1 exactly as window V ends.

## What this removes

Recycle is absorbed into the uniform rebuild, so an entire layer of machinery
becomes unnecessary and is deleted:

- `do_swap` and its `write_jrskip_column`
- `prep_step` and its 7 phases
- `configure_pipe_slots`
- the active list (`ACTIVE_PIPE_0..3`) and `patch_pipe_targets`
- the JR-skip prep column
- `SLOT_ADDR_TABLE` — the rebuild computes a row offset as
  `grid_base + row * 32` directly

The 4th "preparing" pipe most likely collapses into being an ordinary pipe:
there is no longer a build deadline to prepare against. (Confirmed during
implementation.)

## Memory

A second 5120-byte grid is required. Deleting `SLOT_ADDR_TABLE` (~1.3KB) and
the active lists (~0.9KB) reclaims ~2.2KB; the remainder comes from a
memory-map reshuffle. Exact addresses are assigned in the implementation plan.

## Cost budget

| Component | T-states/frame |
|---|---|
| Render `live_grid` | ~16k |
| Rolling rebuild (1 pipe column) | ~18–20k |
| Bird / ground / score | ~10k |
| **Total, every frame** | **~44–46k, flat** |

Peak frame cost drops from ~67k to ~45k. A full from-geometry column rebuild
genuinely costs ~18–20k T (this is why the old `prep_step` amortised the build
over many frames); doing one whole column per frame is affordable because the
flat ~45k frame still leaves ~25k T of headroom under the 70k ceiling — enough
for a uniform beeper-sound budget. Every routine is still T-state counted per
the project discipline and verified with the border profiler.

## Open detail — cap handlers

Cap rows currently `JP` to shared cap handlers that carry byte-position imms.
With two grids representing two byte windows, the cap state must be
per-grid. The exact form — per-grid cap-handler instances, or folding cap
position into the grid slots — is resolved in the implementation plan. It does
not affect the architecture above.

## Payoff for sound

With every frame flat at ~45k there is ~25k T-states of headroom on **every**
frame. The beeper sound budget becomes uniform — no wrap/build flutter — and
the muted flap effect can be re-enabled. The sound work, currently parked, is
fully unblocked by this redesign.

## Risk and staging

This replaces the core renderer — the highest-risk change in the project. The
implementation plan must:

- stage the work so the build stays runnable between stages;
- validate each stage with the border profiler (uniform band heights, no frame
  crossing into the next interrupt);
- treat the cap-handler detail as its own resolved sub-step;
- keep the existing renderer until the new one is proven, if feasible.

## Verification

- `make` clean (`Errors: 0, warnings: 0`) at every step.
- Border profiler: every frame's bands are the same height — no spike, no
  frame overrunning into the next `halt` — across normal, wrap and recycle
  moments.
- Visual: pipes scroll smoothly at 50 Hz with no tearing or positional jump,
  including across a recycle.

## Out of scope

- The beeper sound work itself (resumes, with uniform budgets, after this).
- The phase / pre-shifted sub-byte rendering mechanism (unchanged).
- Bird, ground, and scoreboard rendering (unchanged).
- 128K-specific features.
