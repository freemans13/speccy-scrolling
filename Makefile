SJASMPLUS := tools/sjasmplus/sjasmplus
SRC       := src/main.asm
OUT       := build/main.sna

.PHONY: all run clean

all: $(OUT)

$(OUT): $(SRC) | build
	$(SJASMPLUS) --fullpath $(SRC)

build:
	mkdir -p build

run: $(OUT)
	open $(OUT)

clean:
	rm -rf build
