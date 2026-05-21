# Beeper Sound Effects — Design

Date: 2026-05-21

## Goal

Add two sound effects to Speccy Flappy Bird using the stock 48K ZX Spectrum
beeper:

- **Flap** — a short noise "fwip" when SPACE is pressed and a flap is accepted.
- **Score** — a rising chime when the score increments.

The beeper *is* the CPU on a 48K Spectrum, so sound generation steals
T-states from rendering. The game runs at 50 Hz with a hard 70,000 T per-frame
budget and is already CPU-saturated. **No sound effect may ever cause a missed
`halt` (a drop to 25 Hz).** This is the overriding constraint.

## Architecture — cycle-counted frame-sliced beeper

Sound is generated as a **frame-end idle tick**. All rendering and state prep
in `main_loop` completes first; whatever idle T-states remain before the next
interrupt belong to sound.

- The tick is inserted in `main_loop` at `.post_prep_step` (around line 150 of
  `src/main.asm`), before `ei` / `halt`. It runs under the existing `di`.
- If `sound_active == 0`, the tick is skipped and `main_loop` behaves as today.

A sound effect spans many frames. Each tick consumes a bounded slice of the
effect and advances persistent sound state. The speaker is silent during
`frame_update` (the gap between slices), producing an inherent ~50 Hz
amplitude modulation — this is expected and acceptable.

### The "never overrun" guarantee — edge-budget bounding

The engine generates **at most `sound_budget` speaker edges per frame**. Each
edge costs `edge_overhead + half_period` T-states, where `half_period` is
capped at `MAX_HALF_PERIOD`. Therefore:

```
worst-case slice cost = sound_budget × (edge_overhead + MAX_HALF_PERIOD)
```

This is a fixed, known number. `sound_budget` is chosen per frame type so the
worst-case slice always fits in that frame's idle time with a safety margin.

The tone's **pitch is always exact** — each edge's `half_period` delay is
cycle-counted regardless of frame type. Only the *quantity* of continuous tone
per frame varies: a normal frame yields a long slice, the rare configure frame
a short one (a brief 50 Hz flutter in the tone), but never an overrun.

A low-pitched effect may exhaust the available time before using all its edge
budget — that simply leaves idle T unused (silence), which is harmless. The
budget bounds overrun only.

### No clicks

At a slice boundary the engine **stops** — it never snaps the speaker bit to
0. The membrane holds a silent DC level during `frame_update`, and toggling
resumes from the same bit on the next frame. When an effect ends, the speaker
bit is left where it is.

## Sound state

A small RAM block (~12 bytes), persistent across frames:

| Field | Purpose |
|---|---|
| `sound_active` | 0 = idle, 1 = an effect is playing |
| `sound_id` | 0 = flap, 1 = chime |
| `sound_seg` | current segment index into the descriptor |
| `sound_edges_left` | edges remaining in the current segment |
| `sound_speaker_bit` | current speaker output bit (0 or $10) |
| `sound_half_period` | current edge half-period (T-state delay units) |
| `sound_sweep_acc` | sweep accumulator (noise clock-rate sweep) |
| `sound_lfsr` | 15-bit LFSR state for noise |

`sound_budget` is a separate per-frame value set by `main_loop` (see below).

## The two effects

Each effect is a flat **descriptor table** of segments. A segment is
`{ mode, half_period, edge_count, sweep_delta }`:

- `mode` — tone (fixed half-period square wave) or noise (LFSR-driven bit).
- `half_period` — edge delay; for noise, the LFSR clock interval.
- `edge_count` — how many edges this segment lasts.
- `sweep_delta` — added to `half_period` per edge (0 = steady).

The engine walks the table; when segments are exhausted, `sound_active → 0`.

### Flap "fwip"

A noise burst, roughly 4 frames total. A 15-bit LFSR
(`bit0 XOR bit1 → shifted in`) is clocked once per edge; its output bit drives
the speaker. Across ~3 segments the noise clock rate sweeps **downward**
(`half_period` grows via `sweep_delta`), so the burst darkens as it fades — an
airy "fwip" rather than static hiss. Hard cutoff at the end.

### Score rising chime

Three pure square-wave tones, **ascending** (a root–third–fifth feel), ~4-5
frames each, with the final note held slightly longer. Total ~13-15 frames.
Each segment is a tone with a fixed `half_period`; the engine reloads
`half_period` at each segment boundary.

No envelope/decay in v1 — three clean ascending tones read clearly as a
reward and keep the code tight. Pulse-width decay can be added later if the
tones sound flat; it is explicitly out of scope here (YAGNI).

## Triggers & priority

The beeper is 1-bit: one effect at a time. Triggers are cheap (a few
T-states) — they only set state; all generation happens in the idle tick.

- **Flap** — in `read_input` (line 3418), when a flap is accepted, call
  `sfx_trigger_flap`. Logic: if a chime is currently active (`sound_active`
  and `sound_id == 1`), ignore the trigger; otherwise (re)start the flap from
  segment 0. A flap mid-flap retriggers cleanly; a flap mid-chime is dropped.
- **Score** — in `update_score` (line 3275), when `score` is incremented,
  call `sfx_trigger_chime` — starts the chime unconditionally, interrupting
  any flap.

Priority model in full: **chime beats flap**. State is `sound_active` +
`sound_id`.

## Frame-type budget

`sound_budget` (an edge count) is set each frame by `main_loop`'s existing
frame classification, from three calibrated constants:

| Constant | Frame type | Approx idle target |
|---|---|---|
| `SND_EDGES_NORMAL` | normal frame | ~36-40k T of the ~45k idle |
| `SND_EDGES_WRAP` | wrap frame | medium |
| `SND_EDGES_CONFIG` | swap frame / column build in progress (`activate_pipe_idx != 255`) | ~3k T |

Each constant is derived from the **measured worst-case** cost of that frame
type plus a safety margin, using the border profiler. **These constants are
recalibration-sensitive:** if per-frame render costs change, they must be
re-checked, or a sound slice could overrun. The spec and the implementation
must both call this out.

`main_loop` already branches on `do_swap_fired` and `activate_pipe_idx`; the
budget assignment folds into those existing branches. When multiple
classifications could apply, the smaller budget wins.

## Profiling

The engine's output byte is `SOUND_BORDER | sound_speaker_bit` — toggling
bit 4 (speaker) does not disturb the visible border. The idle/sound region
therefore shows as its own solid profile-colour band. The no-overrun
guarantee is verified visually: the sound band must always end before the
next RED top-blanking band, including during a configure frame.

## Memory layout

- New sound module: ~150-250 bytes of code, placed near `read_input` / the
  score routines.
- Two descriptor tables (flap, chime): small, in the data area.
- Sound-state block: ~12 bytes.
- Exact addresses are assigned in the implementation plan to fit the
  hand-laid memory map; recompute any affected EQU constants.

## Build & test

- `make` from project root must report `Errors: 0, warnings: 0`.
- Functional verification is performed by the human in Fuse (the assistant
  cannot run the emulator):
  - Flap produces the noise "fwip"; score produces the rising chime.
  - A flap during a chime is silent (chime continues); a chime interrupts a
    flap.
  - Border profiling confirms the sound band never crosses into the next
    frame — no 25 Hz drop — including on a configure frame.

## Out of scope

- Background music.
- Pulse-width / amplitude envelopes (decay).
- Any 128K AY chip support — 48K beeper only.
- Multi-channel beeper (simultaneous tones).
