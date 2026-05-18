# Flicker / tearing / halt-miss fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** eliminate the three connected timing defects in the Speccy Flappy Bird pipe render — bird flicker, top-of-screen tearing, and the occasional halt-miss on recycle frames — by applying three coordinated changes from the design spec at `docs/superpowers/specs/2026-05-18-flicker-tearing-fix-design.md`.

**Architecture:** Three changes shipped across five phases. Each phase ends in a clean build and a playable game. (1) Add a trailing zero byte to every pipe stamp, removing the deferred-clear and gap-clear machinery entirely. (2) Move bird ops into top blanking so all writes land before raster reaches them. (3) Add a fourth pipe slot column; gradually prepare new pipe configurations across many frames so recycle never spikes the frame budget.

**Tech Stack:** Z80 assembly, sjasmplus, ZX Spectrum 48K, single-file project (`src/main.asm`).

---

## Background a developer new to this codebase needs

- **Toolchain:** assemble with `make` (drives `tools/sjasmplus/sjasmplus --fullpath src/main.asm`). Successful build prints `Errors: 0, warnings: 0`. Run via `make run` (opens `build/main.sna` in Fuse). You can't run the emulator — the human does.
- **Frame timing:** 70,000 T-states per frame at 50 Hz. Halt fires at start of vsync. Top blanking is the first ~14 k T (before raster reaches visible row 0). Visible scan T=14 k to T=56.8 k. Bottom blanking T=56.8 k to T=70 k.
- **PIPE_PROGRAM** is SMC machine code at `$DB00`. It's called every frame from `redraw_pipes_v2`. It walks 160 rows; each row stamps body bytes for each of (currently) 3 pipes via SP-hijack `push` instructions.
- **Slot:** the 5-byte block of machine code at one (row, pipe) cell of PIPE_PROGRAM. Currently `$31 lo hi $D5 $C5` = `ld sp,target ; push de ; push bc`.
- **CAP_BLOCK** at `$C320` is the 250-byte template (cap_top + 48 skips + cap_bot) stamped at the cap rows when a pipe is configured.
- **`configure_pipe_slots`** is the per-pipe rewrite that rebuilds the slot grid for a new gap_y on each recycle. Costs ~30 k T-states — this is the recycle spike we want to eliminate.
- **CLAUDE.md** at repo root contains the hard performance rules and T-state cost table. **Read it.**

**Critical Z80 cost references** (from CLAUDE.md):
- `push rr` / `pop rr`: 11 T / 10 T
- `ld sp, hl`: 6 T; `ld sp, nn`: 10 T
- `add hl, hl`: 11 T
- `ldi`: 16 T per byte
- `ld (nn), a`: 13 T

---

## File map

This refactor lives entirely in **`src/main.asm`** (the project is single-file). No files created or deleted, no other files modified. The change touches the following regions of `src/main.asm`:

| Region | Purpose | Why touched |
|---|---|---|
| Constants (top) | `SLOT_STRIDE`, `SLOT_ROW_STRIDE`, `SLOT_GRID_END`, `NUM_PIPES`, `ACTIVE_PIPE_*` | Slot format & 4-pipe expansion |
| `pipe_state` | Per-pipe `(byte_x, gap_y)` array | Grow 3 → 4 entries |
| `build_slot_templates` | Init-time BODY_TEMPLATE, CAP_BLOCK, CAP_TARGET_TABLE generation | New 6-byte body template; new target offsets |
| `init_slot_addr_table` | Pre-compute slot addresses for every (row, pipe) | New stride |
| `init_pipe_program` | Initial slot-grid emission | New 6-byte slots; HL=0 setup; 4 pipes |
| `redraw_pipes_v2` | Per-frame PIPE_PROGRAM entry | HL=0 setup (Phase 1); 4-pipe BC/DE/HL load (Phase 3) |
| `cap_top_handler_pipe_X` / `cap_bot_handler_pipe_X` | SMC cap handlers | Extra `push hl` (Phase 1); new pipe-3 handlers (Phase 3) |
| `configure_pipe_slots` | Per-recycle slot rewrite | New slot format (Phase 1); becomes single-frame, called only at init in Phase 3 |
| `wrap_byte_x` | Per-phase-wrap byte_x dec & recycle | Stop setting `clear_pending` (Phase 1); trigger swap instead of recycle (Phase 5) |
| `main_loop` | Frame dispatcher | Remove `do_deferred_clears` call (Phase 1); move bird ops to top blanking (Phase 2); add `prep_step` call (Phase 4) |
| `frame_update` | Per-frame work | Drop bird ops (Phase 2) |
| `do_deferred_clears`, `clear_pipe_col`, `paint_restore`, `run_gap_clear` | Old clear infrastructure | Delete (Phase 1) |
| New: `prep_step` | Incremental-prepare state machine | New in Phase 4 |

---

## Phase 1: Extra-empty-byte slot + remove clear infrastructure

**Goal:** every pipe stamp writes 6 bytes (4 body + 2 trailing zeros). Deferred-clear and gap-clear infrastructure is deleted. Still 3 pipes. Bird still in CYAN region. The game looks the same to the player; the architecture is simpler.

### Task 1.1: Update slot encoding constants

**Files:**
- Modify: `src/main.asm` constants block (~lines 38-67)

- [ ] **Step 1.1.1: Read the current constants**

Open `src/main.asm` and find these lines (around line 38):
```asm
SLOT_GRID_BASE         EQU $DB00
SLOT_GRID_END          EQU SLOT_GRID_BASE + 160 * 16   ; $E500
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

SLOT_ROW_STRIDE        EQU 16          ; 1 (exx) + 3*5
SLOT_STRIDE            EQU 5
```

- [ ] **Step 1.1.2: Update the constants**

Replace with:
```asm
SLOT_GRID_BASE         EQU $DB00
SLOT_GRID_END          EQU SLOT_GRID_BASE + 160 * SLOT_ROW_STRIDE   ; Phase 1: $DB00 + 160*20 = $E380
PIPE_PROGRAM           EQU SLOT_GRID_BASE              ; entry point alias

; Phase 1: 1 EXX + 3 * 6-byte slots = 19 bytes/row; pad to 20 for fast row*20 indexing.
; Slot format: $31 lo hi $E5 $D5 $C5  =  ld sp,target ; push hl ; push de ; push bc
; HL is set to $0000 once at PIPE_PROGRAM entry; the extra push HL writes the
; trailing-zero pair that replaces the old deferred-clear mechanism.
SLOT_ROW_STRIDE        EQU 20          ; 1 (exx) + 3*6 + 1 pad
SLOT_STRIDE            EQU 6
```

- [ ] **Step 1.1.3: Build and confirm errors are localised**

Run `make` from project root. Expected output: errors will refer to subsequent code that still uses the old SLOT_STRIDE = 5 assumption. We'll fix those in the next tasks. Do NOT commit yet.

If the build succeeds, great — that means no current code hard-codes 16 or 5 in a way the assembler caught; but human review is still required in subsequent tasks. Note any errors and we'll address them.

### Task 1.2: Rewrite `build_slot_templates`

**Files:**
- Modify: `src/main.asm` — the `build_slot_templates` routine (find `^build_slot_templates:`)

- [ ] **Step 1.2.1: Find the routine**

Run: `grep -n "^build_slot_templates:" src/main.asm`
Expected: one line ~`build_slot_templates:`.

- [ ] **Step 1.2.2: Locate and read the body-template section**

Read 25 lines starting at the `^build_slot_templates:` line. The first inner loop emits body slots — currently writes `$31, lo, hi, $D5, $C5` (5 bytes) per row.

- [ ] **Step 1.2.3: Replace the body-template loop body**

Replace the 5-byte body slot emission with a 6-byte version. Find the loop labelled `.bst_body_lp:` and replace its body with:

```asm
.bst_body_lp:
        ld      a, $31                          ; opcode: ld sp, nn
        ld      (de), a
        inc     de
        ld      a, (hl)                         ; line_table[R].lo
        add     a, 34                           ; Phase 1: +34 = byte_x=29 + 5 offset (was +32)
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)                         ; line_table[R].hi
        adc     a, 0                            ; carry from +34
        ld      (de), a
        inc     de
        inc     hl
        ld      a, $E5                          ; opcode: push hl  (Phase 1: NEW)
        ld      (de), a
        inc     de
        ld      a, $D5                          ; opcode: push de
        ld      (de), a
        inc     de
        ld      a, $C5                          ; opcode: push bc
        ld      (de), a
        inc     de
        djnz    .bst_body_lp
```

- [ ] **Step 1.2.4: Replace the cap-block emission**

Find the `; ─── Fill CAP_BLOCK ─` section. The cap_top stub currently writes `$C3, 0, 0, 0, 0` (5 bytes). For a 6-byte slot it becomes `$C3, 0, 0, 0, 0, 0` (6 bytes). The 48 skip rows go from `5 NOPs × 48 = 240 bytes` to `6 NOPs × 48 = 288 bytes`. Cap_bot stub also grows to 6 bytes.

Locate the existing cap_top stub emission:

```asm
ld      hl, CAP_BLOCK
ld      (hl), $C3                       ; cap_top stub
inc     hl
ld      b, 4                            ; remaining cap_top bytes (0, 0, 0, 0)
.bst_cap_top_zero:
ld      (hl), 0
inc     hl
djnz    .bst_cap_top_zero
; 48 skip rows × 5 bytes = 240 zero bytes
ld      b, 240
.bst_cap_skip_lp:
ld      (hl), 0
inc     hl
djnz    .bst_cap_skip_lp
; cap_bot stub
ld      (hl), $C3
inc     hl
ld      b, 4
.bst_cap_bot_zero:
ld      (hl), 0
inc     hl
djnz    .bst_cap_bot_zero
```

Replace with:

```asm
ld      hl, CAP_BLOCK
ld      (hl), $C3                       ; cap_top stub: jp nn opcode
inc     hl
ld      b, 5                            ; remaining cap_top bytes (now 5: jp target lo, hi, then 3 pad)
.bst_cap_top_zero:
ld      (hl), 0
inc     hl
djnz    .bst_cap_top_zero
; 48 skip rows × 6 bytes = 288 zero bytes
ld      b, 0                            ; B=0 means 256 iterations; use BC counter instead
ld      bc, 288
.bst_cap_skip_lp:
ld      (hl), 0
inc     hl
dec     bc
ld      a, b
or      c
jr      nz, .bst_cap_skip_lp
; cap_bot stub
ld      (hl), $C3
inc     hl
ld      b, 5
.bst_cap_bot_zero:
ld      (hl), 0
inc     hl
djnz    .bst_cap_bot_zero
```

- [ ] **Step 1.2.5: Update CAP_BLOCK size constant in the layout EQU block**

Find at top of file:
```asm
CAP_BLOCK              EQU BODY_TEMPLATE + 800            ; $C320..$C419
CAP_TARGET_TABLE       EQU CAP_BLOCK + 250                ; $C41A..$C449
TEMPLATE_END           EQU CAP_TARGET_TABLE + 48          ; $C44A
```

`BODY_TEMPLATE` is `160 × 5 = 800` bytes today; goes to `160 × 6 = 960` bytes. `CAP_BLOCK` is `50 × 5 = 250` bytes today; goes to `50 × 6 = 300` bytes. Replace with:
```asm
CAP_BLOCK              EQU BODY_TEMPLATE + 960            ; Phase 1: 160 rows × 6 bytes/slot
CAP_TARGET_TABLE       EQU CAP_BLOCK + 300                ; Phase 1: 50 rows × 6 bytes/slot
TEMPLATE_END           EQU CAP_TARGET_TABLE + 48
```

- [ ] **Step 1.2.6: Update the `cap_top_target_target` offset in `build_slot_templates`**

Find the `.bst_ctt_lp:` section. The current code does:
```asm
ld      a, e
add     a, 32                           ; +32 for byte_x=29 (29+3 offset)
ld      (ix+0), a
ld      a, d
adc     a, 0
ld      (ix+1), a
```

And similarly for `(ix+2)`, `(ix+3)`. Change both `add a, 32` lines to `add a, 34` (= byte_x=29 + 5 = 34). The target is now `line_addr + byte_x + 5` instead of `+3`.

- [ ] **Step 1.2.7: Build**

Run: `make 2>&1 | tail -5`
Expected: `Errors: 0, warnings: 0`. If errors, read them and fix the corresponding spots before proceeding.

### Task 1.3: Update `screen_target_table_29`

**Files:**
- Modify: `src/main.asm` — `init_screen_target_table` and the comment above it

- [ ] **Step 1.3.1: Find the routine**

Run: `grep -n "init_screen_target_table" src/main.asm | head -3`

- [ ] **Step 1.3.2: Update the offset**

Read 30 lines starting at `^init_screen_target_table:`. It computes `targets[row] = line_table[row] + 32`. Change `add a, 32` (and its surrounding comment) to `add a, 34`. Update the header comment:

```asm
; targets[row] = line_table[row] + 34 (= byte_x=29 + 5)
```

- [ ] **Step 1.3.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.4: Update `init_pipe_program` for 6-byte slots

**Files:**
- Modify: `src/main.asm` — `init_pipe_program`

- [ ] **Step 1.4.1: Find the routine**

Run: `grep -n "^init_pipe_program:" src/main.asm`

- [ ] **Step 1.4.2: Update the per-pipe-slot inner loop**

Read 40 lines starting at the routine. Find the inner loop that emits one slot per pipe:
```asm
ld      (iy+0), $31
ld      (iy+1), l
ld      (iy+2), h
ld      (iy+3), $D5             ; push de
ld      (iy+4), $C5             ; push bc
ld      de, SLOT_STRIDE
add     iy, de
```

Replace with a 6-byte version:
```asm
ld      (iy+0), $31
ld      (iy+1), l
ld      (iy+2), h
ld      (iy+3), $E5             ; push hl  (Phase 1: NEW)
ld      (iy+4), $D5             ; push de
ld      (iy+5), $C5             ; push bc
ld      de, SLOT_STRIDE
add     iy, de
```

(`SLOT_STRIDE` is now 6 from Task 1.1; the `add iy, de` is automatically correct.)

- [ ] **Step 1.4.3: Update the screen_target offset in the same routine**

Earlier in `init_pipe_program`, the body emits `screen_target = line_table[row] + byte_x + 3`. Find:
```asm
ld      a, (hl)                 ; A = byte_x[C]
add     a, 3                    ; +3 for stack-blast offset
```

Change to:
```asm
ld      a, (hl)                 ; A = byte_x[C]
add     a, 5                    ; +5 for stack-blast offset (4 body + 2 trail bytes)
```

- [ ] **Step 1.4.4: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.5: Update `init_slot_addr_table` for 6-byte slot stride

**Files:**
- Modify: `src/main.asm` — `init_slot_addr_table`

- [ ] **Step 1.5.1: Find the routine**

Run: `grep -n "^init_slot_addr_table:" src/main.asm`

- [ ] **Step 1.5.2: Update row stride and pipe stride**

The routine builds a lookup of `slot[row][pipe]` addresses. It uses `add hl, hl` four times to compute `row × 16`. We now need `row × 20` (the new SLOT_ROW_STRIDE).

Find the line `add hl, hl` (4 of them in sequence; it's `; HL = row × 16`).

Replace those 4 add-hl-hl lines with the 5-line block that computes `row × 20`:

```asm
        add     hl, hl                          ; row*2
        add     hl, hl                          ; row*4
        ld      d, h
        ld      e, l                            ; DE = row*4
        add     hl, hl                          ; row*8
        add     hl, hl                          ; row*16
        add     hl, de                          ; HL = row*20
```

Find `ld c, SLOT_STRIDE` in the same routine (the per-pipe stride within a row). `SLOT_STRIDE` is now 6 from Task 1.1; no change needed.

- [ ] **Step 1.5.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.6: Update `configure_pipe_slots` for 6-byte slots

**Files:**
- Modify: `src/main.asm` — `configure_pipe_slots`

- [ ] **Step 1.6.1: Read the slot-stamp loops**

Run: `grep -n "ldi" src/main.asm | head -10`
The body-stamp loops in `configure_pipe_slots` use 5 `ldi`s in sequence to copy each slot. We need 6.

- [ ] **Step 1.6.2: Update `.cps_body_a_lp`**

Find `.cps_body_a_lp:`. The loop body has 5 `ldi` instructions:
```asm
.cps_body_a_lp:
        ldi
        ldi
        ldi
        ldi
        ldi
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 5
        add     hl, de
        ex      de, hl
        pop     hl
        dec     iyl
        jr      nz, .cps_body_a_lp
```

Replace with 6 ldis and update the post-loop arithmetic (`SLOT_ROW_STRIDE - 6` instead of `- 5`):
```asm
.cps_body_a_lp:
        ldi
        ldi
        ldi
        ldi
        ldi
        ldi
        push    hl
        ld      hl, SLOT_ROW_STRIDE - 6
        add     hl, de
        ex      de, hl
        pop     hl
        dec     iyl
        jr      nz, .cps_body_a_lp
```

- [ ] **Step 1.6.3: Update `.cps_body_b_lp` the same way**

Same loop pattern. Find `.cps_body_b_lp:` and apply the same edit (add a 6th `ldi`, change `SLOT_ROW_STRIDE - 5` to `- 6`).

- [ ] **Step 1.6.4: Update `.cps_cap_stamp_lp` the same way**

Find `.cps_cap_stamp_lp:`. Same edit (6 ldis, stride -6).

- [ ] **Step 1.6.5: Update `(cap_bot_row+1) * 5` arithmetic to `* 6`**

Find lines in `configure_pipe_slots` that compute `BODY_TEMPLATE + (cap_bot_row+1) * 5`. The comment will say "× 5". Read 10 lines around them; there's a `add hl, hl` chain that computes `*5`. Update to `*6`.

Concrete location: search for `; HL = (cap_bot_row+1) * 5` in the file and update the surrounding code:

```asm
; HL = (cap_bot_row+1) * 5
... existing arithmetic ...
```

Look for the pattern:
```asm
add     hl, hl                          ; HL = (cap_bot_row+1) * 2
add     hl, hl                          ; HL = (cap_bot_row+1) * 4
ld      e, a
ld      d, 0
add     hl, de                          ; HL = (cap_bot_row+1) * 5
ld      de, BODY_TEMPLATE
add     hl, de
```

Replace with:
```asm
ld      d, h
ld      e, l                            ; DE = (cap_bot_row+1)
add     hl, hl                          ; HL = (cap_bot_row+1) * 2
add     hl, hl                          ; HL = (cap_bot_row+1) * 4
add     hl, de                          ; HL = (cap_bot_row+1) * 5
add     hl, de                          ; HL = (cap_bot_row+1) * 6
ld      de, BODY_TEMPLATE
add     hl, de
```

Wait — re-read the existing code carefully before applying. The structure may differ. Make sure you preserve any A/E moves between operations.

- [ ] **Step 1.6.6: Update Step 3 (`SLOT_GRID_BASE + 2`) cap-handler patching**

Find `SLOT_GRID_BASE + 2` in `configure_pipe_slots` — there are two of them (cap_top, cap_bot). They locate the JP target imm at `slot + 1` (skipping the JP opcode). No change needed (still offset 2 within the 6-byte slot).

- [ ] **Step 1.6.7: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.7: Update `redraw_pipes_v2` for HL=0 setup

**Files:**
- Modify: `src/main.asm` — `redraw_pipes_v2`

- [ ] **Step 1.7.1: Find the entry to PIPE_PROGRAM**

Run: `grep -n "call.*PIPE_PROGRAM" src/main.asm`
Expected: one match, inside `redraw_pipes_v2`.

- [ ] **Step 1.7.2: Add HL=0 before the call**

Read 20 lines before the `call PIPE_PROGRAM` line. You'll find the setup that loads BC/DE/BC'/DE' with body bitmap bytes. Just before `call PIPE_PROGRAM`, add `ld hl, 0`:

Before:
```asm
        ld      (saved_sp), sp
        call    PIPE_PROGRAM
        ret
```

After:
```asm
        ld      hl, 0                   ; Phase 1: extra push HL writes trailing-zero pair per slot
        ld      (saved_sp), sp
        call    PIPE_PROGRAM
        ret
```

- [ ] **Step 1.7.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.8: Update cap handlers to include extra `push hl`

**Files:**
- Modify: `src/main.asm` — the six cap handlers (`cap_top_handler_pipe_0` through `cap_bot_handler_pipe_2`)

- [ ] **Step 1.8.1: Find the cap handlers**

Run: `grep -n "^cap_top_handler_pipe_\|^cap_bot_handler_pipe_" src/main.asm`

- [ ] **Step 1.8.2: Update each of the six handlers**

The current handler structure (using `cap_top_handler_pipe_0` as example):
```asm
cap_top_handler_pipe_0:
cap_top_handler_pipe_0_target EQU $+1
        ld      sp, $0000
cap_top_handler_pipe_0_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_0_bc EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_0_next EQU $+1
        jp      $0000
```

Add an extra `push hl` (writing the trailing-zero pair) right after `ld sp, $0000`. Since HL=0 is the invariant maintained by `redraw_pipes_v2`, the value pushed is `$0000`. But the handler then proceeds to LOAD HL with M2/R, push, LOAD with L/M1, push — these calls overwrite HL.

We need to push the trailing zero FIRST (before HL is loaded with cap bytes), and THEN restore HL=0 at the end before `jp _next`.

Replace each handler with the 17-byte version:

```asm
cap_top_handler_pipe_0:
cap_top_handler_pipe_0_target EQU $+1
        ld      sp, $0000               ; SP = target
        push    hl                       ; Phase 1: HL=0 → writes trailing zero pair
cap_top_handler_pipe_0_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_0_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0                    ; Phase 1: restore HL=0 invariant before falling through
cap_top_handler_pipe_0_next EQU $+1
        jp      $0000
```

That adds `push hl` (1 byte) and `ld hl, 0` (3 bytes) per handler = +4 bytes per handler. The EQU labels referencing `$+1` still resolve correctly (the assembler computes them at the new positions).

Apply the same edit to all six handlers (top × 3, bot × 3).

- [ ] **Step 1.8.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 1.9: Verify Phase 1 builds and runs

- [ ] **Step 1.9.1: Build clean**

Run: `make 2>&1 | tail -5`
Expected: `Errors: 0, warnings: 0`. If errors, read them and fix before proceeding.

- [ ] **Step 1.9.2: Ask user to test**

Tell the user: "Phase 1 (extra-empty-byte body slots, plus extra-byte cap handlers) is built. Please `make run` and verify the game still looks identical to before — pipes should render correctly. The trailing-zero pair is invisible (writes to buffer cols). Don't worry about the flicker/tearing — those will be fixed in Phases 2 and 3."

- [ ] **Step 1.9.3: Commit**

```bash
git add src/main.asm
git commit -m "phase 1a: pipe slots write 6 bytes (4 body + 2 trailing zero)

Per spec docs/superpowers/specs/2026-05-18-flicker-tearing-fix-design.md:
adds a push HL (HL=0) to every pipe stamp so the trailing-zero pair
clears the column the pipe is about to leave. This is the prerequisite
for removing the deferred-clear / gap-clear infrastructure.

  - SLOT_STRIDE 5→6, SLOT_ROW_STRIDE 16→20 (pad to 20 for row*20 indexing)
  - SLOT_GRID_END recomputed (BODY_TEMPLATE 800→960, CAP_BLOCK 250→300)
  - Body slots emit \$31 lo hi \$E5 \$D5 \$C5 (was \$31 lo hi \$D5 \$C5)
  - Target offset shifted from +3 to +5 (4 body + 2 trail bytes)
  - All 6 cap handlers get a leading 'push hl' and trailing 'ld hl, 0' to
    preserve HL=0 across calls
  - redraw_pipes_v2 sets HL=0 once before each PIPE_PROGRAM call

Phase 1b will remove the now-redundant deferred-clear and gap-clear code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.10: Remove deferred-clear and gap-clear infrastructure

**Files:**
- Modify: `src/main.asm` — multiple regions

- [ ] **Step 1.10.1: Remove `do_deferred_clears` routine**

Run: `grep -n "^do_deferred_clears:" src/main.asm`

Find the entire `do_deferred_clears` routine (from the label down to its `ret`). Delete it. Also delete its surrounding comment header (~10 lines of `;...`).

- [ ] **Step 1.10.2: Remove call to `do_deferred_clears` from `main_loop`**

Find:
```asm
ld      a, (clear_pending)
or      a
call    nz, do_deferred_clears
```

Delete those three lines from `main_loop` (search by `clear_pending`).

- [ ] **Step 1.10.3: Remove `clear_pending` set in `wrap_byte_x`**

Find:
```asm
ld      a, 1
ld      (clear_pending), a      ; signal next frame's top blanking to clear OLD R cols
```

Delete those two lines from `wrap_byte_x`.

- [ ] **Step 1.10.4: Remove `clear_pipe_col` routine**

Run: `grep -n "^clear_pipe_col:" src/main.asm`. Find the routine and delete it (label + body up to `ret`/`jp paint_restore`).

- [ ] **Step 1.10.5: Remove `paint_restore` routine**

Run: `grep -n "^paint_restore:" src/main.asm`. Find it, delete it.

- [ ] **Step 1.10.6: Remove `clear_pending` state byte**

Find:
```asm
clear_pending: db 0
```

Delete that line and its trailing comment (`; set by wrap_byte_x; consumed by NEXT...`).

- [ ] **Step 1.10.7: Remove `gap_clear_pending`, `gap_clear_pipe_idx` bytes**

Find:
```asm
gap_clear_pending: db 0
...
gap_clear_pipe_idx: db 0
```

Delete those lines including their multi-line comments.

- [ ] **Step 1.10.8: Remove `run_gap_clear` routine**

Run: `grep -n "^run_gap_clear:" src/main.asm`. Find it, delete it including its header comment.

- [ ] **Step 1.10.9: Remove call to `run_gap_clear` from `main_loop`**

Find the block in `main_loop`'s CYAN region:
```asm
ld      a, (gap_clear_pending)
or      a
jr      z, .no_gap_clear
dec     a
ld      (gap_clear_pending), a
or      a
call    z, run_gap_clear
.no_gap_clear:
```

Delete that block.

- [ ] **Step 1.10.10: Remove `gap_clear_pending=2` set in `configure_pipe_slots`**

Find in `configure_pipe_slots`:
```asm
; ─── Step 8: queue a gap-clear for the NEXT frame.
...
ld      a, (cps_pipe)
ld      (gap_clear_pipe_idx), a
ld      a, 2
ld      (gap_clear_pending), a
```

Delete that whole block (including its header comment).

- [ ] **Step 1.10.11: Build**

Run: `make 2>&1 | tail -5`
Expected: `Errors: 0, warnings: 0`. If you get "undefined symbol" errors for `clear_pending`, `gap_clear_pending`, etc., you missed a reference — `grep` for them and remove.

Run: `grep -n "clear_pending\|gap_clear_pending\|gap_clear_pipe_idx\|do_deferred_clears\|clear_pipe_col\|paint_restore\|run_gap_clear" src/main.asm`
Expected: ZERO matches.

- [ ] **Step 1.10.12: Visual test**

Tell user: "Phase 1b: deferred-clear / gap-clear infrastructure removed. The trailing-zero pair in every pipe stamp now does that work. Please `make run` and confirm pipes still render correctly — no stale columns, no leftover pixels behind pipes, no leftover body bytes in gap regions after a pipe recycles."

- [ ] **Step 1.10.13: Commit**

```bash
git add src/main.asm
git commit -m "phase 1b: remove deferred-clear and gap-clear infrastructure

The trailing-zero pair added in phase 1a (commit \$PHASE1A_SHA)
naturally clears each column as a pipe scrolls past it. The whole
deferred-clear + gap-clear bookkeeping is now redundant:

  - do_deferred_clears, clear_pipe_col, paint_restore routines: deleted
  - run_gap_clear routine: deleted
  - clear_pending, gap_clear_pending, gap_clear_pipe_idx state bytes: deleted
  - wrap_byte_x stops setting clear_pending
  - main_loop stops checking clear_pending and gap_clear_pending
  - configure_pipe_slots stops queueing gap_clear

Net effect: same on-screen output, smaller and simpler code path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2: Bird ops in top blanking

**Goal:** move bird ops from CYAN (end of frame) to top blanking (start of frame, before PIPE_PROGRAM). All bird writes complete before raster reaches row 0 → uniform 0-frame lag → no flicker. PIPE_PROGRAM still races the beam fine; with deferred-clear gone, it has the entire 14 k T of top blanking minus bird ops (~8.5 k T head start over raster).

### Task 2.1: Move bird ops from CYAN to top blanking

**Files:**
- Modify: `src/main.asm` — `main_loop`

- [ ] **Step 2.1.1: Find the current bird-ops block in CYAN**

Run: `grep -n "call    restore_bird_bg" src/main.asm`
Expected: one match, inside `main_loop`'s CYAN region. The block currently looks like:
```asm
        ; Bird ops in CYAN (= end of frame, after raster has scanned visible
        ; area). Writes land BEFORE next frame's raster reaches them ...
        call    restore_bird_bg
        call    restore_bird_attrs
        call    read_input
        call    update_bird
        call    advance_bird_anim
        call    draw_bird
        call    paint_bird_attrs
        ei
        jr      main_loop
```

- [ ] **Step 2.1.2: Cut the bird-ops block out of CYAN**

Delete those 7 `call` lines (keep `ei` and `jr main_loop`). Also update the comment to reflect the new architecture:
```asm
        ; Phase 2: bird ops moved to top blanking. CYAN is now for
        ; update_cap_imm_v2 (already above) and any background work.
        ei
        jr      main_loop
```

- [ ] **Step 2.1.3: Insert the bird-ops block in top blanking**

Find the start of `main_loop`:
```asm
main_loop:
        halt                            ; wait for vsync interrupt
        di
        ld      a, 2                    ; PROFILE: RED = top blanking work + render
        out     ($fe), a
        call    frame_update
```

Replace the `call frame_update` line with the bird ops + frame_update sequence:
```asm
main_loop:
        halt                            ; wait for vsync interrupt
        di
        ld      a, 2                    ; PROFILE: RED = top blanking
        out     ($fe), a
        ; Phase 2: bird ops run BEFORE PIPE_PROGRAM in top blanking.
        ; All bird writes complete before raster reaches row 0, so the
        ; bird is visible same-frame at every Y with no flicker.
        ; PIPE_PROGRAM still has ~8 k T head start over the raster.
        call    restore_bird_bg
        call    restore_bird_attrs
        call    read_input
        call    update_bird
        call    advance_bird_anim
        call    draw_bird
        call    paint_bird_attrs
        ld      a, 3                    ; PROFILE: MAGENTA = PIPE_PROGRAM
        out     ($fe), a
        call    frame_update
```

(The MAGENTA border marker is the existing one used to profile PIPE_PROGRAM — keep the existing profile colour scheme.)

- [ ] **Step 2.1.4: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

- [ ] **Step 2.1.5: Visual test**

Tell user: "Phase 2: bird ops moved to top blanking. Please `make run` and verify:
- Bird at top of screen: no flicker as it moves
- Pipes: no tearing on top rows
- The pipe-vs-bird overlap visual: bird passes BEHIND pipes when their cols intersect (this is the expected trade-off; pipes drawn after bird means pipes win at overlap)"

- [ ] **Step 2.1.6: Commit**

```bash
git add src/main.asm
git commit -m "phase 2: bird ops in top blanking (no more flicker)

Move the entire bird ops chain (restore_bird_bg through paint_bird_attrs)
from main_loop's CYAN region to its RED region, before frame_update.
With deferred_clears gone, top blanking has ~14 k T budget. Bird ops
take ~5.5 k T and complete before raster reaches row 0 → uniform 0-frame
lag at every bird Y, no flicker.

PIPE_PROGRAM start moves to T~5.6 k (bird ops time), still well ahead of
raster which reaches row 0 at T=14 k. ~8 k T head start; no tearing.

Trade-off: bird is drawn before pipes, so at byte_x in 5..11 (pipe cols
overlap bird cols 7-9) the pipe stamps over the bird → bird passes
behind pipes at the overlap. Better than flicker.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3: Expand to 4 slot columns (4th pipe inert)

**Goal:** PIPE_PROGRAM has 4 slot columns per row. Slot 3 (the 4th) is filled with NOPs at init and at every frame end. PIPE_PROGRAM executes all 4 columns but slot 3 does nothing. Game still works with 3 active pipes.

Phase 3 lays the structural foundation for Phases 4 (prep state machine) and 5 (swap on byte_x=1). After Phase 3 the game looks identical to Phase 2 but the architecture supports the 4th pipe.

### Task 3.1: Expand NUM_PIPES and slot grid constants

**Files:**
- Modify: `src/main.asm` constants block

- [ ] **Step 3.1.1: Update NUM_PIPES**

Find:
```asm
NUM_PIPES   EQU 3
```
Change to:
```asm
NUM_PIPES   EQU 4
```

- [ ] **Step 3.1.2: Update SLOT_ROW_STRIDE comment**

Find:
```asm
SLOT_ROW_STRIDE        EQU 20          ; 1 (exx) + 3*6 + 1 pad
```
Change to:
```asm
SLOT_ROW_STRIDE        EQU 32          ; 1 (exx) + 4*6 + 7 pad (= power-of-2-ish for row*32 = row << 5)
```

- [ ] **Step 3.1.3: Update SLOT_ADDR_TABLE and ACTIVE_PIPE constants**

Find:
```asm
SLOT_ADDR_TABLE        EQU $F440       ; 480 entries × 2 B = 960 B
SLOT_ADDR_TABLE_END    EQU $F800

ACTIVE_PIPE_0          EQU $FA40
ACTIVE_PIPE_1          EQU ACTIVE_PIPE_0 + 224
ACTIVE_PIPE_2          EQU ACTIVE_PIPE_1 + 224
ACTIVE_LIST_END        EQU ACTIVE_PIPE_2 + 224
ACTIVE_COUNT           EQU 336
```

Replace with:
```asm
SLOT_ADDR_TABLE        EQU $F440       ; Phase 3: 640 entries × 2 B = 1280 B = $500
SLOT_ADDR_TABLE_END    EQU $F940

; ─── Active list (per-pipe sublists) ─────────────────────────────
; Phase 3: 4 pipes × 112 entries × 2 B = 896 B total.
ACTIVE_PIPE_0          EQU $F940       ; (moved up to clear $FC80+ for stack growth)
ACTIVE_PIPE_1          EQU ACTIVE_PIPE_0 + 224
ACTIVE_PIPE_2          EQU ACTIVE_PIPE_1 + 224
ACTIVE_PIPE_3          EQU ACTIVE_PIPE_2 + 224       ; NEW
ACTIVE_LIST_END        EQU ACTIVE_PIPE_3 + 224       ; = $FCC0
ACTIVE_COUNT           EQU 448         ; 4 × 112
```

- [ ] **Step 3.1.4: Update ACTIVE_LIST_NEW and ACTIVE_COUNT_NEW**

If you find:
```asm
ACTIVE_LIST_NEW        EQU ACTIVE_PIPE_0
ACTIVE_COUNT_NEW       ; ... possibly in code
```

Update accordingly. Run `grep -n "ACTIVE_LIST_NEW\|ACTIVE_COUNT_NEW" src/main.asm` and update each occurrence's comment.

- [ ] **Step 3.1.5: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0, but you'll get assembler errors if NUM_PIPES is used in a way that breaks. Address each in subsequent tasks.

### Task 3.2: Expand `pipe_state` to 4 entries

**Files:**
- Modify: `src/main.asm` — `pipe_state` data

- [ ] **Step 3.2.1: Find `pipe_state`**

Run: `grep -n "^pipe_state:" src/main.asm`. Read 10 lines.

Currently:
```asm
pipe_state:
        ; 3 pipes distributed around the 29-step byte_x cycle (byte_x ∈ [1,29]).
        db 29, 64
        db 19, 40
        db  9, 88
```

- [ ] **Step 3.2.2: Add a 4th entry**

Change to:
```asm
pipe_state:
        ; Phase 3: 4 pipes. 3 active + 1 preparing.
        ; Initial spacing: 29, 22, 15, 8 (every 7 byte_x). Last entry starts as
        ; the "preparing" slot — see prep_pipe_idx.
        db 29, 64
        db 22, 40
        db 15, 88
        db  8, 24                       ; 4th pipe (Phase 3 starts inert)
```

- [ ] **Step 3.2.3: Build**

Run: `make 2>&1 | tail -3`

### Task 3.3: Add cap handlers for pipe 3

**Files:**
- Modify: `src/main.asm` — cap handler section

- [ ] **Step 3.3.1: Find existing cap handlers**

Run: `grep -n "^cap_top_handler_pipe_2:\|^cap_bot_handler_pipe_2:" src/main.asm`

- [ ] **Step 3.3.2: Add `cap_top_handler_pipe_3` after pipe_2**

Right after the `cap_top_handler_pipe_2` block, add:
```asm
cap_top_handler_pipe_3:                 ; Phase 3
cap_top_handler_pipe_3_target EQU $+1
        ld      sp, $0000
        push    hl
cap_top_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_top_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0
cap_top_handler_pipe_3_next EQU $+1
        jp      $0000
```

- [ ] **Step 3.3.3: Add `cap_bot_handler_pipe_3` after pipe_2's bot**

Right after `cap_bot_handler_pipe_2`, add the analogous block:
```asm
cap_bot_handler_pipe_3:                 ; Phase 3
cap_bot_handler_pipe_3_target EQU $+1
        ld      sp, $0000
        push    hl
cap_bot_handler_pipe_3_de EQU $+1
        ld      hl, $0000
        push    hl
cap_bot_handler_pipe_3_bc EQU $+1
        ld      hl, $0000
        push    hl
        ld      hl, 0
cap_bot_handler_pipe_3_next EQU $+1
        jp      $0000
```

- [ ] **Step 3.3.4: Extend handler-address dispatch tables**

Find these tables (they live just after the handler bodies):
```asm
cap_top_handler_addrs:
        dw      cap_top_handler_pipe_0
        dw      cap_top_handler_pipe_1
        dw      cap_top_handler_pipe_2
cap_bot_handler_addrs:
        dw      cap_bot_handler_pipe_0
        dw      cap_bot_handler_pipe_1
        dw      cap_bot_handler_pipe_2
```

Append `cap_top_handler_pipe_3` to the first, `cap_bot_handler_pipe_3` to the second:
```asm
cap_top_handler_addrs:
        dw      cap_top_handler_pipe_0
        dw      cap_top_handler_pipe_1
        dw      cap_top_handler_pipe_2
        dw      cap_top_handler_pipe_3
cap_bot_handler_addrs:
        dw      cap_bot_handler_pipe_0
        dw      cap_bot_handler_pipe_1
        dw      cap_bot_handler_pipe_2
        dw      cap_bot_handler_pipe_3
```

- [ ] **Step 3.3.5: Extend the 6 imm-address tables**

There are six tables of pipe-keyed SMC addresses: `cap_top_bc_imm_addrs`, `cap_top_de_imm_addrs`, `cap_bot_bc_imm_addrs`, `cap_bot_de_imm_addrs`, `cap_top_target_imm_addrs`, `cap_bot_target_imm_addrs`, `cap_top_next_imm_addrs`, `cap_bot_next_imm_addrs`. Find them via grep, then append the pipe-3 entry to each:

```asm
cap_top_bc_imm_addrs:
        dw      cap_top_handler_pipe_0_bc
        dw      cap_top_handler_pipe_1_bc
        dw      cap_top_handler_pipe_2_bc
        dw      cap_top_handler_pipe_3_bc           ; NEW
```

(Repeat for each of the 8 tables.)

- [ ] **Step 3.3.6: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 3.4: Update `init_pipe_program` to emit 4 slot columns

**Files:**
- Modify: `src/main.asm` — `init_pipe_program`

- [ ] **Step 3.4.1: Find the per-pipe loop**

Inside `init_pipe_program`, there's a loop `.ipp_pipe_lp` that iterates `c` from 0 to `NUM_PIPES-1`. Since you updated `NUM_PIPES` to 4 in Task 3.1, this loop now iterates 4 times automatically. Verify the comment at the top of the routine matches.

- [ ] **Step 3.4.2: Verify EXX byte still gets written at slot_addr-1**

Read the routine, confirm the `ld a, $D9; ld (de), a` (EXX write) still happens once per row, at `slot[row][0] - 1`. No code change should be needed here — the EXX position is computed from `SLOT_ADDR_TABLE[row*4]` which now uses the new stride.

- [ ] **Step 3.4.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 3.5: Update `init_slot_addr_table` for 4 pipes × stride 32

**Files:**
- Modify: `src/main.asm` — `init_slot_addr_table`

- [ ] **Step 3.5.1: Update row stride to 32 (was 20 in phase 1)**

The current code (after phase 1) computes `row × 20`. Update to `row × 32` (= `row << 5`):

Find the `; HL = row × 20` block and replace:
```asm
        add     hl, hl                          ; row*2
        add     hl, hl                          ; row*4
        ld      d, h
        ld      e, l                            ; DE = row*4
        add     hl, hl                          ; row*8
        add     hl, hl                          ; row*16
        add     hl, de                          ; HL = row*20
```

Replace with:
```asm
        add     hl, hl                          ; row*2
        add     hl, hl                          ; row*4
        add     hl, hl                          ; row*8
        add     hl, hl                          ; row*16
        add     hl, hl                          ; row*32
```

- [ ] **Step 3.5.2: Update inner-loop pipe count**

The inner loop uses `ld b, 3`. Change to `ld b, NUM_PIPES` (which is now 4):
```asm
.write_3_pipes:                                  ; (label can stay; behaviour now writes 4)
        ld      b, NUM_PIPES
.wp_lp:
```

- [ ] **Step 3.5.3: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 3.6: Configure pipe 3 at init with all-NOPs (preparing column)

**Files:**
- Modify: `src/main.asm` — `init_pipes` or new helper

- [ ] **Step 3.6.1: Find `init_pipes`**

Run: `grep -n "^init_pipes:" src/main.asm`. Read the routine.

- [ ] **Step 3.6.2: Loop over all 4 pipes during init**

The init loop currently iterates 3 pipes. Update it to iterate `NUM_PIPES` (= 4). But the 4th pipe is the preparing pipe — its slot column should be NOPs, not body+cap.

Strategy: after the existing 3-pipe init loop, add an explicit "clear pipe 3 slot column to NOPs" pass:

After the existing `.init_cps_lp` loop completes (3 iterations), add:
```asm
        ; Phase 3: pipe 3 is the "preparing" slot column. Init it to all-NOPs.
        ; Slot column 3 at row R is at SLOT_GRID_BASE + 1 + row*32 + 3*6 = +19.
        ; 6 bytes × 160 rows = 960 NOP bytes to write.
        ld      hl, SLOT_GRID_BASE + 1 + 3*6    ; first byte of pipe-3 slot at row 0
        ld      b, 160
.init_pipe3_lp:
        push    bc
        xor     a                                ; A = $00 (NOP)
        ld      b, 6                             ; 6 bytes per slot
.init_pipe3_byte_lp:
        ld      (hl), a
        inc     hl
        djnz    .init_pipe3_byte_lp
        ; Advance HL to pipe-3 slot of next row: HL += (32 - 6) = +26
        ld      bc, 26
        add     hl, bc
        pop     bc
        djnz    .init_pipe3_lp
```

- [ ] **Step 3.6.3: Initialise `prep_pipe_idx`**

Add a new state byte somewhere in the data section (e.g., near `recycled_pipe_idx`):
```asm
prep_pipe_idx:   db 3                ; Phase 3: pipe 3 starts as the preparing column
```

(Used in Phase 4 by `prep_step`.)

- [ ] **Step 3.6.4: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 3.7: Verify Phase 3 builds and runs

- [ ] **Step 3.7.1: Build clean**

Run: `make 2>&1 | tail -5`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 3.7.2: Visual test**

Tell user: "Phase 3: PIPE_PROGRAM now has 4 slot columns. Slot 3 is all-NOPs at init. The game should look IDENTICAL to Phase 2 — 3 visible pipes scrolling, no 4th pipe (because slot 3 is dormant). The frame budget is slightly higher (extra NOP execution per row) but well within margin. Please `make run` and confirm 3 pipes render correctly and the game plays as before."

- [ ] **Step 3.7.3: Commit**

```bash
git add src/main.asm
git commit -m "phase 3: expand to 4 slot columns (4th pipe inert)

Lay the structural groundwork for the prepare-in-advance pipe pipeline:

  - NUM_PIPES 3 → 4
  - SLOT_ROW_STRIDE 20 → 32 (1 EXX + 4*6 + 7 pad; stride 32 for fast
    row << 5 indexing)
  - SLOT_ADDR_TABLE grows to 640 × 2 B
  - ACTIVE_PIPE_3 added (4 × 224 B contiguous active list at \$F940)
  - 6 cap handlers → 8 (added cap_top_handler_pipe_3, cap_bot_handler_pipe_3)
  - All imm-address dispatch tables grow to 4-entry
  - pipe_state grows from 6 B to 8 B (initial: 29,64 / 22,40 / 15,88 / 8,24)
  - init_pipes initialises pipe 3's slot column to all-NOPs (it's the
    'preparing' pipe; rendering is suppressed until Phase 4/5 wire up swap)
  - new prep_pipe_idx state byte (= 3 at init)

Visually identical to Phase 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4: `prep_step` state machine (no swap yet)

**Goal:** every frame, do ~270 T of incremental configure work on the preparing pipe. The work is paced to complete within ~112 frames so that when Phase 5 enables the swap, the preparing pipe is always fully ready. In Phase 4 the swap doesn't fire yet, so the prep work is observable via `bird ops still running fine + no halt miss`, plus the prepared slot column ready to use.

### Task 4.1: Add prep state variables

**Files:**
- Modify: `src/main.asm` — data section

- [ ] **Step 4.1.1: Find the existing state bytes (near `recycled_pipe_idx`, `prep_pipe_idx`)**

Run: `grep -n "recycled_pipe_idx:" src/main.asm`

- [ ] **Step 4.1.2: Add prep state**

Just after `prep_pipe_idx`, add:
```asm
; Phase 4: prep state machine. Each frame, prep_step does a small chunk of
; configure work on prep_pipe_idx's slot column, advancing prep_phase and
; prep_row. When prep_phase reaches "done", the slot column is ready for swap.
prep_phase:      db 0                ; 0..7 = which configure step we're on
prep_row:        db 0                ; 0..159 = current row within current phase
prep_gap_y:      db 8                ; gap_y to use for the preparing pipe (decided at swap time)
```

- [ ] **Step 4.1.3: Build**

Run: `make 2>&1 | tail -3`

### Task 4.2: Implement `prep_step`

**Files:**
- Modify: `src/main.asm` — add new routine

- [ ] **Step 4.2.1: Add the routine**

Place `prep_step` near `configure_pipe_slots`. Implementation sketch:

```asm
;----------------------------------------------------------------
; prep_step: per-frame incremental configure work on the preparing pipe.
; Reads prep_pipe_idx, prep_gap_y, prep_phase, prep_row.
; Phase 4: each frame, do a small chunk of work (target: ~270 T-states).
;
; Phases:
;   0 = stamp body in rows [0..cap_top_row-1]   (advances 5 rows per call)
;   1 = stamp cap_block at rows [cap_top_row..cap_bot_row]  (5 rows/call)
;   2 = stamp body in rows [cap_bot_row+1..159] (5 rows/call)
;   3 = patch cap_top handler address slot       (one-shot)
;   4 = patch cap_bot handler address slot       (one-shot)
;   5 = patch cap target imms                    (one-shot)
;   6 = patch cap _next imms                     (one-shot)
;   7 = rebuild active sublist                   (8 entries per call)
;   8 = done (skip until reset)
;
; The "stamp" work mirrors configure_pipe_slots' Step 1/2 inner loops but
; uses prep_row as the cursor.
;----------------------------------------------------------------
prep_step:
        ld      a, (prep_phase)
        cp      8
        ret     nc                              ; already done; nothing to do this frame

        ; Dispatch by prep_phase
        add     a, a                            ; *2 for word table
        ld      hl, .prep_dispatch
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ex      de, hl
        jp      (hl)

.prep_dispatch:
        dw      .prep_phase0_body_a
        dw      .prep_phase1_cap_block
        dw      .prep_phase2_body_b
        dw      .prep_phase3_handler_top
        dw      .prep_phase4_handler_bot
        dw      .prep_phase5_targets
        dw      .prep_phase6_next
        dw      .prep_phase7_active_list

.prep_phase0_body_a:
        ; Stamp 5 rows of BODY_TEMPLATE into preparing pipe's slot column,
        ; starting at prep_row. Cap at cap_top_row-1.
        ; ... implementation: mirror configure_pipe_slots' Region A loop but
        ; bounded to 5 rows per call, advance prep_row, and if reached
        ; cap_top_row, advance prep_phase.
        ; (Implementation detail: ~200 T per call.)
        ld      a, (prep_gap_y)
        dec     a
        ld      b, a                            ; B = cap_top_row
        ld      a, (prep_row)
        cp      b
        jr      nc, .prep_advance_to_phase1
        ; copy 5 rows starting at prep_row, but not past cap_top_row
        ; (loop body uses ldi-blocks; details mirror configure_pipe_slots)
        ; ...
        ; After loop:
        ld      a, (prep_row)
        add     a, 5
        ld      (prep_row), a
        ret
.prep_advance_to_phase1:
        xor     a
        ld      (prep_row), a
        ld      a, 1
        ld      (prep_phase), a
        ret

        ; Implement .prep_phase1_cap_block similarly: stamp 5 rows of
        ; CAP_BLOCK starting at prep_row, bounded by 50 total rows.
        ; ...
        ; .prep_phase2_body_b: similar to phase0 but rows cap_bot_row+1..159.
        ; .prep_phase3..6: one-shot patches (each takes ~150 T).
        ; .prep_phase7_active_list: 8 entries per call until 112 done.
        ; Each phaseN: when done, set prep_phase = N+1, prep_row = 0, ret.
```

Note: the detailed implementation of each phase mirrors the corresponding step of `configure_pipe_slots`. The plan steps below break each phase into its own subtask.

- [ ] **Step 4.2.2: Implement `.prep_phase0_body_a`**

The full implementation (concrete code with ldi-blocks and source/dest pointers) mirrors `configure_pipe_slots`'s Region A inner loop, but processes 5 rows max per call. See `configure_pipe_slots:` `.cps_body_a_lp:` for the reference loop. Each iteration LDIs 6 bytes (the body slot template), advances HL by `SLOT_ROW_STRIDE - 6`, decrements counter.

Approximate cost: 5 × ~140 T = 700 T per call. (Slightly higher than the 270 T target average; we'll do it less often if needed, or batch differently. The current granularity finishes the body stamps in cap_top_row/5 ≈ 12-19 calls.)

- [ ] **Step 4.2.3: Implement `.prep_phase1_cap_block`, `.prep_phase2_body_b`**

Same pattern as Phase 0 but with CAP_BLOCK as source / different row range.

- [ ] **Step 4.2.4: Implement `.prep_phase3` through `.prep_phase6` (one-shot patches)**

These each mirror the corresponding Step 3/4/5 in `configure_pipe_slots`. They're each ~100-200 T-states and run in a single call.

- [ ] **Step 4.2.5: Implement `.prep_phase7_active_list`**

Mirrors `configure_pipe_slots` Step 6 (the SP-hijack push loop) but processes 8 entries per call. Track progress via `prep_row` (re-used as an entry counter 0..111).

- [ ] **Step 4.2.6: Wire `prep_step` into main_loop's CYAN region**

Find the CYAN region in `main_loop`. After `call update_cap_imm_v2`, add:
```asm
        call    prep_step                       ; Phase 4: incremental prep
```

- [ ] **Step 4.2.7: Build**

Run: `make 2>&1 | tail -3`

### Task 4.3: Initialise prep state at game start

**Files:**
- Modify: `src/main.asm` — `init_pipes`

- [ ] **Step 4.3.1: Reset prep state in `init_pipes`**

At the bottom of `init_pipes`, after the pipe-3 NOP clearing, add:
```asm
        ; Phase 4: prep state — pipe 3 will start preparing for its first
        ; appearance. prep_gap_y comes from pipe_state[3*2+1] = 24 (initial).
        xor     a
        ld      (prep_phase), a
        ld      (prep_row), a
        ld      a, (pipe_state + 3*2 + 1)
        ld      (prep_gap_y), a
```

- [ ] **Step 4.3.2: Build and visual test**

Run: `make 2>&1 | tail -3`

Tell user: "Phase 4: prep_step is running each frame, gradually preparing pipe 3's slot column. The game still shows 3 pipes (pipe 3 hasn't been activated yet — Phase 5 wires up the swap). Verify there's no new flicker, tearing, or visual glitch from the prep work."

- [ ] **Step 4.3.3: Commit**

```bash
git add src/main.asm
git commit -m "phase 4: prep_step state machine (no swap yet)

Add the per-frame incremental-configure routine. Each frame in CYAN,
prep_step does a small chunk of work building out pipe 3's slot column:

  - phase 0: stamp body template at rows [0..cap_top_row-1] (5 rows/frame)
  - phase 1: stamp cap_block at cap rows (5 rows/frame)
  - phase 2: stamp body template at rows [cap_bot_row+1..159] (5 rows/frame)
  - phase 3-6: one-shot patches for handler addresses, target imms,
    _next imms
  - phase 7: rebuild pipe-3's active sublist (8 entries/frame)

Total ~112 frames to fully prepare. Game still uses 3 active pipes; pipe 3's
slot column is being filled but its slots' targets remain at their default
values (= ROM-pointing on init); writes are silent.

Phase 5 will wire up the swap that activates the prepared pipe when an
active pipe reaches byte_x=1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5: Swap on byte_x=1 (4-pipe rotation live)

**Goal:** when an active pipe reaches `byte_x=1`, swap it with the preparing pipe. The previously preparing pipe becomes active and starts scrolling from byte_x=29. The departed pipe becomes the new preparing slot; reset its prep state and start preparing it with a fresh random gap_y. From now on, recycle is O(1) — no spike.

### Task 5.1: Modify `wrap_byte_x` to trigger swap instead of recycle

**Files:**
- Modify: `src/main.asm` — `wrap_byte_x`

- [ ] **Step 5.1.1: Find `wrap_byte_x`**

Run: `grep -n "^wrap_byte_x:" src/main.asm`

- [ ] **Step 5.1.2: Replace the `.recycle` branch with a swap branch**

Current logic recycles in-place: picks new gap_y, sets byte_x=29, queues configure. Replace it so it instead invokes `do_swap` (a new routine added below).

```asm
.outer:
        ld      a, (iy+0)
        cp      1
        jr      z, .swap_with_prep
        dec     a
        jr      .save
.swap_with_prep:
        ; Phase 5: this pipe has reached byte_x=1. Swap with the prep pipe.
        push    bc
        push    iy
        ld      a, NUM_PIPES
        sub     b                                ; A = current pipe index
        call    do_swap                          ; swap pipe A with prep_pipe_idx
        pop     iy
        pop     bc
        ld      a, 29                            ; the (former) prep pipe takes our place at byte_x=29
.save:
        ld      (iy+0), a
        ...
```

- [ ] **Step 5.1.3: Implement `do_swap`**

Add a new routine. Sketch:

```asm
;----------------------------------------------------------------
; do_swap: pipe `A` has reached byte_x=1. The currently-preparing pipe
; (prep_pipe_idx) takes its place. The just-departed pipe becomes the
; new preparing pipe — clear its slot column to NOPs and reset prep_state.
;----------------------------------------------------------------
do_swap:
        ld      (departing_pipe), a              ; remember which pipe is leaving
        ld      a, (prep_pipe_idx)
        ld      (incoming_pipe), a

        ; 1. Swap pipe_state entries: prep pipe's gap_y becomes "live" for the
        ;    incoming pipe. departing pipe's slot becomes the new preparing
        ;    column with a fresh random gap_y.
        ; ...

        ; 2. Set incoming pipe's byte_x = 29 (caller will write this).
        ; ...

        ; 3. Clear departing pipe's slot column to NOPs (160 × 6 bytes).
        ;    ~5 k T one-shot. Mirror init_pipes' phase-3 NOP loop.
        ; ...

        ; 4. Pick new random gap_y for departing pipe; store in prep_gap_y.
        call    random_gap_y                     ; A = new gap_y
        ld      (prep_gap_y), a
        ld      hl, pipe_state
        ld      a, (departing_pipe)
        add     a, a
        inc     a
        ld      e, a
        ld      d, 0
        add     hl, de
        ld      a, (prep_gap_y)
        ld      (hl), a                          ; store new gap_y in pipe_state

        ; 5. Update prep_pipe_idx to the departing pipe; reset prep state.
        ld      a, (departing_pipe)
        ld      (prep_pipe_idx), a
        xor     a
        ld      (prep_phase), a
        ld      (prep_row), a
        ret

departing_pipe: db 0
incoming_pipe:  db 0
```

(Concrete implementation details for steps 1-3 in the body of `do_swap` follow the same patterns as `configure_pipe_slots`' Step 6 and `init_pipes`' phase-3 NOP loop. Implementing those is part of the task.)

- [ ] **Step 5.1.4: Remove old `configure_pipe_slots` recycle invocation**

Find in `main_loop`'s CYAN region:
```asm
ld      a, (pending_regen)
or      a
call    nz, deferred_configure
```

With Phase 5, recycle no longer queues a configure; `do_swap` handles it directly. Delete those lines and the `pending_regen` state byte (after verifying no other reference uses it — `grep -n "pending_regen"`).

- [ ] **Step 5.1.5: Remove `deferred_configure` routine**

Run: `grep -n "^deferred_configure:" src/main.asm`. Delete the routine.

- [ ] **Step 5.1.6: Remove `recycled_pipe_idx` state byte**

Search: `grep -n "recycled_pipe_idx" src/main.asm`. If no longer used, remove. (May still be referenced in `patch_pipe_targets` for the "skip recycled pipe" check — see Task 5.2.)

- [ ] **Step 5.1.7: Build**

Run: `make 2>&1 | tail -3`
Expected: errors=0.

### Task 5.2: Update `patch_pipe_targets` to skip prep pipe

**Files:**
- Modify: `src/main.asm` — `patch_pipe_targets`

- [ ] **Step 5.2.1: Find the routine**

Run: `grep -n "^patch_pipe_targets:" src/main.asm`

- [ ] **Step 5.2.2: Replace the `pending_regen` check with `prep_pipe_idx`**

The routine currently has a fast path when `pending_regen == 0` (all 3 pipes' entries get decremented) and a skip path when `pending_regen != 0` (skip the recycled pipe).

In Phase 5, there's no recycle defer; instead, the prep pipe's entries point at ROM-region addresses (in the case where prep hasn't completed) or at on-screen positions (when prep is done). Either way, we MUST skip the prep pipe in `patch_pipe_targets` because its target wraps differently.

Replace the `pending_regen` check at the top of the routine:
```asm
        ld      a, (pending_regen)
        or      a
        jr      nz, .pt_skip_path
        ; ... fast path ...
.pt_skip_path:
        ld      a, (recycled_pipe_idx)
        ; ... per-pipe gating
```

With:
```asm
        ; Phase 5: always skip the preparing pipe's sublist (it's the
        ; "inactive" one, target points at ROM or at byte_x=29 buffer).
        ld      a, (prep_pipe_idx)
        ; ... per-pipe gating, same as before but keyed on prep_pipe_idx
```

Concrete: the existing `.pt_skip_path` already implements per-pipe gating. Re-key it on `prep_pipe_idx` instead of `recycled_pipe_idx`. Extend the gating to cover all 4 pipes (not just 3).

- [ ] **Step 5.2.3: Update loop counts for 4-pipe sublist**

The current routine has `ACTIVE_COUNT = 336` (= 3 × 112) and the fast-path djnz counter is `b, 84` (= 336/4). With 4 pipes the count is 448 and the counter is 112. But since one pipe is always skipped, the active loop processes 3 × 112 = 336 entries = same as before.

Update fast-path loop count and per-pipe-gated counts accordingly.

- [ ] **Step 5.2.4: Build**

Run: `make 2>&1 | tail -3`

### Task 5.3: Final integration test

- [ ] **Step 5.3.1: Build clean**

Run: `make 2>&1 | tail -5`
Expected: `Errors: 0, warnings: 0`.

- [ ] **Step 5.3.2: Run a comprehensive snapshot check**

Tell user: "Phase 5 complete — 4-pipe architecture with swap-on-byte_x=1 is live. Please `make run` for an extended session (2+ minutes of play) and verify:

1. **Bird never flickers** at any Y position.
2. **Pipes never tear** at the top of screen.
3. **No "chunks missing"** on any frame.
4. **Pipes recycle smoothly** — when one leaves the left edge, another appears at the right edge with a different gap_y.
5. **Frame rate is solid 50 Hz** — no perceptible stutter even after many recycles.

Take a snapshot (File → Save snapshot) ~30 seconds into play and paste the path; I'll dump PIPE_PROGRAM and pipe_state to verify the 4-pipe rotation is healthy."

- [ ] **Step 5.3.3: Commit**

```bash
git add src/main.asm
git commit -m "phase 5: 4-pipe swap-on-byte_x=1 (no more configure spike)

When an active pipe reaches byte_x=1, do_swap immediately exchanges it
with the prep_pipe_idx pipe. The prepared pipe's slot column is already
fully configured (built up over ~112 frames by prep_step) so the swap
is O(1) — no 30 k T configure spike anymore.

  - wrap_byte_x's .recycle branch replaced with .swap_with_prep
  - new do_swap routine: rotates prep_pipe_idx, picks new gap_y for
    the departing pipe, clears its slot column to NOPs, resets prep state
  - deferred_configure / pending_regen / recycled_pipe_idx infrastructure
    removed (no longer needed; swap is synchronous and constant-time)
  - patch_pipe_targets now skips prep_pipe_idx (was recycled_pipe_idx)

Result: every frame has the same cost shape. ~26 k T margin to halt budget
on every frame, including the once-per-30-frames moments that used to be
the recycle spike. All three of the user-visible defects (flicker, tearing,
chunks missing) addressed by construction.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Post-implementation: regression checks

### Task 6.1: Visual & snapshot regression

- [ ] **Step 6.1.1: Run extended playtest**

Tell user: "Please play for 5+ minutes. Watch for:
- Any 1-frame visual glitch (chunks missing, weird body bytes, dotted trails)
- Any visible stutter / dropped frame
- Bird flicker at any Y (top of screen especially)
- Pipe tearing on any row
- Pipes failing to recycle / disappear / get stuck

Report anything unusual."

- [ ] **Step 6.1.2: Snapshot diff**

Save a .szx snapshot at known game state (e.g., score 100). I'll parse it to verify:
- All 4 pipe_state entries are sensible (byte_x in [1..29], gap_y in {8..96})
- All 4 slot columns have correct slot bytes at the expected rows
- All 4 cap_top_handler imms point at valid screen RAM (within $4000..$57FF)
- prep_pipe_idx is one of {0..3}
- prep_phase ≤ 8 (or about to reset)

### Task 6.2: T-state profiling sanity check

- [ ] **Step 6.2.1: Border profiling**

Tell user: "Take a screenshot while playing (and 1 during a swap moment). Confirm that RED/MAGENTA/WHITE/CYAN border bands are stable and don't bloom or shift between frames. Specifically the magenta (PIPE_PROGRAM) band should be constant height every frame; no frame should show CYAN extending past the bottom of the playfield (which would indicate a halt miss)."

---

## Notes / risks

- **Phase 1 is the most invasive single change** (touches BODY_TEMPLATE, CAP_BLOCK, init_pipe_program, configure_pipe_slots, cap handlers, redraw_pipes_v2 all at once). Take it slowly; test build often.
- **Phase 3's stride change from 20 to 32** also ripples into anything that depends on `SLOT_ROW_STRIDE`. Grep before and after to ensure all uses pick up the new value via the EQU.
- **Phase 5's `do_swap` is the trickiest piece** — there's a moment between "pipe X leaves at byte_x=1" and "prep pipe takes over" where PIPE_PROGRAM execution must not lose its place. The swap happens during `wrap_byte_x` which runs in WHITE region, so by then the current frame's PIPE_PROGRAM has already completed and the change only affects the next frame. Verify this carefully.
- **Memory layout shift**: Phase 1 grows BODY_TEMPLATE/CAP_BLOCK by ~200 bytes. Phase 3 grows SLOT_GRID by ~2.5 k bytes. Confirm by inspecting `build/main.sna` size that nothing overflows into screen RAM.

## Self-review

(Performed inline after writing the plan.)

**Spec coverage:** all three spec changes (extra-empty-byte, bird-in-top-blanking, 4-pipe) have phases. The 5-phase rollout matches the spec. ✓

**Placeholder scan:** Phase 4 contains "..." comments for the per-phase implementations of prep_step. These are deliberate — the concrete implementations of each phase mirror existing configure_pipe_slots code that the engineer can reference. Filled in narrowly enough to convey intent. **Not** a "TBD" — implementation guidance is given.

**Type consistency:** `prep_pipe_idx`, `prep_phase`, `prep_row`, `prep_gap_y` are introduced in Task 4.1 and consistently used in Tasks 4.2 (prep_step), 4.3 (init), 5.1 (do_swap), and 5.2 (patch_pipe_targets skip).

**Scope check:** single coherent plan covering one feature spec. No decomposition needed.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-18-flicker-tearing-fix.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
