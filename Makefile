.PHONY: setup setup-tools doctor format format-check lint lint-fix build localization-check localization-sync run dev-install use-dev use-release test-dev-tools energy-profile arc-audit test-skylight-live release-check verify check check-tool-versions check-swiftformat-version check-swiftlint-version check-pins hooks

include Scripts/dev-tools.env

NIX_BUILD := nix --extra-experimental-features "nix-command flakes" build
GHOSTTYKIT := Frameworks/GhosttyKit.xcframework
SWIFTFORMAT := $(CURDIR)/.cache/flake-tools/bin/swiftformat
SWIFTLINT := $(CURDIR)/.cache/flake-tools/bin/swiftlint
SWIFT_WITH_GHOSTTY = LIBRARY_PATH="$$(./Scripts/ghostty-preflight.sh print-library-dir)$${LIBRARY_PATH:+:$$LIBRARY_PATH}"
SWIFT := $(or $(SWIFTLY_HOME_DIR),$(HOME)/.swiftly)/bin/swift

setup: setup-tools
	@if [ -e "$(GHOSTTYKIT)" ] && ! readlink "$(GHOSTTYKIT)" | grep -q '^/nix/store/'; then \
		./Scripts/ghostty-preflight.sh verify || { echo "error: $(GHOSTTYKIT) does not match this checkout. It was preserved; move it aside before make setup." >&2; exit 1; }; \
	else \
		mkdir -p Frameworks && $(NIX_BUILD) .#ghosttykit -o "$(GHOSTTYKIT)"; \
	fi
	./Scripts/ghostty-preflight.sh verify

setup-tools:
	$(NIX_BUILD) .#default -o .cache/flake-tools

doctor:
	./Scripts/doctor.sh

check-pins:
	python3 Scripts/check-pinned-downloads.py

hooks:
	git config core.hooksPath .githooks

check-swiftformat-version:
	@actual="$$("$(SWIFTFORMAT)" --version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTFORMAT_VERSION)" ]; then echo "error: SwiftFormat $(SWIFTFORMAT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-swiftlint-version:
	@actual="$$("$(SWIFTLINT)" version 2>/dev/null || true)"; if [ "$$actual" != "$(SWIFTLINT_VERSION)" ]; then echo "error: SwiftLint $(SWIFTLINT_VERSION) required; found $${actual:-missing}" >&2; exit 1; fi

check-tool-versions: check-swiftformat-version check-swiftlint-version

format: check-swiftformat-version
	"$(SWIFTFORMAT)" .

format-check: check-swiftformat-version
	"$(SWIFTFORMAT)" --lint .

lint: check-swiftlint-version
	"$(SWIFTLINT)" lint

lint-fix: check-tool-versions
	"$(SWIFTFORMAT)" .
	"$(SWIFTLINT)" lint --fix || true
	"$(SWIFTFORMAT)" .
	"$(SWIFTLINT)" lint

build:
	./Scripts/ghostty-preflight.sh verify
	$(SWIFT_WITH_GHOSTTY) "$(SWIFT)" build --arch arm64

localization-check: build
	python3 Scripts/localization.py check

localization-sync: build
	python3 Scripts/localization.py sync

run: dev-install

dev-install:
	./Scripts/omniwm-dev.sh install

use-dev:
	./Scripts/omniwm-dev.sh use dev

use-release:
	./Scripts/omniwm-dev.sh use release

test-dev-tools:
	python3 -m unittest discover -s Tests/DevToolingTests
	python3 -m unittest discover -s Tests/KittyControlTests

energy-profile:
	./Scripts/energy-profile.sh

arc-audit:
	./Scripts/arc-audit.sh

test-skylight-live:
	OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 "$(SWIFT)" test --filter SkyLightNativeSpaceInventoryLiveTests/testLiveTransactionMoveIsObservedThroughWindowServerBounds

release-check: localization-check

verify: format-check lint localization-check

check: verify
