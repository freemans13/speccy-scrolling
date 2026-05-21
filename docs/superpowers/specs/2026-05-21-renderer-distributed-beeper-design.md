# Renderer-Distributed Beeper — Design

Date: 2026-05-21

## Why this supersedes the tail-slice approach

The first beeper design (`2026-05-21-beeper-sfx-design.md`) ran the sound
engine once per frame, in the idle tail. The game spends ~25,000 T-states
rendering, during which the speaker is silent — so every sustained tone is
gated on/off at 50 Hz, an inherent buzz. Heard in practice, the chime was
"awful". Raising the budget cannot fix it: the silent render gap is the cause,
not the budget.

This design distributes speaker activity across the **whole frame** so the
gap shrinks (or disappears), giving a clean sustained tone — with no stutter.

Scope: the **score sound** only. The flap stays muted until the score sound
is solved.

## Core idea

The renderer is fully T-state-deterministic. If the speaker is toggled at
points spread through the frame's code path, and those points sit at fixed
code locations, they fire at the same T-offsets every frame. The speaker
waveform then repeats exactly per frame → a *stable* pitch (not a buzz),
provided the toggle points are reasonably evenly spaced in T-states.

Perceived pitch ≈ `edges_per_frame × 25 Hz`. Pitch is selected by how many
toggle points are active. Even spacing → clean tone; uneven spacing → residual
buzz at the unevenness frequency.

## The unavoidable budget fact

A configure/build frame uses ~67k of the 70k T-state budget — only ~3k
T-states of slack. On those frames the sound necessarily thins to almost
nothing (a brief flutter). This is accepted and unchanged from the original
design. Normal frames have ~45k slack; wrap frames ~38k. Build frames are
the only tight ones, and are detectable at frame start via
`activate_pipe_idx != 255`.

## Staged delivery — prototype first

The technique's quality (how clean vs how buzzy) is genuinely unknown until
heard. Build it in stages, cheapest and most informative first.

### Stage 1 — call-distributed slices (prototype)

Reuse the existing `sfx_tick` engine **unchanged**. It already plays edges
until its budget is spent and preserves state across calls. Instead of one
call in the idle tail, call it at ~5 points across the frame:

1. in `main_loop`, after the bird ops, before `call frame_update`;
2. inside `frame_update`, immediately after `call redraw_pipes_v2`;
3. after `frame_update` returns;
4. in `main_loop`, after `update_cap_imm_v2`;
5. in `main_loop`, the existing idle-tail point.

Each call gets `total_budget / 5`, so the **total per-frame cost is
unchanged** — no new overrun risk on any frame type. `total_budget` is
classified once at the top of `main_loop`: `SND_BUDGET_CONFIG` if
`activate_pipe_idx != 255` (build frame), else `SND_BUDGET_NORMAL`.

Stage 1 fills every gap **except** the ~16k T `PIPE_PROGRAM` block, which is
one indivisible call. Driven by a single steady test tone triggered on score,
it answers two questions: how much does call-distribution reduce the buzz, and
does the remaining 16k pipe gap dominate?

### Stage 2 — instrument PIPE_PROGRAM (only if Stage 1 shows the pipe gap dominates)

`PIPE_PROGRAM` is a 160-row SMC slot grid, 32-byte row stride. Selected row
trailers get an SMC-patched `out ($fe), a` to toggle the speaker mid-render.
Patched on only while a score sound plays (~10-15 frames), patched off
otherwise → zero cost on the 99% of frames with no sound. ~13 patched rows
≈ 143 T-states added, affordable even on a configure frame. Exact row layout
and register handling to be specified when Stage 2 is reached.

### Stage 3 — the real 3-note chime

Replace the steady test tone with the 3-note ascending chime descriptor,
built on whichever mechanism (Stage 1 alone, or Stage 1 + Stage 2) proved
clean enough.

## What is reused unchanged

- `sfx_tick` engine, `sfx_next_segment`, descriptor format, sound state block.
- `sfx_trigger_chime` (triggered from `update_score`).
- The cycle-bounded budget guarantee.

## What changes

- Stage 1: budget classified at `main_loop` top; `sfx_tick` called at 5 points
  with a per-slice budget; a `sfx_tone_test` steady-tone descriptor added for
  prototyping.
- Stage 2 (conditional): `PIPE_PROGRAM` row instrumentation.
- Stage 3: real chime descriptor swapped in.

## Out of scope

- The flap sound (stays muted until the score sound is finished).
- 128K AY support.
- Background music.

## Verification

- `make` clean (`Errors: 0, warnings: 0`) at every step.
- Human runs `make run` in Fuse after each stage and reports: tone cleanliness
  (clean vs buzzy), and — via the border profiler — that no frame overruns
  into the next interrupt (no 25 Hz drop), including on configure frames.
