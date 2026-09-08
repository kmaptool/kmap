# kmap — OpenStreetMap to Garmin, in the terminal

BINARY    := kmap
BUILD_DIR := .build
PREFIX    ?= /usr/local
ARGS      ?=
ARCHES    ?=

UNAME := $(shell uname)

# Optimisation for the release build.
#
# Whole-module is deliberately *not* named here: `-c release` already compiles that way,
# and passing it again makes SwiftPM plan the module twice and refuse the build outright
# with "multiple producers".
#
# Cross-module lets the optimiser see through the package boundary. Measured on kmap as
# it stands, that is a difference of four bytes of code and nothing in wall clock: there
# is one module and no dependencies, so there is no boundary to see through. It is here
# for the day there is one, and it costs nothing until then.
SWIFT_FLAGS = -Xswiftc -cross-module-optimization

ifeq ($(UNAME), Linux)
    # So the binary runs on a machine without the Swift runtime installed.
    SWIFT_FLAGS += -Xswiftc -static-stdlib
endif

# Every bounds and overflow check removed. Measured, it buys nothing here: Crimea builds
# in 18.6 s either way, and the binary is 200 kB smaller because the checks really are
# gone. The hot loops already read through unsafe buffer pointers, which is where the
# time was; what is left to check is the arithmetic on numbers that came off the wire,
# and those checks are what turn a malformed PBF into a clean stop instead of into
# silently wrong terrain. So: off, and here only to be measured again --
# `make release UNCHECKED=1`.
ifdef UNCHECKED
    SWIFT_FLAGS += -Xswiftc -Ounchecked
endif

.PHONY: all build release run test linux assets version reassign clean install uninstall \
        package-mac package-debian package-windows

all: build

## Debug build
build: assets
	swift build

## Optimized release build
release: assets
	swift build -c release $(SWIFT_FLAGS)

## Build & run
run: assets
	swift run $(BINARY) $(ARGS)

## The test suite
test: assets
	swift test

## Fold Assets/ back into Sources/kmap/Build/Style/StyleAssets.swift
assets: version
	@swift build
	@$(BUILD_DIR)/debug/$(BINARY) embed-assets

## Regenerate the version constant from the VERSION file. The generated file is
## committed, so a plain `swift build` needs nothing but the sources.
version:
	@printf '// Generated from the VERSION file at the repository root by `make version`.\n// Edit that file, not this one.\nextension Version {\n    /// The number the VERSION file holds.\n    static let number = "%s"\n}\n' "$$(tr -d ' \r\n' < VERSION)" > $(BUILD_DIR)/version-next.swift
	@cmp -s $(BUILD_DIR)/version-next.swift Sources/kmap/Core/VersionNumber.swift || cp $(BUILD_DIR)/version-next.swift Sources/kmap/Core/VersionNumber.swift

## Remove build artifacts
clean:
	swift package clean
	rm -rf $(BUILD_DIR) build

## Packages, one per platform. `make install` below is the other way and stays the base:
## it puts the binary in $(PREFIX)/bin and involves no bundle, no installer and no
## package manager. See Scripts/README.md.
package-mac:
	@Scripts/build-mac.sh

## The architecture, or several: `make package-debian ARCHES="amd64 arm64"`.
package-debian:
	@Scripts/build-debian.sh $(ARCHES)

## Only on Windows, from a bash prompt there.
package-windows:
	@Scripts/build-windows.sh

## Install the release binary
install: release
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/release/$(BINARY) $(PREFIX)/bin/$(BINARY)
	@echo "installed -> $(PREFIX)/bin/$(BINARY)"

uninstall:
	rm -f $(PREFIX)/bin/$(BINARY)
