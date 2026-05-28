SJASMPLUS := tools/sjasmplus/sjasmplus
SRC       := src/main.asm
OUT       := build/main.sna
LST       := build/main.lst
PYTHON    := /tmp/emuvenv/bin/python

.PHONY: all run clean test test-render test-overrun test-buffer-cols test-beam-race test-bird test-yellow-band test-bird-sweep

all: $(OUT)

# Build always emits the .lst alongside the .sna so test/diagnostic
# tools (snadump, refrender, runsim_until, test_*) can read up-to-date
# symbol addresses. Without --lst the tools would silently use stale
# defaults whenever code-size changes shift RAM labels.
$(OUT): $(SRC) | build
	$(SJASMPLUS) --fullpath --lst=$(LST) $(SRC)

build:
	mkdir -p build

run: $(OUT)
	open $(OUT)

# Test targets — fast headless checks. Run on every build with `make test`.
test: test-render test-overrun test-buffer-cols test-beam-race test-bird test-yellow-band

test-render: $(OUT)
	@$(PYTHON) tools/test_render.py

test-overrun: $(OUT)
	@$(PYTHON) tools/test_overrun.py

test-buffer-cols: $(OUT)
	@$(PYTHON) tools/test_buffer_cols.py

test-beam-race: $(OUT)
	@$(PYTHON) tools/test_beam_race.py

test-bird: $(OUT)
	@$(PYTHON) tools/test_bird.py

test-yellow-band: $(OUT)
	@$(PYTHON) tools/test_yellow_band.py

# test-bird-sweep: comprehensive sweep of bird Y=20..144, checking for
# artifacts at every position. Standalone — NOT in default `make test`
# because it surfaces real transient stale-residue bugs not yet fixed.
test-bird-sweep: $(OUT)
	@$(PYTHON) tools/test_bird_sweep.py

clean:
	rm -rf build
