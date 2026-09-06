# imagine — Makefile
# Quick dev install:  make install   (builds binary + installs skill)

# ----- configurable paths (override on the command line) -----------------
PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
AGENTS_DIR  ?= $(HOME)/.agents
SKILL_DIR   ?= $(AGENTS_DIR)/skills/imagine
OPTIMIZE    ?= ReleaseFast
SVG_OVERLAY ?= 1
RESVG_INCLUDE ?=
RESVG_LIB ?=

ZIG         ?= zig
BIN_NAME    := imagine
BUILD_BIN   := zig-out/bin/$(BIN_NAME)
SVG_FLAGS   :=
ifeq ($(SVG_OVERLAY),1)
SVG_FLAGS += -Dsvg-overlay=true
endif
ifneq ($(RESVG_INCLUDE),)
SVG_FLAGS += -Dresvg-include=$(RESVG_INCLUDE)
endif
ifneq ($(RESVG_LIB),)
SVG_FLAGS += -Dresvg-lib=$(RESVG_LIB)
endif

.DEFAULT_GOAL := build

# ----- build / test ------------------------------------------------------
.PHONY: build
build: ## Build the optimized binary with SVG/text render support by default
	$(ZIG) build -Doptimize=$(OPTIMIZE) $(SVG_FLAGS)

.PHONY: build-core
build-core: SVG_OVERLAY=0
build-core: ## Build without optional SVG/text render support
	$(ZIG) build -Doptimize=$(OPTIMIZE) -Dsvg-overlay=false

.PHONY: debug
debug: ## Build a debug binary
	$(ZIG) build $(SVG_FLAGS)

.PHONY: build-svg
build-svg: ## Build with SVG rendering/composition support via resvg
	$(ZIG) build -Doptimize=$(OPTIMIZE) -Dsvg-overlay=true $(if $(RESVG_INCLUDE),-Dresvg-include=$(RESVG_INCLUDE),) $(if $(RESVG_LIB),-Dresvg-lib=$(RESVG_LIB),)

.PHONY: test
test: ## Run unit tests
	$(ZIG) build test $(SVG_FLAGS)

.PHONY: test-core
test-core: SVG_OVERLAY=0
test-core: ## Run unit tests without optional SVG/text render support
	$(ZIG) build test -Dsvg-overlay=false

.PHONY: test-svg
test-svg: ## Run tests with SVG rendering/composition support enabled
	$(ZIG) build test -Dsvg-overlay=true $(if $(RESVG_INCLUDE),-Dresvg-include=$(RESVG_INCLUDE),) $(if $(RESVG_LIB),-Dresvg-lib=$(RESVG_LIB),)

.PHONY: run
run: ## Build & run (use ARGS="generate -m ... -p ...")
	$(ZIG) build run $(SVG_FLAGS) -- $(ARGS)

.PHONY: fmt
fmt: ## Format all Zig sources
	$(ZIG) fmt build.zig src

.PHONY: check
check: fmt test ## Format + test

# ----- install / uninstall ----------------------------------------------
.PHONY: install
install: build install-bin install-skill ## Build, then install binary + skill
	@echo ""
	@echo "imagine installed."
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "NOTE: $(BINDIR) is not on PATH. Add to your shell rc:"; \
	     echo "      export PATH=\"$(BINDIR):\$$PATH\"";; esac

.PHONY: install-bin
install-bin: build ## Install only the binary
	@mkdir -p "$(BINDIR)"
	install -m 0755 "$(BUILD_BIN)" "$(BINDIR)/$(BIN_NAME)"
	@echo "binary -> $(BINDIR)/$(BIN_NAME)"

.PHONY: install-svg
install-svg: SVG_OVERLAY=1
install-svg: install ## Build/install binary with SVG rendering/composition support

.PHONY: install-skill
install-skill: ## Install only the skill into ~/.agents/skills/imagine
	@mkdir -p "$(SKILL_DIR)"
	cp -R skills/imagine/. "$(SKILL_DIR)/"
	@echo "skill  -> $(SKILL_DIR)"

.PHONY: uninstall
uninstall: ## Remove installed binary and skill
	rm -f "$(BINDIR)/$(BIN_NAME)"
	rm -rf "$(SKILL_DIR)"
	@echo "uninstalled $(BIN_NAME) and skill"

# ----- cross-platform release artifacts ---------------------------------
# Mirrors .github/workflows/release.yml — produces every published asset
# locally so a release can be verified before tagging.
DIST_DIR ?= dist
REL_TARGETS := \
  imagine-linux-x86_64:x86_64-linux-musl \
  imagine-linux-aarch64:aarch64-linux-musl \
  imagine-macos-x86_64:x86_64-macos \
  imagine-macos-aarch64:aarch64-macos \
  imagine-windows-x86_64.exe:x86_64-windows \
  imagine-windows-aarch64.exe:aarch64-windows

.PHONY: dist
dist: ## Cross-compile all release binaries + skill + checksums into dist/
	@rm -rf "$(DIST_DIR)" && mkdir -p "$(DIST_DIR)"
	@for pair in $(REL_TARGETS); do \
	  asset=$${pair%%:*}; zt=$${pair##*:}; \
	  echo "building $$asset ($$zt)"; \
	  $(ZIG) build -Dtarget=$$zt -Doptimize=ReleaseFast -Dstrip=true -p "$(DIST_DIR)/.stage" || exit 1; \
	  if [ -f "$(DIST_DIR)/.stage/bin/imagine.exe" ]; then \
	    cp "$(DIST_DIR)/.stage/bin/imagine.exe" "$(DIST_DIR)/$$asset"; \
	  else cp "$(DIST_DIR)/.stage/bin/imagine" "$(DIST_DIR)/$$asset"; fi; \
	done
	@rm -rf "$(DIST_DIR)/.stage"
	@tar -czf "$(DIST_DIR)/imagine-skill.tar.gz" -C skills imagine
	@for target in imagine-linux-x86_64 imagine-linux-aarch64 imagine-macos-x86_64 imagine-macos-aarch64; do \
	  tar -czf "$(DIST_DIR)/$${target}.tar.gz" -C "$(DIST_DIR)" "$$target" -C . skills; \
	done
	@cd "$(DIST_DIR)" && { sha256sum imagine-* > SHA256SUMS 2>/dev/null || shasum -a 256 imagine-* > SHA256SUMS; }
	@echo "" && echo "dist -> $(DIST_DIR)/" && ls -1 "$(DIST_DIR)"

# ----- housekeeping ------------------------------------------------------
.PHONY: clean
clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache $(DIST_DIR)

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
