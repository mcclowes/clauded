SCHEME = Clauded
PROJECT_DIR = Clauded
BUILD_DIR = $(shell xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

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
	xcodebuild -project $(PROJECT_DIR)/Clauded.xcodeproj -scheme $(SCHEME) -configuration Debug build

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
