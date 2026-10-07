# Aura — build entry points.
#
# The `core-*` targets run anywhere Swift runs, including Linux.
# Everything else needs macOS with Xcode.

SCHEME  := Aura
SIM     ?= iPhone 16
DEST    := platform=iOS Simulator,name=$(SIM)
BUILDIR := build

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Aura"
	@echo
	@echo "  Anywhere (Linux included):"
	@echo "    make core-test        Run the unit suite over the portable source layer"
	@echo "    make core-build       Type-check the portable source layer"
	@echo
	@echo "  macOS + Xcode only:"
	@echo "    make bootstrap        Install XcodeGen via Homebrew"
	@echo "    make project          Generate Aura.xcodeproj from project.yml"
	@echo "    make no-carplay       Generate it WITHOUT the CarPlay entitlement"
	@echo "    make open             Generate, then open in Xcode"
	@echo "    make build            Build for the simulator"
	@echo "    make test             Run the test suite on the simulator"
	@echo "    make simulators       List available simulator names"
	@echo
	@echo "    make clean            Remove build artefacts and the generated project"
	@echo
	@echo "  Override the simulator with:  make test SIM='iPhone 15 Pro'"

# ---------------------------------------------------------------- portable

.PHONY: core-test
core-test:
	swift test

.PHONY: core-build
core-build:
	swift build

# ------------------------------------------------------------------- macOS

.PHONY: require-macos
require-macos:
	@if [ "$$(uname)" != "Darwin" ]; then \
		echo "This target needs macOS with Xcode. On Linux, use 'make core-test'."; \
		exit 1; \
	fi

.PHONY: require-xcodegen
require-xcodegen: require-macos
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Run 'make bootstrap' first."; exit 1; }

.PHONY: bootstrap
bootstrap: require-macos
	@command -v brew >/dev/null 2>&1 || { \
		echo "Homebrew not found: https://brew.sh"; exit 1; }
	brew install xcodegen

.PHONY: project
project: require-xcodegen
	xcodegen generate
	@echo "Generated Aura.xcodeproj"

# Signing fails while com.apple.developer.carplay-audio is unapproved for your
# account, so this generates an otherwise identical project without it. The
# phone app and the CarPlay Now Playing screen still work; only the app's own
# CarPlay templates are unavailable.
.PHONY: no-carplay
no-carplay: require-xcodegen
	@sed '/CODE_SIGN_ENTITLEMENTS/d' project.yml > .project.nocarplay.yml
	xcodegen generate --spec .project.nocarplay.yml
	@rm -f .project.nocarplay.yml
	@echo "Generated Aura.xcodeproj WITHOUT the CarPlay entitlement."

.PHONY: open
open: project
	open Aura.xcodeproj

.PHONY: build
build: project
	xcodebuild build \
		-project Aura.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(BUILDIR) \
		CODE_SIGNING_ALLOWED=NO

.PHONY: test
test: project
	xcodebuild test \
		-project Aura.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(BUILDIR) \
		CODE_SIGNING_ALLOWED=NO

.PHONY: simulators
simulators: require-macos
	@xcrun simctl list devices available | grep -E 'iPhone|iPad' || true

# ------------------------------------------------------------------- chores

.PHONY: clean
clean:
	rm -rf $(BUILDIR) .build Aura.xcodeproj .project.nocarplay.yml
	@echo "Cleaned."
