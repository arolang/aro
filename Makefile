# =============================================================================
# ARO — convenience build targets
# =============================================================================
# `swift build` / `swift build -c release` work directly on a clean checkout
# and in CI. These targets are shortcuts, plus a self-heal for one macOS
# quirk: switching a build directory from debug to release can leave a stale
# `_NumericsShims` module, so `swift build -c release` fails with
# "missing required module '_NumericsShims'" (issue #295). `make release`
# detects that one failure, clears the stale release artifacts, and retries.
#
#   make            # debug build (default)
#   make release    # release build (self-heals the #295 stale-module case)
#   make aro        # release build of just the `aro` CLI
#   make solaro     # assemble a local Solaro.app (release)
#   make test       # run the test suite
#   make clean      # remove all build artifacts (.build)
#   make clean-release   # remove only the release artifacts
#
# Pass extra swift-build args with ARGS, e.g.  make release ARGS="--product aro"
# =============================================================================

# bash gives us `set -o pipefail` + PIPESTATUS, used by the release self-heal.
SHELL := /bin/bash
SWIFT ?= swift
ARGS  ?=

.DEFAULT_GOAL := build
.PHONY: build debug release aro solaro test clean clean-release help

build debug: ## Debug build (default)
	$(SWIFT) build $(ARGS)

release: ## Release build; self-heals the #295 stale _NumericsShims module
	@$(call safe_release,$(ARGS))

aro: ## Release build of just the `aro` CLI
	@$(call safe_release,--product aro $(ARGS))

solaro: ## Assemble a local Solaro.app (release)
	./tools/build-solaro-app-local.sh release

test: ## Run the test suite
	$(SWIFT) test $(ARGS)

clean: ## Remove all build artifacts
	rm -rf .build

clean-release: ## Remove only the release artifacts (manual #295 fix)
	rm -rf "$$($(SWIFT) build -c release --show-bin-path 2>/dev/null)"

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

# safe_release(<swift build args>): run `swift build -c release <args>`; if it
# fails specifically on the stale `_NumericsShims` release module (#295), clear
# the release artifacts and retry once. Unrelated failures propagate unchanged.
define safe_release
	set -o pipefail; \
	log=$$(mktemp); \
	if $(SWIFT) build -c release $(1) 2>&1 | tee "$$log"; then \
		rm -f "$$log"; \
	elif grep -q _NumericsShims "$$log"; then \
		echo ">>> stale _NumericsShims release module (#295); clearing release artifacts and retrying once…"; \
		rm -f "$$log"; \
		rel=$$($(SWIFT) build -c release --show-bin-path 2>/dev/null || true); \
		[ -n "$$rel" ] && rm -rf "$$rel"; \
		$(SWIFT) build -c release $(1); \
	else \
		rm -f "$$log"; exit 1; \
	fi
endef
