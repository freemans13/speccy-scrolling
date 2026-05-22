# Char-Cell-Banded Pipe Renderer — Design

**Status:** design / approved-for-planning
**Supersedes:** the Approach-2 double-buffered renderer (`2026-05-21-uniform-cost-pipe-renderer-design.md`), which is abandoned — see "Why the double buffer is dropped".

## Goal

Free per-frame T-state headroom (target: every frame comfortably under 70k, no
spike, ~12k+ idle on the worst frame) **without changing the visual** — 3
pixel-dithered pipes scrolling pixel-smooth at 50 Hz, plus bird, ground,
scoreboard. The headroom is for future sprites/effects.

The game already rendered this correctly; it just used the whole budget, with
the **wrap frame at ~70k (zero spare)** — the ~18k scroll-patch spike. This
design removes that spike.

## The core idea — char-cell bands

The ZX screen address of 8 vertically-consecutive pixel rows **within one
character cell** differ only in the high byte:

```
line_table[Y+0..Y+7]  =  base, base+256, base+512, … base+1792
```

So a pipe's 160-row column splits into **20 bands of 8 rows**, and each band's
8 stamp targets share a base — the row offset is just `+256` per row, i.e.
`inc` of the address high byte.

Render a body band with **IX as a running target pointer**:

```
        ld   ix, band_base          ; ONE 16-bit immediate per band
        ld   sp, ix  /  push … push  /  inc ixh    ; ×8 rows
```

`ld sp,ix` (10T) reloads SP each row; `inc ixh` (8T, undocumented but solid on
the Speccy Z80) walks to the next row. **The whole band carries a single base
immediate.**

### Why this wins

Today every body row has its own 16-bit `ld sp,target` immediate, so scrolling
patches **~110 targets per pipe (~330 total ≈ 18k T)** — the wrap spike. With
banding, scrolling decrements **one base per band: 20 per pipe, ~60 total ≈
~3k T**. The wrap-frame scroll spike collapses from ~18k to ~3k.

Because the patch is now tiny, the **double buffer is unnecessary** — ~3k of
patching is done as a single-grid post-render chunk on the wrap frame, no
tearing (the grid code is free between its execute and the next frame's
execute). The entire leapfrog/shadow-grid/boot/clone apparatus is deleted.

## The slot format

A body row stamps a **4-byte** pipe bitmap (no per-slot trailing-zero — see
"Trailing clear" below). The A/B dither bitmaps differ only in bytes 2–3, so:

- `BC` = bitmap bytes 0,1 (shared by A and B)
- `DE` = bitmap bytes 2,3 of variant **A**
- `HL` = bitmap bytes 2,3 of variant **B**

(`HL` is free because there is no trailing-zero push.) `redraw_pipes_v2` loads
these three pairs once per frame from the pre-shifted bitmap for the current
phase.

```
A-row:   ld sp,ix : push de : push bc : inc ixh      ; 40 T
B-row:   ld sp,ix : push hl : push bc : inc ixh      ; 40 T
```

The dither alternates by pushing `DE` vs `HL` — **no `EXX` anywhere** (the
current per-row `EXX` is removed). Band K's first row is row 8K (even) → every
band starts on an A-row, so a band is `[A][B][A][B][A][B][A][B]`.

Per-row cost ~40T vs the current ~43T + EXX share — the render is also slightly
cheaper, but the scroll patch is the real prize.

## Grid layout — band-interleaved

`PIPE_PROGRAM` is a single SMC-emitted routine, executed once per frame via
`call`. It is ordered **band-interleaved** so it tracks the raster:

```
P0.band0  P1.band0  P2.band0  P3.band0
P0.band1  P1.band1  P2.band1  P3.band1
…
P0.band19 P1.band19 P2.band19 P3.band19
ret-epilogue
```

A band-group (4 pipes × 8 rows) renders in ~1.5k T; the beam scans 8 rows in
~1.8k T, so the render gains on the beam and never tears (verified by reasoning;
**confirm empirically with the border profiler during implementation**).

Each pipe-band is one of three kinds:
- **body band** — `ld ix,base` + 8 IX-walk rows (~52 bytes).
- **skip band** — the pipe's gap; renders nothing. A single `jr`/short stub.
- **cap-edge band** — 7 body rows + 1 cap row (see "Caps").

Grid size ≈ 80 bands × ~50 bytes ≈ ~4 KB (one grid, vs the old 2×5 KB).

## Caps

`gap_y ∈ {8,16,…,96}` (multiple of 8), and `PIPE_GAP = 48` (multiple of 8), so:
- `cap_top_row = gap_y−1` → always the **last** row of a band.
- `cap_bot_row = gap_y+48` → always the **first** row of a band.

Each cap therefore sits on a band edge: exactly **2 mixed bands per pipe**
(7 body rows + 1 cap row), 6 pure skip bands, 12 pure body bands.

A cap row is stamped inside its band using the band's IX position (the cap is
the band's row 0 or row 7, so IX already addresses it). The cap's phase-shifted
bitmap is supplied per frame by an `update_cap_*` routine writing SMC imms, as
today. **The mixed band still carries just one base immediate** — the cap row
shares the band's IX walk; only the pushed *data* differs. So the 60-base
scroll-patch count holds. (Exact register handling for the cap row — it needs
the cap bitmap, which would clobber the body A/B pairs — is an implementation
detail: resolve against the current cap-handler code. Likely a tiny per-cap
handler entered from the band, using `ld sp,ix`.)

## Scroll

`pipe_state` holds `byte_x` per pipe. On the wrap (every 4 frames, `byte_x`
decremented), patch the **band bases**: for each active pipe, decrement its 20
`ld ix,base` operands by 1 (with borrow into the high byte). ~60 decrements
≈ ~3k T, done on the wrap frame after the grid has executed. Single grid; no
shadow, no spreading.

## Trailing clear

The per-slot trailing-zero (which cleared the column a pipe vacated) is removed
— it is only genuinely needed once per byte-step, not every frame. On the wrap,
a small pass clears the single column each active pipe vacated, all 160 rows
(~2.6k T, stack-blast of zeros). This runs on the wrap frame alongside the
scroll patch.

## Recycle

The 3+1 model is kept (3 visible pipes + 1 parked at `byte_x=29`, invisible).
When a pipe parks it gets a new `gap_y`; its 20 bands must be re-stamped
(body/skip/cap pattern shifts). This is amortised over the parked lead-time
(~a few bands per frame), as the current `rc_step` does — but band-granular and
into the single grid, so far simpler (no two-grid sync, no `boot`, no clone).
The parked pipe's bands are JR-skip while parked (cheap) until rebuilt.

## Why the double buffer is dropped

Approach 2 spread the scroll patch across frames via a shadow grid, but the
shadow must be patched **−2 per window** (it leapfrogs the live grid) — *twice*
the work, ~10–13k T *every* frame. It raised every frame to the old spike
level. Banding makes the patch so cheap (~3k, once per 4 frames) that spreading
is pointless. Delete: `GRID_B`, `patch_shadow_step`, `boot_step`,
`clone_grid_a_to_b`, the grid-swap SMC, `shadow_grid`, `first_window`, and the
two-grid `do_swap`/`rc_*` plumbing.

## Expected per-frame budget (rough estimates — MEASURE to confirm)

All figures below are estimates; the project rule is measure-don't-estimate, so
treat them as direction, not commitment. The renderer's *structure* is the
deliverable; the border profiler decides the numbers at each stage.

| | calm frame | wrap frame |
|---|---|---|
| pipe grid render | ~28–30k | ~28–30k |
| bird + ground + score | ~11k | ~11k |
| caps / bookkeeping | ~5k | ~5k |
| scroll patch (band bases) | — | ~3k |
| trailing clear | — | ~2.6k |
| **rough total** | **~44–46k** | **~50–52k** |
| **rough idle** | **~24–26k** | **~18–20k** |

The point is not the exact figures — it is that the **~18k wrap spike is
replaced by ~6k of wrap-only work**, so the wrap frame stops being the limiter
and every frame keeps real headroom.

Pipe attribute updates (`apply/restore_pipe_attrs`) remain a wrap-frame cost and
are **out of scope** here — a candidate for a later pass if still more headroom
is wanted.

## Risks / verify during implementation

- **Race-the-beam** — confirm with the border profiler that band-interleave
  never lets the render fall behind the beam (reasoning says ~0.3k/group of
  margin; measure it).
- **`inc ixh`** — undocumented; assemble and run-test early.
- **Cap-row register juggling** — the cap row needs the cap bitmap without
  losing the body A/B pairs for the rest of its band; prototype this first.
- **Estimates** — all T-state figures above are estimates. Per project rule,
  measure with the border profiler at each stage; the design's *structure* is
  the commitment, not the numbers.

## Out of scope

Pipe attribute scrolling, the beeper sound budget (re-tune once the renderer's
real headroom is measured), and any visual change.
