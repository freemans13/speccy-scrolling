SJASMPLUS := tools/sjasmplus/sjasmplus
SRC       := src/main.asm
OUT       := build/main.sna
LST       := build/main.lst
PYTHON    := /tmp/emuvenv/bin/python

.PHONY: all run clean test test-render test-overrun

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
test: test-render test-overrun

test-render: $(OUT)
	@$(PYTHON) tools/test_render.py

test-overrun: $(OUT)
	@$(PYTHON) tools/test_overrun.py

clean:
	rm -rf build
