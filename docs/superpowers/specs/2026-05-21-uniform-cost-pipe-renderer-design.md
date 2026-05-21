# Uniform-Cost Pipe Renderer — Design

Date: 2026-05-21

## Revision note — Approach 1 superseded by Approach 2

This spec originally specified **Approach 1**: each frame, fully rebuild one
pipe's whole 160-row slot column into a shadow grid. Stages 1–3 of that plan
were built; Stage 4 then measured the reality on hardware:

- A full from-geometry column rebuild costs **~30k T-states**.
- A *normal* frame has only **~28k T-states of spare time** (measured: ~40% of
  the frame is idle).
- *Wrap* frames are already **fully saturated** (~0 spare — `patch_pipe_targets`
  alone consumes ~28k there).

So Approach 1 — one full rebuild per frame — cannot fit: 30k > 28k even on a
good frame, and there is no room at all on a wrap frame. Four columns must be
refreshed per 4-frame byte window, which forces one full column per frame;
that total cost is irreducible *if every column is fully rebuilt every window*.

**Approach 2** (this revision) fixes that: only a *recycling* column needs a
full rebuild — a *scrolling* column changes only in its baked target
addresses, which is cheap to re-sync and, crucially, can be **spread** across
the 4-frame window. Stages 1–3 and the `rebuild_column` routine carry over
unchanged; only the per-frame strategy changes.

## Why

The pipe renderer is fast on average but **spiky**. The SMC slot grid bakes
screen geometry into the instruction stream, so when geometry changes the
baked values must be re-synced — and that re-sync is dumped into a single
frame:

- **The 4-frame wrap spike** — `patch_pipe_targets` re-syncs the baked screen
  addresses (~28k T, measured) every time `byte_x` steps one byte. A wrap
  frame is fully saturated.
- **The ~40-frame recycle spike** — `do_swap` + the amortised `prep_step`
  build, on the heavy configure frames.

The spikes leave no consistent headroom — which is why the beeper sound has
nowhere to live on wrap/build frames.

## Goal

Every frame costs roughly the same — no spikes — so headroom is consistent.
Target: a flat ~46–48k T-states/frame, ~22k uniform headroom under the 70k
ceiling.

## Architecture — double-buffered grid, spread re-sync

### Two grids

Two identical slot grids, `GRID_A` and `GRID_B` (160 rows × 32-byte stride,
5120 bytes each). One is **live** (rendered this frame); one is **shadow**
(being prepared for the next byte position). The live grid is the operand of
the `grid_call` instruction in `redraw_pipes_v2`, SMC-patched on each swap; a
`shadow_grid` word tracks the other. Each grid's row JP-trailers point within
its own rows.

### Render

`redraw_pipes_v2` renders the live grid via the SMC-patched `grid_call` —
~16k T, unchanged. The phase / pre-shifted sub-byte mechanism is untouched.

### Per-frame shadow maintenance — the spread re-sync

Between consecutive byte windows, a **scrolling** pipe's column changes *only*
in its target-immediate addresses (each `ld sp,target` imm shifts by a fixed
delta). The opcodes, EXX bytes, JP-trailers, cap slots and skip slots are
identical. So preparing the shadow for the next window is just **patching the
target imms** — the same work `patch_pipe_targets` already does, walking the
active list.

Because the shadow grid is not being rendered, that patch can be **spread
across the 4 frames of a byte window** with no visual inconsistency: each
frame, patch ~¼ of the active columns' target imms in the shadow toward the
next `byte_x`. ~3k T/frame, uniform — replacing the ~28k single-frame spike.

### Swap

On a byte-boundary crossing (the old "wrap"): the shadow — now fully
re-synced for the new byte position — becomes live (SMC-patch the `grid_call`
operand); the old live becomes the new shadow, to be re-synced toward the
following window. The wrap frame's grid cost collapses to a pointer swap.

The 4-frame byte window and the 4-frame spread cycle are the same length by
design.

### Recycle — the one full rebuild, amortised

When a pipe scrolls off the left and re-enters at the right with a new
`gap_y`, its column genuinely changes shape (new cap-row positions) — an imm
shift is not enough; it needs a **full column rebuild**. This is exactly what
the `rebuild_column` routine (built in Stage 4) does.

A recycled column must be rebuilt in **both** grids (each represents a byte
position). The recycling pipe re-enters invisibly (buffer column) and has a
long lead time before it is visible, so the two full rebuilds (~30k each) are
**amortised** — a bounded slice per frame (~1–2k T/frame) — over that lead
time. This replaces the `do_swap` + `prep_step` configure spike.

## What changes vs. what is kept

Approach 2 is a **restructuring**, not a wholesale deletion:

- **Kept (re-targeted):** the `patch_pipe_targets` logic and the active list —
  now run incrementally (¼/frame) against the *shadow* grid instead of
  all-at-once against the live grid on the wrap frame.
- **Kept (re-targeted & amortised):** the recycle column build (`prep_step` /
  `rebuild_column`) — now feeds the *shadow* grid and is amortised over the
  recycling pipe's lead time.
- **Changed:** `do_swap` — the swap becomes the grid-pointer exchange plus
  kicking off the recycled column's amortised rebuild.
- **Removed:** the JR-skip prep column (the recycling column is built directly
  now); any machinery made redundant by the above (assessed during
  implementation).

The spikes are eliminated; the fragile machinery is reduced but not all
deleted (this is the cost of Approach 2 fitting the hardware where Approach 1
did not).

## Memory

Two 5120-byte grids. `GRID_A` is the existing grid (`$DB00`); `GRID_B` is at
`$AC00` (reserved in Stage 2). No further reshuffle needed.

## Cost budget

| Component | T-states/frame |
|---|---|
| Render `live_grid` | ~16k |
| Bird / ground / score / cap | ~26k (measured: the current ~60%-of-frame work minus render) |
| Spread imm re-sync (¼ of the patch) | ~3k |
| Amortised recycle rebuild | ~1–2k |
| **Total, every frame** | **~46–48k, flat** |

Peak frame cost drops from ~70k (saturated wrap frame) to ~47k flat, leaving
~22k T uniform headroom — enough for a uniform beeper-sound budget. Every
routine is still T-state counted and verified with the border profiler.

## Open detail — cap handlers

Cap rows `JP` to shared cap handlers carrying byte-position imms. With two
grids representing two byte windows, the cap state must be per-grid. The exact
form — per-grid cap-handler instances, or folding cap position into the grid
slots — is resolved in the implementation plan.

## Payoff for sound

With every frame flat at ~47k there is ~22k T of headroom on **every** frame.
The beeper sound budget becomes uniform — no wrap/build flutter — and the
muted flap effect is re-enabled. The sound work, currently parked, is unblocked.

## Risk and staging

This restructures the core renderer. The implementation plan must:

- stage the work so the build stays runnable between stages;
- validate each stage with the border profiler (uniform band heights, no frame
  crossing into the next `halt`) — and, given how wrong the pre-measurement
  estimates were, **measure** rather than estimate at each checkpoint;
- treat the cap-handler detail as its own resolved sub-step.

## Verification

- `make` clean (`Errors: 0, warnings: 0`) at every step.
- Border profiler: every frame's bands are the same height — no spike, no
  frame overrunning into the next `halt` — across normal, wrap and recycle.
- Visual: pipes scroll smoothly at 50 Hz with no tearing or positional jump,
  including across a recycle.

## Out of scope

- The beeper sound work itself (resumes, with uniform budgets, after this).
- The phase / pre-shifted sub-byte rendering mechanism (unchanged).
- Bird, ground, and scoreboard rendering (unchanged).
- 128K-specific features.
