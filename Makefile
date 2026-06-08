SCHEME = Clauded
PROJECT_DIR = Clauded
BUILD_DIR = $(shell xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

# Sign local debug builds with the same Developer ID identity used for releases.
# macOS keys TCC grants (Accessibility, Automation) to the code signature, so the
# default ad-hoc signing loses the grant on every rebuild and never matches the
# Homebrew-installed app. Signing with a stable Developer ID makes the permission
# persist across rebuilds and shared with the released app. Auto-detected from the
# keychain; override with `make run SIGN_TEAM=...`, or `SIGN_TEAM=` to disable.
SIGN_IDENTITY = Developer ID Application
SIGN_TEAM ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/')
CODESIGN_FLAGS = $(if $(strip $(SIGN_TEAM)),CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$(SIGN_TEAM)",)

.PHONY: build run test release package clean generate format lint setup help

help:
	@echo "Available targets:"
	@echo "  build     - Debug build"
	@echo "  run       - Build and launch"
	@echo "  test      - Run unit tests"
	@echo "  release   - Release build (unsigned)"
	@echo "  package   - Release build + zip for distribution"
	@echo "  clean     - Clean build artifacts"
	@echo "  generate  - Regenerate Xcode project from project.yml"
	@echo "  format    - Auto-format Swift code"
	@echo "  lint      - Check code style (swiftformat + swiftlint)"

build:
	xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -configuration Debug $(CODESIGN_FLAGS) build

run: build
	open "$(BUILD_DIR)/Clauded.app"

test:
	xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -configuration Debug test

release:
	@echo "Note: For distributable builds, use the CI release workflow which handles Developer ID signing + notarization."
	xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -configuration Release build
	@echo "Built to: $(BUILD_DIR)/../Release/Clauded.app"

package: release
	cd "$$(xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')" && \
	ditto -c -k --keepParent Clauded.app Clauded.zip && \
	echo "Package ready: $$(pwd)/Clauded.zip" && \
	echo "SHA256: $$(shasum -a 256 Clauded.zip | awk '{print $$1}')"

clean:
	xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) clean

generate:
	cd $(PROJECT_DIR) && xcodegen generate

format:
	swiftformat .

lint:
	swiftformat --lint .
	swiftlint lint --strict

setup:
	git config core.hooksPath .githooks
	@echo "Git hooks configured."
