# 2026-05-18 — Flicker / tearing / halt-miss fix

## Problem

Three connected defects visible in the current build:

1. **Bird flickers when at the top of the screen.** Bird ops run in CYAN
   (end of frame). For a bird at low Y, the raster has already scanned the
   bird's rows by the time draw_bird writes them → the writes only become
   visible next frame. At higher Y, the writes land before raster reaches
   those rows → 0-frame lag. The lag boundary moves with Y, so a bird
   crossing through the boundary appears to stutter.

2. **Pipes tear in the top ~1/3 of screen on deferred-clear frames.**
   When `do_deferred_clears` (~11 k T) consumes top blanking, PIPE_PROGRAM
   starts too late and is behind the raster on the first ~20 rows →
   raster reads stale pixels before PIPE_PROGRAM stamps them.

3. **Chunks of pipes occasionally vanish for one frame.** Almost certainly
   a halt miss on the configure frame: the recycle frame's budget
   (frame_update + configure ≈ 60 k T) leaves only ~10 k T margin, and
   any data-dependent variance can push it over the 70 k T halt budget.
   The bird also flickers harder around these moments.

All three share a root cause: timing is too sensitive to which kind of
frame we're in.

## Goal

Every frame, in 70 k T, with no race-the-beam tearing, no asymmetric bird
lag, and no halt-miss spike on recycle.

## Approach

Three changes, applied together:

### 1. Extra-empty-byte pipe stamp (replaces deferred-clear)

Each pipe slot grows from 5 bytes to 6 bytes:

```
old: 31 lo hi D5 C5         ; ld sp,target ; push de ; push bc
new: 31 lo hi E5 D5 C5      ; ld sp,target ; push hl ; push de ; push bc   (HL = 0)
```

Target shifts to `line_addr[row] + byte_x + 5`. The three pushes write 6
bytes at cols `byte_x-1 .. byte_x+4`:

- `byte_x-1 .. byte_x+2`: L, M1, M2, R (the existing 4-byte body)
- `byte_x+3, byte_x+4`: two trailing zeros

As `byte_x` decrements each wrap, the trailing zeros naturally clear the
column that was previously the pipe's right edge. Every column at every
body row gets visited by a trailing zero exactly twice as the pipe
scrolls past, so by the time the pipe recycles, the row is fully clean
except for the buffer cols (which are invisible anyway).

This **eliminates the entire deferred-clear mechanism**:

- `do_deferred_clears`, `clear_pending`, `clear_pipe_col`, `paint_restore`
  routines and state — gone.
- `gap_clear_pending`, `gap_clear_pipe_idx`, `run_gap_clear` — also gone.
  With every-frame trailing-zero, there's no accumulated stale pixel
  problem when a row transitions from body to gap on recycle.
- `wrap_byte_x` no longer sets `clear_pending`.
- Configure no longer queues gap_clear.

**Wraparound safety at byte_x=29:** writes at cols `byte_x-1..byte_x+4`
= cols 28..33. Cols 32 and 33 map to "col 0, col 1 of a different
scanline within the same 8 KB band" via Spectrum screen address
arithmetic. Those are buffer cols (hidden by ATTR_BUFFER). Safe.

### 2. Bird ops in top blanking (replaces CYAN bird ops)

With `do_deferred_clears` gone, top blanking (T = 0 .. ~14 k) is empty.
Bird ops (~5.5 k T) move there, before PIPE_PROGRAM:

```
main_loop:
    halt → di → RED
    bird ops (5.5 k)            ← TOP BLANKING
    frame_update:
        redraw_pipes_v2 (PIPE_PROGRAM, ~25 k T)
        update_score, draw_ground, render_score
    WHITE → do_white_work
    CYAN → update_cap_imm_v2 → prep_step_for_next_pipe
    ei → jr main_loop
```

All bird writes complete before raster reaches row 0. Uniform 0-frame
lag at every Y → no flicker. PIPE_PROGRAM still has T ≈ 5.6 k of head
start over the raster (raster reaches row 0 at T = 14 k), more than
enough.

### 3. 4-pipe architecture (replaces recycle spike)

`pipe_state` grows from 3 entries to 4: at any moment, 3 pipes are
**active** (drawing on-screen), and the 4th is **preparing** (its slot
column is being filled in incrementally; its slot targets point at ROM
so the writes are silently ignored).

PIPE_PROGRAM has **4 slot columns per row** instead of 3:

```
Row R bytes (25 per row):
    [EXX]  [slot 0: 6B]  [slot 1: 6B]  [slot 2: 6B]  [slot 3: 6B]
```

Each frame, the dispatcher does ~270 T of prep work on the preparing
pipe — stamping body/cap_block bytes, patching handler imms, building
its active sublist. Over ~112 frames (one full byte_x cycle of an
active pipe), the prep completes well before the next swap.

**Swap event:** when an active pipe reaches `byte_x = 1`, that pipe's
slot column becomes the new "preparing" slot (start a fresh prep cycle
with a new random gap_y). The previously preparing pipe — already fully
configured — becomes the new active pipe and starts scrolling from
`byte_x = 29`. The swap is logical (update an index in pipe_state); no
memory move needed.

The "spike" of configure work disappears: it's been amortized into ~270
T/frame across all frames. Every frame has the same cost shape.

## Architecture

### Memory layout changes

| Symbol | Old | New |
|---|---|---|
| `pipe_state` | 6 bytes (3 × {byte_x, gap_y}) | 8 bytes (4 × {byte_x, gap_y}) |
| `SLOT_GRID_BASE` | `$DB00` | `$DB00` |
| Row stride | 16 bytes (1 EXX + 3 × 5) | 25 bytes (1 EXX + 4 × 6) — pad to 32 for fast `row × 32` indexing |
| `SLOT_GRID_END` | `$E500` (160 × 16) | `$E300` (160 × 32, ends at `$DB00 + 5120`) |
| `ACTIVE_PIPE_N` (per-pipe sublists) | 3 × 224 B at `$FA40..$FCDF` | 4 × 224 B (= 896 B), moved to `$F900..$FC7F` |
| `SLOT_ADDR_TABLE` | 480 × 2 B (160 rows × 3 pipes) | 640 × 2 B (160 × 4) at `$F440..$F93F` |
| Cap handlers | 6 (3 pipes × {top, bot}) | 8 (4 pipes × {top, bot}) |
| Cap handler imm-address tables | 3-entry | 4-entry |

Stride 32 instead of 25 (a 22 % waste of slot grid space) so the
per-row address calculation stays a fast left-shift: `row × 32 = row << 5`.

### New state

```asm
prep_pipe_idx:    db 3              ; which slot column is currently preparing (0..3)
prep_progress:    dw 0              ; cursor into the prep state machine
prep_pending_y:   db 0              ; new gap_y chosen for the preparing pipe
ACTIVE_LIST_NEW:  equ $F900         ; 4 × 224 bytes, contiguous, walked by patch_pipe_targets
ACTIVE_COUNT_NEW: equ 4 * 112       ; 448
```

`prep_pipe_idx` rotates 0 → 1 → 2 → 3 → 0 → … as pipes swap roles.

### Prep state machine

Each frame in CYAN, after `update_cap_imm_v2`, call `prep_step`. It
dispatches based on `prep_progress` to do a small chunk of work:

| Phase (cursor range) | Work |
|---|---|
| 0..N1 | Stamp BODY_TEMPLATE for rows `[0..cap_top-1]` of the preparing pipe (each frame: ~3 rows = ~250 T) |
| N1..N2 | Stamp CAP_BLOCK at rows `[cap_top..cap_bot]` (~3 rows/frame) |
| N2..N3 | Stamp BODY_TEMPLATE for rows `[cap_bot+1..159]` (~3 rows/frame) |
| N3 | Patch cap-handler addresses (Step 3, ~100 T, one frame) |
| N3+1 | Patch cap target imms (Step 4, ~150 T, one frame) |
| N3+2 | Patch cap _next imms (Step 5, ~200 T, one frame) |
| N3+3..N4 | Build active sublist (~4 entries/frame) |
| N4 | Done — wait for swap |

Total chunks: ~112 frames worth of work, paced so it always finishes
before the next swap. If it lags (e.g., a pipe scrolls faster than
expected), the swap waits until prep completes. Realistically this
won't happen.

`prep_step` itself is ~270 T/frame average.

### Swap logic

At end of `wrap_byte_x`, when a pipe reaches `byte_x = 1`:

```
1. Save departing pipe's slot-column index → soon_preparing_idx
2. Set departing pipe's byte_x = (don't care; will be reset below)
3. Make the currently-preparing pipe ACTIVE:
   - Set its byte_x = 29
   - Update slot column targets from ROM → screen RAM via existing
     patch_pipe_targets infrastructure (or by re-stamping the body
     bytes that were prepped — but with on-screen targets this time)
4. Mark soon_preparing_idx as the new preparing slot:
   - Clear its 160 slot-column rows to NOPs (~5 k T, done over a few
     frames via prep_step) OR all-at-once during the swap frame
   - Pick a new random gap_y for this pipe
   - Reset prep_progress to 0
```

The "all-at-once clear during swap frame" is ~5 k T. Acceptable since
swap frame doesn't carry any other extra work.

### Slot targets during prep

A preparing slot's `ld sp, target` writes to a ROM address (e.g.,
`$0000`). Writes to ROM are no-ops. PIPE_PROGRAM still executes those
slot instructions (~43 T per slot per row), but they have no visible
effect.

`patch_pipe_targets` MUST skip the preparing pipe's active sublist
entries — decrementing a ROM-pointing target would overflow into `$FFFx`
and start corrupting RAM. Easiest: only decrement entries belonging to
active pipes. The per-pipe sublist structure already supports this
(use `prep_pipe_idx` as a skip key).

## Frame budget

All values T-states. PIPE_PROGRAM cost: 4 slot columns at 43 T/slot
(extra-empty-byte form) + 4 T EXX = 176 T/row × 160 rows ≈ 28 k T.

| Component | Cost |
|---|---|
| Top blanking: bird ops | 5.5 k |
| frame_update: PIPE_PROGRAM | 28 k |
| frame_update: ground/score | ~2 k |
| WHITE: do_white_work | 3 k |
| CYAN: update_cap_imm_v2 | 2 k |
| CYAN: prep_step | 0.3 k |
| **Total per frame** | **~41 k** |
| Margin to 70 k | **~29 k** |

Every frame is ~41 k T. No spike, no special case for recycle or wrap.
29 k T margin is comfortable; even if my estimates are off by ±3 k T,
budget holds easily.

For reference, the **prep_step** budget over a full pipe cycle:
~270 T/frame × 112 frames = ~30 k T, the same amount of work that
currently happens as a single spike in `configure_pipe_slots`.

## Edge cases

### Pipe spacing

With 4 pipes evenly distributed across the 29-step byte_x cycle, initial
positions are at byte_x = 29, 22, 15, 8 (or similar even spacing,
distance = 7). Closest pair = 7 cols. Body + 2 trailing zeros = 6 cols
wide. Min gap between any two pipes' write footprints = 1 col. Safe.

When a pipe swaps from preparing → active at byte_x=29, the cycle's
phase relationship is maintained.

### `byte_x = 29` wraparound

The 6-byte stamp at byte_x = 29 writes at cols 28..33. Cols 32, 33
wrap (within the 8 KB band) to cols 0, 1 of a different scanline. Those
are buffer cols (hidden by ATTR_BUFFER = paper cyan + ink cyan). The
writes overwrite buffer pixels but the result is still invisible.

### Initial state

At game start, init configures pipes 0, 1, 2 the existing way (full
configure_pipe_slots call per pipe — 3 × 30 k = 90 k T, but it's init,
not a frame). Pipe 3 starts with `prep_pipe_idx = 3` and its slot
column is initialised to all-NOPs. The prep state machine immediately
starts preparing pipe 3 for its first appearance.

### HL=0 invariant in PIPE_PROGRAM

`redraw_pipes_v2` sets HL = 0 before calling PIPE_PROGRAM. Body slots
only touch SP/DE/BC, so HL stays 0 through them. Cap handlers use HL
to load cap byte pairs — they must restore HL = 0 before falling
through to the next slot. Add `ld hl, 0` at the end of each cap handler
(before the `jp _next`).

### `patch_pipe_targets` and the preparing pipe

`patch_pipe_targets` walks the active sublist contiguously (now
4 × 112 = 448 entries). The preparing pipe's 112 entries point at
slot target imms whose targets are ROM addresses ($0000..$3FFF range).

Two options:
- **Skip the preparing pipe's sublist** via an index check (current
  pattern with `pending_regen` already does this kind of skip).
- **Let it run.** The decrement still decrements; ROM targets wrap
  toward $FFFF eventually, but since the pipe will be reset to
  byte_x=29 at swap time (= target re-pointed at line_addr+34), the
  intermediate values don't matter.

Skip is safer (avoids any chance of the ROM pointer overflowing into
real RAM during the prep period).

### Cap-handler infinite-loop trap (memory note `project_split_cap_handler_race`)

The known trap: if the cap_top slot fires the handler, and the handler's
`_next` imm points BEFORE the cap row, control loops forever.

In the 4-pipe design this is impossible by construction: the preparing
pipe's slot column is built in a fixed order (body rows first, then
cap_block, then handlers patched). The handlers' `_next` is only
patched *after* the cap_block stamp is complete, so during the prep
window the `jp $0000` placeholder JPs to ROM — safe (any execution
that reaches a partially-prepared cap slot would fall through into ROM,
which has no infinite-loop hazard).

Even better: keep the preparing pipe's slot column at all-NOPs until the
final step (patch handlers + active list), and only then enable cap
slots. Until that final step, `jp` opcodes don't exist in the column;
PIPE_PROGRAM just runs NOPs.

## Removed code

- `do_deferred_clears` routine in `main_loop`
- `clear_pending` byte, `clear_pipe_col` routine, `paint_restore`
  routine — no longer called from anywhere
- `gap_clear_pending`, `gap_clear_pipe_idx` bytes, `run_gap_clear`
  routine
- `wrap_byte_x`'s `clear_pending = 1` set
- The defensive `cap_*_target_imm_addrs` refresh added in commit
  7d9d5ae — still useful as a belt-and-braces safeguard, can stay

## Migration risk

This is a significant refactor of PIPE_PROGRAM's structure. Risks:

- **Slot grid layout change** ripples into `init_slot_addr_table`,
  `init_pipe_program`, `configure_pipe_slots`, and `init_pipes`. Each
  needs to use the new 4-pipe / 32-byte-stride formulas.
- **Active list size doubles** (3 × 112 → 4 × 112). `patch_pipe_targets`
  loop count changes.
- **Cap handler count doubles** (6 → 8). New tables, new SMC labels.
- **Pipe spacing** — initial byte_x values need re-thinking for 4 pipes
  (currently 29, 19, 9 with spacing 10; for 4 pipes consider 29, 22,
  15, 8 with spacing 7).

The implementation will be done in phases (see plan doc) so each
intermediate state is buildable and testable. Big-bang refactor would
be too risky.

## Testing

- `make` clean (errors 0, warnings 0).
- `make run` — visual:
  - Bird at top of screen: no flicker as it moves.
  - Pipes: no tearing on top rows ever.
  - No "missing chunks" of pipes on any frame.
  - Bird-pipe overlap: bird passes behind pipes at the overlap moment
    (pipe-in-front trade-off as before).
- Border profiling: RED/WHITE/CYAN bands stable, no overrun into the
  next frame's RED.
- Snapshot diff via `.szx` files at known game states (e.g., after 30
  recycles) — verify all 4 pipe slot columns are correctly populated,
  no stale body bytes in gap regions, cap handler imms consistent.

## Phasing

This will be a multi-commit refactor:

1. **Phase 1**: Replace body slot with 6-byte (extra-empty-byte) form.
   Keep 3 pipes. Remove `do_deferred_clears`, `gap_clear` infrastructure.
   Bird stays in CYAN for now. Verify pipes don't have stale leftovers.
2. **Phase 2**: Move bird ops to top blanking. Verify no flicker, no
   tearing.
3. **Phase 3**: Expand pipe_state to 4 entries, expand PIPE_PROGRAM to
   4 slot columns, add cap handlers and tables. Wire up the 4th slot
   column rendering with all-NOPs. Verify game still works with 3
   active pipes and 1 dormant column.
4. **Phase 4**: Implement `prep_step` state machine. Verify the prep
   work happens correctly and the prepared pipe is ready when swap
   fires.
5. **Phase 5**: Implement swap at `byte_x = 1`. Verify pipes cycle
   smoothly through the 4 slot columns.

Each phase is independently buildable / playable.
