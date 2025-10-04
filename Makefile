# Wardrive Makefile (with opener auto-detect)

SHELL := /bin/bash

LOGS := logs/kismet/wardrive
DATA := data
MAP  := $(DATA)/snapshots

LATEST_MAP := $(shell ls -t $(MAP)/*.html $(LOGS)/*.html 2>/dev/null | head -n1)
LATEST_LOG_MAP := $(shell ls -t $(LOGS)/*.html 2>/dev/null | head -n1)

# Try a list of known “openers”; pick the first that exists
OPENERS := xdg-open gio open gnome-open kde-open sensible-browser x-www-browser wslview
OPEN := $(firstword $(foreach c,$(OPENERS),$(if $(shell command -v $(c) >/dev/null 2>&1; echo $$?),,$(c))))

.PHONY: all ci map stats open open-log echo-path clean setup

all: map

ci:
	@echo "[CI] Running syntax and sanity checks..."
	bash -n scripts/build_map.sh
	@PY_FILES=("make_map.py" "parse_netxml.py" "csv_to_geojson.py"); \
	EXISTING=(); \
	for f in "$${PY_FILES[@]}"; do [ -f "$$f" ] && EXISTING+=("$$f"); done; \
	if [ $${#EXISTING[@]} -gt 0 ]; then \
		echo "[CI] Compiling python: $${EXISTING[@]}"; \
		python3 -m py_compile "$${EXISTING[@]}"; \
	else \
		echo "[CI] No optional python helpers to compile"; \
	fi
	./scripts/build_map.sh --ci-check
	@echo "[OK] CI check passed."

map:
	@echo "[Build] Regenerating GeoJSON + HTML map..."
	./scripts/build_map.sh
	@mkdir -p "$(MAP)"
	@if ls $(LOGS)/*.html >/dev/null 2>&1; then \
		NEWEST=$$(ls -t $(LOGS)/*.html | head -n1); \
		cp -u "$$NEWEST" "$(MAP)/"; \
		echo "[Copy] Synced $$(basename $$NEWEST) -> $(MAP)/"; \
	fi
	@echo "[Done] Map updated in $(MAP)/"

stats:
	@echo "[Stats] Updating summaries..."
	./scripts/build_map.sh --dry-run
	@echo "[Done] Stats refreshed in $(DATA)/stats/"

open:
	@if [ -n "$(LATEST_MAP)" ]; then \
		if [ -n "$(OPEN)" ]; then \
			echo "[Open] Using $(OPEN) to launch $(LATEST_MAP)"; \
			"$(OPEN)" "$(LATEST_MAP)"; \
		else \
			echo "[Warn] No desktop opener found."; \
			echo "Path: $(LATEST_MAP)"; \
			echo "Tip: sudo apt install -y xdg-utils   # then re-run make open"; \
		fi \
	else \
		echo "[Warn] No map found in $(MAP)/ or $(LOGS)/"; \
	fi

open-log:
	@if [ -n "$(LATEST_LOG_MAP)" ]; then \
		if [ -n "$(OPEN)" ]; then \
			echo "[Open] Using $(OPEN) to launch $(LATEST_LOG_MAP)"; \
			"$(OPEN)" "$(LATEST_LOG_MAP)"; \
		else \
			echo "[Warn] No desktop opener found."; \
			echo "Path: $(LATEST_LOG_MAP)"; \
			echo "Tip: sudo apt install -y xdg-utils"; \
		fi \
	else \
		echo "[Warn] No map found in $(LOGS)/"; \
	fi

# Always prints the path so you can open it manually (scp, browser, etc.)
echo-path:
	@if [ -n "$(LATEST_MAP)" ]; then \
		echo "$(LATEST_MAP)"; \
	else \
		echo "No map yet."; \
	fi

clean:
	@echo "[Clean] Removing temp and cache files..."
	rm -rf $(DATA)/stats/* $(MAP)/*.geojson $(MAP)/*.html 2>/dev/null || true
	@echo "[Clean] Done."

setup:
	@echo "[Setup] Ensuring directories exist..."
	mkdir -p "$(LOGS)" "$(DATA)/stats" "$(MAP)"
	@echo "[Setup] Done."
