# Handoff: Eliminate the per-second recycle pause

**Date:** 2026-05-14
**Branch state:** committed and clean, builds at `Errors: 0, warnings: 0, compiled: 5862 lines`

## Where we are

The game runs at **steady 50Hz** for normal frames and wrap frames. Cityscape masks correctly behind pipe edges via masked-OR with `bg_buffer`. The bird, ground, cap, body, city, and score all render correctly.

**The one remaining visible issue:** every ~1 second a pipe recycles. On that frame the WHITE border band extends through the entire visible area (gen_pipe_program runs and overruns the frame budget) and the user sees a visible 1-frame pause.

## Frame budget (50Hz = 69888 T-states)

Empirical estimates for `frame_update` cost on each frame type:

| Frame type | Cost | Fits? |
|---|---|---|
| Normal (no wrap, no recycle) | ~40k | yes, ~30k idle |
| Wrap (byte_x changes, no recycle) | ~68k | yes, ~2k margin |
| Recycle (wrap + full gen) | ~140-165k | NO, overruns by ~70-100k |

The wrap frame fits because of optimizations already in place:
- `patch_pipe_targets` 4-way unrolled with SP-hijack pop + djnz — ~14k
- `recompute_city_overlay` uses precomputed `CITY_BG_TABLE` — ~9k
- `update_city_cache_fast` uses precomputed `CITY_OVERLAY` — ~16k
- SP-hijack stack-blast in `PIPE_PROGRAM` (the generated flat program) — ~13k
- `update_cap_imm` uses `cap_slot_table` — ~2k

The recycle frame doesn't fit because `gen_pipe_program` regenerates the entire flat render program from scratch (~95k T-states).

## Architecture overview

### Render pipeline (per frame)

```
redraw_pipes_v2:
  update_cap_imm           ; refresh cap bytes in PIPE_PROGRAM cap slots
  update_city_cache_fast   ; refresh CITY_CACHE (sky|overlay&mask per cell)
  call PIPE_PROGRAM         ; flat stack-blast program writes pipes to screen

  ; ... bird, ground, score, advance_phase ...

  if pending_regen:
    call gen_pipe_program    ; full regenerate of PIPE_PROGRAM (~95k!)
```

### Static-data precomputes (done once at init)

- `BG_BUFFER` ($C000-$D7FF, 6KB) — cityscape pixel pattern, written by `init_background` and copied to screen.
- `CITY_BG_TABLE` ($EB00-$EEFF, 1KB) — precomputed by `init_city_bg_table`: `table[row*32+col]` = bg byte if cityscape visible at (col, row) else 0. Page-aligned for fast lookup.

### Dynamic data (recomputed when byte_x changes — every 4 frames)

- `CITY_OVERLAY` ($F080-$F13F, 192B) — rebuilt by `recompute_city_overlay` using `CITY_BG_TABLE`: per (row, pipe, L/R), the bg byte to mask in.

### Per-frame data (every frame)

- `CITY_CACHE` ($EF00-$F07F, 384B) — rebuilt by `update_city_cache_fast`: per (row, pipe, cell), `sky_byte | (overlay & mask)`. PIPE_PROGRAM's city emits pop from here.
- Cap bytes in pipe_program — patched by `update_cap_imm` at addresses recorded in `cap_slot_table`.

### Per-wrap data (every 4 frames)

- `patch_pipe_targets` decrements all 16-bit `ld sp, target` immediates in PIPE_PROGRAM by 1, advancing pipes 8 pixels left.

### Per-recycle (every ~75 frames = ~1 sec)

- `gen_pipe_program` rewrites PIPE_PROGRAM and rebuilds `ACTIVE_LIST_NEW` and `cap_slot_table` from scratch. **This is the source of the pause.**

## What was tried for the recycle pause

### Attempt 1: in-place chunked gen (failed)
Split `gen_pipe_program` into 4 chunks of 40 rows, writing into the live PIPE_PROGRAM. Each chunk wrote a partial program; at end of chunk, save IY+row state for next frame to resume.

**Failure mode:** changing gap_y on recycle changes cap-row emit sizes (5 bytes body vs 19 bytes cap). Partial overlay leaves byte offsets misaligned in the live program → garbage opcodes → CPU crashes / screen corruption.

### Attempt 2: single-frame shadow buffer (failed)
Added `PIPE_PROGRAM_B` at $C000 (reusing BG_BUFFER post-init). Gen writes to the inactive buffer. After completion, atomic swap via SMC of `call PIPE_PROGRAM` site. Plus dual `ACTIVE_LIST_A/B` and dual `live_list_addr`/`shadow_list_addr` vars, with `patch_pipe_targets` reading from `live_list_addr`.

**Failure mode:** screen corruption appeared after several recycles. Root cause never pinpointed but **most likely culprit is `cap_slot_table`**:
- `cap_slot_table` is a 24-byte table at $8069 recording addresses of bc-imm and de-imm slots in PIPE_PROGRAM.
- Gen writes `cap_slot_table` entries with addresses in the SHADOW buffer (where gen is writing).
- `update_cap_imm` runs **every frame** and writes cap bytes to those addresses.
- During chunked gen frames, `cap_slot_table` ends up with MIXED A-buffer and B-buffer addresses (some entries still from previous gen pointing to the old live, some from current gen pointing to shadow).
- `update_cap_imm` writes to wherever the table says, so cap bytes go to BOTH buffers in a haphazard pattern → live's caps stop updating for half the slots → visible glitches that accumulate.

I reverted both attempts. The repo is back at the working "single buffer, recycle pause every second" state.

## Recommended next steps

### Step 1 (low-risk, ~30 min): gen optimizations
Cut `gen_pipe_program` from ~95k to ~50-65k T-states. The recycle frame still overruns but by less — the pause becomes a ~half-frame skip, often imperceptible.

These optimizations are all safe and self-contained:

1. **Hoist `line_table[row]` per row** (save ~10k):
   Currently each pipe re-computes `line_table[row]` in body/cap/city emit. Compute once at start of `.row_lp`, cache in scratch words (e.g., `row_line_lo`, `row_line_hi`), and have each pipe's emit read from there.

2. **Inline `.append_active_slot`** (save ~9k):
   Each emit does `call .append_active_slot; ... ret` = 17 + 10 = 27T overhead × 336 emits = 9k. Inline the 4-instruction body at each call site (5 sites: body emit at line 949, cap emit, city emit; check `grep -n "call .append_active_slot"`).

3. **Hardcode `ACTIVE_COUNT_NEW = 336` at end** (save ~10k):
   `.append_active_slot` increments `ACTIVE_COUNT_NEW` every call (32T × 336 = 10.7k). Remove the per-call increment and just write `ld hl, 336; ld (ACTIVE_COUNT_NEW), hl` once at `.full_done`. (gen always produces 336 entries: 78 body × 3 pipes + 2 cap × 3 + 32 city × 3.)

4. **Use HL cursor instead of IY for byte writes in emit** (save ~10-15k):
   `ld (iy+d), $imm` is 19T per byte. `ld (hl), $imm` is 10T plus `inc hl` 6T = 16T per byte. Save ~3T per byte × 5-19 bytes per emit × 336 emits. Big refactor but biggest single win. Keep IY for stride math at end-of-emit.

Total expected: ~30-44k savings. Gen 95k → 50-65k. Recycle frame: 140k-160k → 95-115k = ~half a frame overrun, often imperceptible.

### Step 2 (proper fix, eliminates pause entirely): shadow buffer + chunked gen
Repeat my second attempt BUT also handle `cap_slot_table` correctly.

Memory layout (already in place via EQUs at top of `main.asm`):
```
PIPE_PROGRAM_A      EQU $DB00    ; 4 KB
PIPE_PROGRAM_B      EQU $C000    ; 4 KB — reuses BG_BUFFER after init
ACTIVE_LIST_A       EQU $FA40    ; 720 B
ACTIVE_LIST_B       EQU $F140    ; 720 B (in legacy area)
ACTIVE_COUNT_A      EQU $FD10    ; 2 B
ACTIVE_COUNT_B      EQU $F410
CITY_BG_TABLE       EQU $EB00    ; 1 KB precomputed once at init
CITY_CACHE          EQU $EF00    ; 384 B (live cache, shared by both buffers — PIPE_PROGRAM's city emits use FIXED CITY_CACHE addresses regardless of which buffer is live)
CITY_OVERLAY        EQU $F080    ; 192 B (live overlay)
```

**Critical:** `cap_slot_table` (at $8069, 24 B) needs dual handling. Two clean options:
- **Option A: two cap_slot_tables.** Add `cap_slot_table_shadow` (24 B). Gen writes to `cap_slot_table_shadow`. At promote, do a 24-byte LDIR from shadow to live `cap_slot_table`.
- **Option B: gen builds into a scratch buffer.** Then promote does a single 24-byte ldir copy and the call-site SMC together.

Other implementation notes for the rewrite:

- **SMC the `call PIPE_PROGRAM` site** in `redraw_pipes_v2` (the 2 bytes after the $CD opcode). Initial value PIPE_PROGRAM_A.
- **Two active_lists** with `live_list_addr` and `shadow_list_addr` variables. `patch_pipe_targets` reads `live_list_addr` (use `ld hl, (live_list_addr); ld sp, hl`). Gen sets `active_cursor` from `shadow_list_addr` at start.
- **Per-pipe byte_x snapshot**: at start of chunked gen, copy `pipe_state` into `pipe_state_snapshot`. Have gen read byte_x/gap_y from snapshot, NOT from pipe_state. This way all chunks use the same byte_x even if wraps happen during gen. Avoids the need for catch-up patches.
- **At promote**: SMC the call site, copy `shadow_list_addr → live_list_addr`, LDIR copy `cap_slot_table_shadow → cap_slot_table`, flip shadow vars to other buffer.
- **Chunk sizing**: 4 chunks of 40 rows = ~24k T-states each. Each gen-active frame: 40k normal + 24k gen = 64k. Fits.
- **Recycle-frame timing**: skip patch (already done via `pending_regen` check). The wrap frame budget on a recycle is ~54k (normal 40k + wrap minus patch 14k). Plus first gen chunk 24k = 78k = over by 8k.
  - Fix: defer first chunk to next frame. Recycle frame: 54k (no chunk). Frames +1, +2, +3, +4: 64k each (gen chunks 1-4). Frame +5 onwards: normal. This works because the recycled pipe sits in the right buffer (byte_x=29, cols 28-31, invisible) for ~12 frames before becoming visible — plenty of time for gen to complete and swap.

### Step 3 (RECOMMENDED — preferred approach per user discussion): fixed-slot dispatch

**Insight from the user:** the program structure doesn't need to change on recycle. Only the *role* of certain rows (body vs cap vs gap) changes. Use a fixed program with per-slot SMC dispatch to swap roles on recycle.

**Architecture:**

Pre-emit at init a fixed PIPE_PROGRAM where every (row, pipe) is a 5-byte slot. Each slot is one of four templates, all the same length:

| Slot type | Bytes | What it does |
|---|---|---|
| **Body** (default for non-city rows) | `$31 lo hi $D5 $C5` | `ld sp, target; push de; push bc` — pushes BC/DE (sky bytes) to screen |
| **Skip** (gap row) | `$00 $00 $00 $00 $00` | NOPs — renders nothing |
| **Cap_top** (one row per pipe) | `$CD lo hi $00 $00` | `call cap_top_handler_for_pipe_N` — separate routine emits the cap |
| **Cap_bot** (one row per pipe) | `$CD lo hi $00 $00` | `call cap_bot_handler_for_pipe_N` |

City rows (128-159) need a different slot size (10 bytes for `ld sp, cache; pop bc; pop de; ld sp, target; push de; push bc` plus BC/DE restore). Either use 10-byte slots throughout (= 160 × 3 × 10 = 4800 bytes, slight overflow) or have separate city-row slots with the same 4-type dispatch (`body`, `skip`, `cap_top`, `cap_bot` — the cap handlers do the city OR'ing).

**Memory:** 160 × 3 × 5 = 2400 bytes for the main slot grid + ~6 cap handler routines × 11 bytes ≈ 70 bytes + city row variants. Total under 3 KB. Fits.

**byte_x patches (every 4 frames, on wrap):** unchanged. `patch_pipe_targets` walks `active_list` and decrements all live target immediates. The active_list still needs to be built at init — it lists addresses of every Body and city-Body slot's `target` immediate (the lo byte at slot_addr + 1).

**On recycle (gap_y changes for pipe N), 6 patch operations:**

1. Patch slot at (OLD gap_y - 1, N): cap_top → body (rewrite 5 bytes).
2. Patch slot at (OLD gap_y + 48, N): cap_bot → body.
3. Patch slots at (OLD gap_y .. OLD gap_y + 47, N): skip → body (48 rows × 5 bytes = 240 bytes).
4. Patch slot at (NEW gap_y - 1, N): body → cap_top.
5. Patch slot at (NEW gap_y + 48, N): body → cap_bot.
6. Patch slots at (NEW gap_y .. NEW gap_y + 47, N): body → skip (48 × 5 = 240 bytes).

Plus updating the active_list: remove entries for OLD cap and gap rows, add entries for the new body rows where caps WERE. ~50 active_list patches.

**Total per-recycle cost:** ~500 byte writes + ~50 active_list updates ≈ **3000-5000 T-states**. Compare to current ~95k. The recycle pause vanishes.

**Cap handler design:**

```
cap_top_handler_pipe_0:
        ld sp, cap_top_target_pipe_0    ; SMC: target patched by patch_pipe_targets
        ld bc, (cap_top_bc_phase_imm)   ; cap-specific bytes, patched per frame by update_cap_imm
        ld de, (cap_top_de_phase_imm)
        push de
        push bc
        ld bc, (body_a_bc)              ; restore BC/DE for subsequent body emits
        ld de, (body_a_de)
        ret
```

Per pipe per cap (6 handlers): each ~25 bytes. Total ~150 bytes for cap handlers.

The cap handler's `ld sp, target` immediate is also in `active_list` so it gets patched on wraps like body slots.

**On recycle, also update `cap_top_target_pipe_N` and `cap_bot_target_pipe_N`** to the new screen line. Since these are screen addresses computed from line_table[NEW gap_y - 1] + byte_x + 3, they need a fresh compute at recycle (~30 T-states each, 4 per recycle).

**Net per-recycle cost estimate:** 500 byte writes (~7k T-states) + active_list rewrite (~1.5k T-states) + cap target computes (~120 T-states) = **~8.5k T-states**. Fits comfortably in the recycle frame (40k normal + 14k wrap + 8.5k recycle = 62.5k total). Wrap frame cost stays the same (~68k).

**Big advantage:** no shadow buffer needed. No chunked gen. Single buffer. Simple atomic updates.

**Trade-off:** the main pipe_program execution is slightly slower since each emit is now a slot rather than inline body — but only for cap/skip rows. The cap call adds ~17 T-states (call + ret) vs the current inline cap which is similar overhead. Skip rows execute 5 NOPs (= 20 T-states each) instead of 0 — only a few rows per frame so under 1k T-states added per frame. Negligible.

**Implementation order:**
1. Pre-emit the slot grid at init (160 × 3 = 480 slots, all default body). Build active_list pointing at each slot's target immediate.
2. Apply initial gap_y configuration: patch slots to Cap/Skip per pipe.
3. Replace `gen_pipe_program` calls with `patch_pipe_slots(pipe_N, old_gap_y, new_gap_y)` — the targeted patch routine.
4. `update_cap_imm` updates the `cap_bc/de_phase_imm` immediates in each pipe's cap handler. Same idea as today's cap_slot_table but simpler — one immediate per handler.

This is the cleanest path forward. Less code than the shadow-buffer architecture and addresses the root cause (regeneration cost) directly.

### Step 4 (deprecated): shadow buffer + chunked gen
The shadow-buffer + chunked-gen approach (described above as Step 2) is no longer recommended given that Step 3 is simpler and more efficient. Keep Step 1 as a sanity-checkpoint commit, then jump directly to Step 3.

## Files and key locations

- **Source:** `src/main.asm`
- **Build:** `make` (sjasmplus). Output: `build/main.sna`.
- **Listing:** `make` with `--lst=build/main.lst` to see byte addresses (already enabled in some commits).
- **Run:** `make run` (opens `build/main.sna` in Fuse).

Key labels to read for context (use `grep -n` in `main.asm`):
- `gen_pipe_program:` — the regenerator. Walks rows 0..160, dispatches to `.emit_a` (body), `.do_cap`, `.emit_city_body`, or skip (gap).
- `gen_pipe_program.row_lp:` — main row loop. Has `.row_limit_smc EQU $+1` for chunked gen.
- `.full_done:` — gen exit point. Emits epilogue.
- `.append_active_slot:` — appends 16-bit slot addr to `ACTIVE_LIST_NEW`.
- `patch_pipe_targets:` — 4-way unrolled SP-hijack walker. Decrements 336 16-bit targets.
- `update_city_cache_fast:` — per-frame cache rebuild.
- `recompute_city_overlay:` — per-byte_x-change overlay rebuild using `CITY_BG_TABLE`.
- `init_city_bg_table:` — one-time init of the precomputed `(col, row) -> bg_if_city` table.
- `update_cap_imm:` — writes cap bytes via `cap_slot_table`.
- `wrap_byte_x:` — handles per-pipe byte_x decrement on phase wrap.

State variables (search for declarations near line 215):
- `wrap_pending`, `pending_regen`, `gen_chunk_state`, `gen_iy_save`, `gen_row_save`, `wraps_during_gen` — chunked-gen state machine (left in place but unused now).
- `shadow_buf_addr`, `shadow_list_addr`, `shadow_count_addr`, `live_list_addr`, `live_count_addr`, `active_set` — shadow-buffer vars (left in place but unused now). Safe to delete OR use as starting point for the rewrite.

Profile border bands in `frame_update`:
- RED ($02): pre-`redraw_pipes_v2` (update_cap_imm)
- YELLOW ($06): `update_city_cache_fast`
- MAGENTA ($03): `PIPE_PROGRAM` execution
- BLUE ($01): bird ops
- GREEN ($04): ground
- WHITE ($07): end-of-frame state prep (advance_phase, wrap_byte_x, gen)
- CYAN ($05): idle

When the border turns mostly WHITE for the whole visible area = gen overran the frame.

## Memory map summary

| Address | Size | Purpose |
|---|---|---|
| $4000-$57FF | 6 KB | Screen pixels (contended) |
| $5800-$5AFF | 768 B | Screen attrs |
| $8000-$B000ish | ~12 KB | Code |
| $C000-$D7FF | 6 KB | BG_BUFFER (only read at init by `init_background`, `init_city_bg_table`, `update_city_cache` (the OLD one called once at init). After init, $C000-$CFFF is **available for PIPE_PROGRAM_B**.) |
| $D800-$DAFF | 768 B | BACKUP_ATTRS (live during gameplay) |
| $DB00-$EAFF | 4 KB | PIPE_PROGRAM_A (actual usage ~3.2 KB, leaves slack) |
| $EB00-$EEFF | 1 KB | CITY_BG_TABLE (page-aligned, static after init) |
| $EF00-$F07F | 384 B | CITY_CACHE (rebuilt each frame) |
| $F080-$F13F | 192 B | CITY_OVERLAY (rebuilt each byte_x change) |
| $F140-$F40F | 720 B | ACTIVE_LIST_B (reserved for shadow buffer) |
| $F410-$F411 | 2 B | ACTIVE_COUNT_B |
| $F412-$F7FF | ~1 KB | Legacy unused |
| $F800-$FA3F | 576 B | CITY_TABLE (legacy unused) |
| $FA40-$FCFF | 720 B | ACTIVE_LIST_NEW = ACTIVE_LIST_A |
| $FD10-$FFFF | ~752 B | counters + state vars + free |

## Test plan for the rewrite

1. Apply Step 1 optimizations one at a time, build + run after each. Verify no visual regression.
2. Implement shadow buffer + chunked gen with cap_slot_table fix. Test:
   - Initial render: cityscape + pipes appear correctly at start.
   - After 1st recycle (~75 frames in): no corruption, smooth scroll.
   - After 10+ recycles (score ~10): still clean.
   - White border should be minimal (under 1 scanline) on recycle frames.
3. Frame-by-frame test in Fuse: pipes should move 1 pixel per advance_phase call (2 pixels per frame total) consistently. No 2-pixel jumps from dropped frames.

## Constants and magic numbers

- `NUM_PIPES = 3`
- `PIPE_GAP = 48` (rows of clear space between cap_top and cap_bot)
- `GROUND_TOP = 160` (last pipe row + 1)
- `CITY_TOP = 128`, `CITY_BOTTOM = 160`
- `BIRD_X = 8` (fixed bird column)
- Each pipe is 4 cells wide: L (byte_x-1), M1 (byte_x), M2 (byte_x+1), R (byte_x+2)
- Each pipe occupies cols byte_x-1 through byte_x+2. Visible playfield = cols 4..27. Cols 0-3 = left buffer (invisible via attr), cols 28-31 = right buffer.
- byte_x cycles: 29 (recycled at right edge) → ... → 1 (about to leave left edge) → recycle to 29.
- Phase: 8 sub-byte phases (0..7), advances by 2 per frame, wraps to 0 every 4 frames triggering byte_x decrement.
- Active list count: 336 = 3 pipes × 112 emit rows = 3 × (160 - PIPE_GAP) = 336. Fixed.

## Joffa-style principles (per project memory)

The user values these principles strongly:
- Pre-compute everything possible.
- No per-line branches at render time.
- Sorted cursors, race-the-beam timing.
- SMC code-gen.
- Mathematical, not heuristic. No "accept compromise."
- Visual quality is the spec — never propose accepting visual glitches.

The recycle pause is a real concern because it breaks the smoothness. The recommended Steps 1+2 above address it without compromising the visual.
