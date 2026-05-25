# Speccy Flappy Bird — Project Instructions

## What this is

Flappy Bird-style scrolling shooter on a stock 48K ZX Spectrum. **Silky-smooth 50 Hz** across the full visible playfield. Three pipes scrolling left, bird obeying gravity, attribute-coloured pipes on cyan sky, ground band + scoreboard.

**This is a performance project.** The whole point is that it runs at 50 Hz on a 3.5 MHz Z80. If it stutters, it's broken. If frames drop to 25 Hz, the work isn't done.

## Hard performance rules

### The budget

- **70,000 T-states per frame.** (Actually 69,888, but treat the round number as the ceiling.)
- **~14,000 T** of that is vertical blanking before the raster reaches the visible top.
- **~50,000 T** is visible scan time (192 lines × ~224 T/line).
- **Bottom blanking ~5,000 T** before the next interrupt.
- If `frame_update` doesn't return before the next `halt` fires, the halt is missed and the game drops to 25 Hz for that frame. **This is a bug.** No matter how rare.

### Discipline

- **Count T-states before you write code.** Not after. The Z80 doesn't reward "we'll optimise later." Every routine starts ultra-optimised. There is no "good-enough first pass."
- **Estimate inner-loop cost line by line.** For a 160-row loop, a 26 T inner copy is 4 k T; a 16 T inner copy (LDI) is 2.5 k T. The difference of 10 T per byte is 1.5 k T per loop. You will think this is small. It is not — over five routines it's a frame.
- **Don't add dispatch inside a hot loop.** Per-row `cp` chains with `jp` cascades will cost 50–100 T per iteration. The whole point of band-loops, SMC-patched dispatch, and pre-computed cursors is to push the decisions OUTSIDE the hot path.
- **Implementation must match the analysis.** If you said the loop is 80 T/row in the design, the assembled loop is 80 T/row. If it turns out higher, you owe a fix before you commit, not after.
- **The visual is the spec.** Never propose "accept a compromise" on render quality. If the technique is too slow, find a faster technique — don't degrade the output.

## Joffa-style techniques (use all of them)

### Compute-time tricks

- **Pre-shifted tiles** — for any sprite/tile that scrolls horizontally at sub-byte resolution, pre-shift it at build/init time, one variant per pixel phase (0..7). Never bit-shift at render time.
- **Pre-baked templates** — if a structure depends on a small fixed set of inputs (e.g. 12 gap_y values), pre-bake all variants at init. Templates live in upper RAM; copies at run time use LDIR or SP-hijack push/pop.
- **Pre-computed LUTs** — `line_table[Y]` for screen addresses. `screen_target_table_29[Y]` for byte_x=29 + line. Any expensive arithmetic should be a lookup.
- **SMC code-gen** — emit specialised code into a slot grid (e.g. `PIPE_PROGRAM` at `$DB00`). Decisions baked into the instruction stream are zero T-state at execute time.

### Run-time tricks

- **Stack-blast** (`ld sp, target ; push de ; push bc`) — pushes write 2 bytes in 11 T each, far faster than `ld (hl), a ; inc hl ; ld (hl), a ; inc hl` (26 T/byte). Use this for any bulk row fill.
- **SP-hijack** — when copying or filling, repoint `sp` into the destination and `push` register pairs into it. Save the real SP first. Restore before any `call`/`ret`.
- **LDI for small fixed-size copies** — `LDI` is 16 T/byte (vs ~26 T sequential). For row copies of 5+ bytes where the destination needs strided advance, LDI inside a loop beats `ld a,(hl); ld (de),a; inc hl; inc de` by ~10 T/byte.
- **EXX register-bank swap for A/B dither** — flip the whole alternate register set with a 4-T `EXX` instead of reloading values. Used to alternate per-row sky-A / sky-B byte patterns inside `PIPE_PROGRAM`.
- **Race the beam** — for full-screen 50 Hz writers, the raster scans the visible area in ~43 k T (192 lines × 224 T). Per-line render must stay under 224 T, and the writer must START ahead of the raster (during top blanking) and stay ahead. If the writer falls behind, tearing.
- **Sorted cursors / linked-SMC dispatch** — when multiple events fire at known rows, sort them at recycle time and link them via SMC `jp` chains, so the hot loop does one fast comparison and a direct jump rather than a multi-way `cp` chain.
- **Active-list pattern** — `patch_pipe_targets` walks a flat list of 16-bit addresses and decrements the byte at each. Cheap (4 entries unrolled per `djnz`, ~33 T/entry). When state changes, rebuild the list once; reads stay cheap forever.

### Layout tricks

- **Buffer columns** — left cols 0–3 and right cols 28–31 have invisible attributes (`paper = ink`). Pipes scrolling through them render fully but are invisible. Eliminates edge clipping in the hot writer.
- **Hand-laid memory map** — every routine has a known address range. EQU constants make moves cheap. Inspect the `.lst` listing if you doubt a routine's location.

## Anti-patterns (never)

- **`LDIR` for small fixed-size copies** — overhead of `ld bc, N` plus the per-byte 21 T cost is worse than LDI/unrolled copy for N < ~20.
- **Per-row `cp` dispatch in an inner loop.** Replace with band-based looping (one `cp` and a `djnz` count per band; zero per-row cost).
- **`call`/`ret` in tight hot paths.** The 17 + 10 T overhead per call multiplies fast. Inline or use SMC chains.
- **Conditional that's always taken.** If your code path is 99% one branch, hoist the dispatch out and inline the body, don't waste 10 T per row on the `jr nc`.
- **Re-reading the same memory location across iterations.** Hoist to a register at top of loop. Z80 has 7 general-purpose 8-bit regs + shadows + IX + IY; use them.
- **`push iy/pop iy` outside of a needed register-juggle.** IY is precious; don't shuffle it unless you have to.

## Reference: instruction costs

| Operation | T-states | Notes |
|---|---|---|
| `nop` | 4 | |
| `ld r, r` | 4 | |
| `ld r, n` (immediate) | 7 | |
| `ld a, (hl)` | 7 | |
| `ld (hl), a` | 7 | |
| `ld a, (nn)` | 13 | absolute |
| `ld (nn), a` | 13 | absolute |
| `ld r, (iy+d)` / `ld (iy+d), r` | 19 | indexed |
| `ld (iy+d), n` | 19 | indexed immediate |
| `inc hl`, `dec hl` | 6 | |
| `inc r`, `dec r` (8-bit) | 4 | |
| `add hl, rr` | 11 | |
| `add a, n` / `cp n` | 7 | |
| `jr e` | 12 taken / 7 not-taken | |
| `jp nn` | 10 | |
| `jp cc, nn` | 10 (always) | |
| `djnz e` | 13 taken / 8 not-taken | |
| `call` / `ret` | 17 / 10 | |
| `push rr` / `pop rr` | 11 / 10 | |
| `exx` | 4 | bank swap |
| `LDI` | 16 | (de)=(hl); inc; dec bc |
| `LDIR` | 21 per byte (16 on last) | |
| `out (n), a` | 11 | |
| `ld sp, hl` | 6 | hot for SP-hijack |

## Project layout

- `src/main.asm` — everything. Single-file project. Currently ~3300 lines.
- `Makefile` — `make` builds, `make run` opens `build/main.sna` in Fuse (you can't run the emulator — the human does).
- `tools/sjasmplus/` — assembler.
- `build/main.sna` — output snapshot. `build/main.lst` — assembly listing (regenerate with `--lst=` flag).
- `docs/superpowers/specs/` — design specs.
- `docs/superpowers/plans/` — implementation plans.

## Workflow

- Build with `make` from project root. Expect `Errors: 0, warnings: 0`.
- For empirical timing, use the border. `out ($fe), a` is 11 T. Set to a colour at the start of a region and a different colour at the end; the band's height on screen tells you the cost. White-band = X visible scanlines ≈ X × 224 T.
- The human runs `make run`. You can't see emulator output. Make changes that won't break the build, commit, ask the human to run.

## Per-frame architecture

```
main_loop:
    halt                            ; wait for vsync interrupt
    di
    OUT $FE, RED                    ; profile marker
    call frame_update               ; <= 70k T total
    OUT $FE, CYAN                   ; idle
    ei
    jr main_loop

frame_update:
    call redraw_pipes_v2            ; -> PIPE_PROGRAM (~16k T per frame)
    OUT $FE, BLUE                   ; bird ops region
    bird routines                   ; ~4-5k T
    OUT $FE, GREEN                  ; ground region
    call draw_ground                ; ~3-5k T
    OUT $FE, WHITE                  ; state prep
    call advance_phase x2           ; +wrap on every 4th frame
    (if wrap_pending) call restore_trailing_pipe_attrs
    (if score changed) call render_score
    ret
```

### Per-frame T-state targets

- **Normal frame** (no wrap, no recycle): ≤ 30 k T. We currently sit at ~25 k. Good margin.
- **Wrap frame** (every 4th): ≤ 40 k T. We sit at ~32 k. OK margin.
- **Configure frame** (every ~40th, after a pipe recycles): ≤ 55 k T. Currently ~67 k — tight. This is the frame to keep optimising.
- **None of these frames may exceed 70 k T, ever.**

## Key data structures

- **`PIPE_PROGRAM`** at `$DB00..$E4FF` — machine-emitted SMC slot grid. 160 rows × 32 bytes (1 EXX + 4 × 6-byte slot + JP-next-row trailer + pad). Each pipe slot is `ld sp,target ; push hl ; push de ; push bc` (body) or `jp cap_handler` (cap_top/cap_bot). Skip slots are `JR +4`. Epilogue at `SLOT_GRID_END` falls through into `ld sp,(saved_sp); ret`.
- **Prep-column JR-skip** — the invisible prep pipe's whole slot column is held as `JR +4` slots (12 T/row instead of a 43 T body push into the off-screen buffer column). `do_swap` JR-skips the departing column; `prep_step` rebuilds the just-activated column post-swap while the pipe is frozen at `byte_x=29`; `ps_phase6` arms its caps at build completion. See `docs/superpowers/specs/2026-05-21-skip-prep-column-design.md`.
- **`pipe_state`** — `db byte_x, gap_y` for each of 3 pipes. byte_x ∈ [1,29], gap_y ∈ {8,16,...,96}.
- **`BODY_TEMPLATE`** at `$C000` — 800 bytes, pre-baked body slot bytes for byte_x=29.
- **`CAP_BLOCK`** at `$C320` — 250 bytes, shared cap_top + 48 skip + cap_bot block.
- **`CAP_TARGET_TABLE`** at `$C41A` — per-gap_y cap handler target imms.
- **`ACTIVE_PIPE_0..2`** at `$FA40..$FCDF` — per-pipe active sublist, 112 entries × 2 bytes. Each entry is the address of a target imm byte that `patch_pipe_targets` decrements per wrap.

## Diagnostics workflow

This project has self-serve snapshot diagnostics. The agent (Claude) is expected
to USE these — every claim of "I fixed it" must be backed by a snapshot reading.

### Snapshot convention

- The snapshot file is **always `build/main.sna`**. Stop renaming it, copying it
  to `~/Downloads/`, or asking for it to be re-saved with a new name.
- Workflow: agent edits → agent builds → user runs `make run` and plays for a
  few seconds → user takes a snapshot (Fuse: File → Save Snapshot) which
  overwrites `build/main.sna` → agent reads `build/main.sna` with the tools
  below.
- The agent **cannot** see the emulator window. Visual analysis comes from
  `tools/snadump.py screen build/main.sna out.png` and reading the PNG.

### In-RAM border profiler ring

- A 256-entry × 2-byte ring buffer at `$FE00..$FFFF` records every
  `PROFILE_OUT color` (the macro that replaces the old `ld a,c : out ($fe),a`
  profile markers). Each entry is `(color, frame_counter_lo)`.
- `diag_frame_counter` (1 byte) increments per completed `halt` (just before
  `di`) — 8-bit, wraps at 256.
- `diag_border_log_ptr` (2 bytes) is the head pointer, advances by 2 per
  marker, wraps at `$FFFF → $FE00`.
- The macro cost is ~50 T per call. Budget that into hot paths; the macro
  preserves AF, HL and writes only to `(diag_border_log_ptr)` /
  `diag_frame_counter` and the ring itself.
- The sound emitter at `sfx_tick.emit` does **not** use the macro — its
  `out ($fe), a` is a speaker pulse, not a profile marker, and a ring write
  inside the sound inner loop would destroy the timing.

### tools/snadump.py

```
python3 tools/snadump.py screen build/main.sna out.png  # decode screen → PNG
python3 tools/snadump.py border build/main.sna          # per-frame timeline
python3 tools/snadump.py mem    build/main.sna $ADDR N  # hex dump
python3 tools/snadump.py grid   build/main.sna          # PIPE_PROGRAM band shapes
```

`border` reconstructs each frame's marker sequence in chronological order and
prints e.g.:

```
Frame  47: RED MAGENTA BLUE GREEN WHITE CYAN YELLOW BLACK
Frame  48: RED MAGENTA BLUE GREEN WHITE CYAN YELLOW BLACK
Frame  49: RED MAGENTA BLUE GREEN WHITE CYAN YELLOW             [OVERRUN — no BLACK]
```

**Overrun detection rule**: a frame must end with `BLACK` (the idle marker
before `halt`). A frame whose log ends with anything else missed its `halt`
and the game ran at 25 Hz on that frame. If `snadump.py border` reports
`overruns: 0` across all logged frames, the timing is clean. **Any non-zero
overrun count is a bug, regardless of how rare.** The fresh-build snapshot
has zero entries (no halt has fired) — that's expected.

Symbol addresses are hard-coded near the top of `snadump.py`. After any
memory-map change, regenerate `build/main.lst` and update the `SYM` dict:

```
tools/sjasmplus/sjasmplus --fullpath --lst=build/main.lst src/main.asm
grep -E 'diag_frame_counter|diag_border_log_ptr|DIAG_BORDER_LOG' build/main.lst
```

### "Before claiming a fix" checklist

1. Predict what the border timeline **should** look like with the fix
   (which frames change colour count? which had overruns and now don't?).
2. After build, ask the user for a fresh `build/main.sna`, then run
   `python3 tools/snadump.py border build/main.sna`.
3. Compare measured vs predicted. Only claim "fixed" if they match.
4. Every per-frame change still requires a written T-state estimate
   **before** the code change. The border timeline verifies the estimate
   after the fact.

## When in doubt

- Read `docs/superpowers/specs/` for design intent.
- Read `git log` for what's been tried and reverted.
- Check the auto-memory at `~/.claude-personal/projects/-Users-freemans-github-freemans13-speccy-scrolling/memory/` for prior pitfalls (SLOT_GRID_END NOP-slide trap, split-configure cap-handler race, etc.).
- If the analysis says "this should cost 80 T/row" and the implementation costs 200 T/row, **the implementation is wrong**. Fix the implementation; do not commit a slower version with the same commit message.
