.DEFAULT_GOAL := build
SHELL := /bin/bash

CONFIGURATION ?= debug
SWIFT ?= swift
PYTHON ?= python3
TAG ?=
HEADLESS ?=
CHIAKI_TAKION_VERSION ?= 0
CHIAKI_KAKUSAN ?= 0
CHIAKI_PS5_CLOUD_LAUNCH ?= 0
IOS_PLATFORM ?= ios-simulator
IOS_DEVICE ?=
IOS_TARGETS ?= ChiakiCoreBridge ChiakiPersistence Video PlatformUI
export CHIAKI_TAKION_VERSION CHIAKI_KAKUSAN CHIAKI_PS5_CLOUD_LAUNCH

.PHONY: help build core swift-build app run release notarize dmg mac-sandbox mac-pkg mac-testflight test test-swift test-core test-storage deps native-deps deps-github mirror-deps clean core-ios ios-build ios-app ios-run ios-device ios-ipa

help:
	@printf '%s\n' \
	  'make                 Build the native core and Swift executable' \
	  'make app             Build a signed .app without launching it' \
	  'make run             Build, sign and launch the .app' \
	  'make release         Build an optimized signed .app' \
	  'make notarize TAG=alpha Build, Developer ID sign and notarize the .app, then package a notarized DMG in dist' \
	  'make dmg             Package the already notarized .build/chiaki-ng.app as a notarized DMG in dist' \
	  'make mac-sandbox     Build the sandboxed App Store app, Apple Development signed, to run locally' \
	  'make mac-pkg         Build the App Store app and its signed installer package in dist' \
	  'make mac-testflight  Build the App Store package, validate it and upload it to App Store Connect' \
  'make app TAG=grill   Build a .app whose version reads v2.0.0-grill' \
	  'make core            Build and test the native core only' \
	  'make swift-build     Build the Swift executable only' \
	  'make core-ios        Cross-build pinned dependencies and the native core; IOS_PLATFORM=ios for devices' \
	  'make ios-build       Cross-build the Swift modules that already support iOS; IOS_TARGETS picks them' \
	  'make ios-app         Build the simulator .app without launching it' \
	  'make ios-run         Build the simulator .app and launch it; IOS_DEVICE picks a simulator' \
	  'make ios-device      Build, sign and install on a connected iPhone or iPad named by IOS_DEVICE' \
	  'make ios-ipa         Build and sign a development .ipa in .build/ios' \
	  'make test            Run all offline checks (includes loopback UDP)' \
  'make test HEADLESS=1 Skip tests that open windows, for machines without a window server' \
	  'make test-swift      Run Swift client, storage, FSM and feature tests' \
	  'make test-core       Run the native core bridge tests' \
	  'make test-storage    Run SQLite schema checks' \
	  'make native-video-probe Test direct VideoToolbox hardware decoding and Metal surfaces' \
	  'make video-effects-probe Test 120 fps interpolation' \
	  'make video-probe     Check FFmpeg/VideoToolbox surfaces and PQ colour math' \
	  'make video-fixture   Fetch a YouTube PQ fixture using VIDEO_URL' \
	  'make video-deps      Install optional video fixture tools' \
	  'make format          Format project-owned Swift, C and Objective-C' \
	  'make lint            Check Swift, C and documentation; fails on any problem' \
	  'make lint-c          Check C and Objective-C formatting' \
	  'make lint-docs       Require DocC on non-private Swift declarations, build every DocC catalog' \
	  '                     with warnings as errors and lint the core headers' \
	  'make analyze-c       Run Clang static analysis on bridge and discovery C' \
	  'make core-notes      Rewrite the Swift API notes from the pinned core headers' \
	  'make check-core-notes Fail when the Swift API notes do not match the pinned core headers' \
	  'make check-core-includes Fail when app code includes core headers outside its public faces' \
	  'make lint-deps       Install Swift and C formatting tools' \
	  'make native-deps     Build pinned native dependencies for arm64 macOS 26' \
	  'make deps-github     Fetch the pinned native dependencies prebuilt for macOS, iOS and the simulator;' \
	  '                     DEPS_DATE=101026 picks a release, DEPS_PLATFORM=macos|ios|ios-simulator picks one,' \
	  '                     DEPS_FROM=../native-deps/dist installs a locally packaged build instead' \
	  'make mirror-deps     Upload pinned source archives to chiaki-ng/native-deps' \
	  'make deps            Install build dependencies and resolve Swift packages' \
	  'make clean           Remove compiler outputs; keep app data and signing identity' \
	  '' \
	  'Options: CONFIGURATION=debug|release SWIFT=swift PYTHON=python3 TAG=name HEADLESS=1 DEPS_DATE=ddmmyy' \
	  '         CHIAKI_KAKUSAN=1|0 builds Kakusan session sharing (default 0); 0 leaves it out of the core and app' \
	  '         CHIAKI_PS5_CLOUD_LAUNCH=1|0 allows PS Cloud launches (default 0); 0 refuses them in the core and app, PS Now still launches' \
	  '         CHIAKI_BUILD_ONLY=1 builds the macOS app core without running native core tests' \
	  '         IOS_PLATFORM=ios-simulator|ios IOS_TARGETS="ChiakiCoreBridge ChiakiPersistence Video PlatformUI"'

build: core swift-build

core:
	./Scripts/build-core.sh

swift-build: core
	$(SWIFT) build --configuration "$(CONFIGURATION)"

core-ios:
	CHIAKI_PLATFORM="$(IOS_PLATFORM)" ./Scripts/build-core.sh

ios-build:
	CHIAKI_PLATFORM="$(IOS_PLATFORM)" CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" ./Scripts/build-ios.sh $(IOS_TARGETS)

ios-app:
	CHIAKI_LAUNCH_APP=0 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" ./Scripts/run-ios.sh

ios-run:
	CHIAKI_LAUNCH_APP=1 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" IOS_DEVICE="$(or $(IOS_DEVICE),booted)" \
	    ./Scripts/run-ios.sh

ios-device:
	CHIAKI_PLATFORM=ios CHIAKI_LAUNCH_APP=1 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" \
	    IOS_DEVICE="$(IOS_DEVICE)" ./Scripts/run-ios.sh

ios-ipa:
	CHIAKI_PLATFORM=ios IOS_IPA=1 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" ./Scripts/run-ios.sh

app: core
	CHIAKI_LAUNCH_APP=0 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" CHIAKI_VERSION_TAG="$(TAG)" ./Scripts/run-app.sh

run: core
	CHIAKI_LAUNCH_APP=1 CONFIGURATION="$(CONFIGURATION)" SWIFT="$(SWIFT)" CHIAKI_VERSION_TAG="$(TAG)" ./Scripts/run-app.sh

release:
	$(MAKE) CONFIGURATION=release TAG="$(TAG)" app

notarize: core
	CHIAKI_VERSION_TAG="$(TAG)" SWIFT="$(SWIFT)" ./Scripts/release.sh

dmg:
	./Scripts/package-dmg.sh

mac-sandbox: core
	CHIAKI_VERSION_TAG="$(TAG)" SWIFT="$(SWIFT)" ./Scripts/app-store.sh sandbox

mac-pkg: core
	CHIAKI_VERSION_TAG="$(TAG)" SWIFT="$(SWIFT)" ./Scripts/app-store.sh pkg

mac-testflight: core
	CHIAKI_VERSION_TAG="$(TAG)" SWIFT="$(SWIFT)" ./Scripts/app-store.sh upload

test: check-core-notes test-core test-swift test-storage test-video-metadata test-video-state

test-core: core

test-swift: core
	CHIAKI_HEADLESS_TESTS="$(HEADLESS)" $(SWIFT) test --configuration "$(CONFIGURATION)"

test-storage:
	$(PYTHON) -B Tests/Native/StorageSchemaTests/test_storage.py

native-deps:
	$(PYTHON) Tools/Dependencies/build.py

deps-github:
	$(PYTHON) Tools/Dependencies/prebuilt.py $(if $(DEPS_PLATFORM),--platform=$(DEPS_PLATFORM)) \
	    $(if $(DEPS_FROM),--from=$(DEPS_FROM)) $(DEPS_DATE)

mirror-deps:
	$(PYTHON) Tools/Dependencies/sources.py --mirror

deps:
	brew install cmake ninja pkg-config create-dmg
	$(PYTHON) Tools/Dependencies/build.py
	$(SWIFT) package resolve

clean:
	$(SWIFT) package clean
	rm -rf .build/native-core .build/native-core-ios .build/native-core-ios-simulator .build/chiaki-core \
	    .build/dependencies .build/ios .build/ios-simulator

.PHONY: video-probe
video-probe:
	./Tools/VideoProbe/run.sh

export VIDEO_URL VIDEO_FILE
.PHONY: video-fixture video-deps
video-fixture:
	$(PYTHON) Tools/VideoFixture/import.py

video-deps:
	brew install yt-dlp ffmpeg

.PHONY: test-video-metadata
test-video-metadata:
	$(PYTHON) -B Tests/Native/VideoFixtureTests/test_metadata.py

.PHONY: native-video-probe
native-video-probe:
	./Tools/NativeVideoProbe/run.sh

.PHONY: test-live-video
test-live-video:
	bash Tools/NativeVideoProbe/run-live-encoded.sh

.PHONY: video-effects-probe
video-effects-probe:
	./Tools/VideoEffectsProbe/run.sh

.PHONY: test-video-state
test-video-state:
	./Scripts/test-native.sh video

.PHONY: lint lint-fix lint-docs
lint: lint-c check-core-notes check-core-includes lint-docs
	swiftlint lint --strict --config .swiftlint.yml

lint-docs: core
	SWIFT="$(SWIFT)" PYTHON="$(PYTHON)" $(PYTHON) Tools/Quality/docs-lint.py

lint-fix: format-c
	./Scripts/format.sh swift
	swiftlint lint --fix --config .swiftlint.yml
	./Scripts/format.sh swift

.PHONY: format
format:
	./Scripts/format.sh

.PHONY: format-c lint-c analyze-c lint-deps
format-c:
	./Scripts/format.sh c

lint-c:
	./Scripts/format.sh check-c

analyze-c: core
	$(PYTHON) Tools/Quality/analyze-c.py

.PHONY: core-notes check-core-notes
core-notes:
	$(PYTHON) Tools/Quality/core-apinotes.py

check-core-notes:
	$(PYTHON) Tools/Quality/core-apinotes.py --check

.PHONY: check-core-includes
check-core-includes:
	$(PYTHON) Tools/Quality/core-includes.py

lint-deps:
	brew install swiftformat swiftlint clang-format
