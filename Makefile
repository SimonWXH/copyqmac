# Build, run, test, and clean CopyQmac and the CopyQSync format module.
#
# There is no Xcode project here on purpose: the Command Line Tools ship the
# Swift compiler and the macOS SDK, which is all the app and module need. See
# docs/build.md and core/CopyQSync/README.md.
#
# To install into /Applications, remove any existing bundle first so ditto does
# not merge into stale bundle contents from a previous build:
#   rm -rf /Applications/CopyQmac.app
#   ditto build/CopyQmac.app /Applications/CopyQmac.app

APP_NAME      := CopyQmac
BUNDLE        := build/$(APP_NAME).app
CONTENTS      := $(BUNDLE)/Contents
MACOS_DIR     := $(CONTENTS)/MacOS
RESOURCES_DIR := $(CONTENTS)/Resources
VERSION_FILE  := VERSION
VERSION       := $(shell tr -d '[:space:]' < $(VERSION_FILE) 2>/dev/null)

# CFBundleIconFile in app/Info.plist names this file, so it has to be installed
# at Contents/Resources/<name> before the bundle is sealed by codesign.
ICON          := AppIcon.icns
ICON_SOURCE   := resources/$(ICON)

ARCH      ?= $(shell uname -m)
TARGET    ?= $(ARCH)-apple-macosx26.0
SDK       ?= $(shell xcrun --show-sdk-path)
SWIFTC    ?= swiftc
CODESIGN  ?= codesign

SWIFT_FLAGS := -target $(TARGET) -sdk $(SDK) -swift-version 5 -O -g -lz

CORE_SOURCES  := $(wildcard core/*.swift) $(wildcard core/CopyQSync/Sources/CopyQSync/*.swift)
APP_SOURCES   := $(wildcard app/*.swift)
TEST_SOURCES  := $(wildcard tests/*.swift)
TEST_APP_SOURCES := app/AppModel.swift app/EntryListView.swift app/RichTextPresentation.swift app/GlassSupport.swift \
                    app/SelectionState.swift app/PasteService.swift app/PasteTrust.swift \
                    app/ClipboardWatcher.swift \
                    app/AppActions.swift app/MainMenuBuilder.swift app/LaunchAtLogin.swift \
                    app/ActivationPolicyController.swift app/PlainTextEditor.swift \
                    app/PreferencesView.swift app/HotKeyRecorderView.swift app/HotKeyManager.swift \
                    app/StyledTextEditor.swift app/RichTextEditing.swift \
                    app/NoticeBannerView.swift app/NoticeTimer.swift app/AppLog.swift \
                    app/StatusItemNotice.swift app/AppearanceManager.swift app/DesignTokens.swift \
                    app/MainWindowView.swift app/WindowKeyMonitor.swift app/NoteFocusMonitor.swift app/MainWindowController.swift
SYNC_SOURCES  := core/QtCompression.swift $(wildcard core/CopyQSync/Sources/CopyQSync/*.swift)

FRAMEWORKS := -framework AppKit -framework SwiftUI -framework Carbon \
              -framework ApplicationServices -framework CoreServices -framework CoreGraphics \
              -framework ImageIO -framework UniformTypeIdentifiers -framework ServiceManagement

BUILD_DIR       := build
DMG_NAME        := CopyQMac-$(VERSION).dmg
DMG             := $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGE       := $(BUILD_DIR)/dmg-stage
APP_STAGE       := $(BUILD_DIR)/$(APP_NAME)-bin
APP_BINARY      := $(MACOS_DIR)/$(APP_NAME)
TEST_BINARY     := $(BUILD_DIR)/CopyQmacTests
SYNC_BUILD_DIR  ?= .build
SYNC_LIBRARY    := $(SYNC_BUILD_DIR)/libCopyQSync.dylib

.PHONY: all build run test clean stage-resources dmg dmg-path

all: build

## Compile the app and CopyQSync module, then assemble, assert, and sign the app bundle.
build: $(APP_BINARY) $(CONTENTS)/Info.plist stage-resources $(SYNC_LIBRARY)
	@tools/assert-bundle-resources.sh $(BUNDLE)
	@$(CODESIGN) --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

# Compile outside the bundle so the .dSYM and any other side products do not
# end up sealed inside the signed app.
$(APP_STAGE): $(CORE_SOURCES) $(APP_SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) $(FRAMEWORKS) $(CORE_SOURCES) $(APP_SOURCES) -o $@

$(APP_BINARY): $(APP_STAGE)
	@mkdir -p $(MACOS_DIR)
	@cp $< $@

$(CONTENTS)/Info.plist: app/Info.plist $(VERSION_FILE)
	@mkdir -p $(CONTENTS)
	@sed 's/__VERSION__/$(VERSION)/g' app/Info.plist > $@

# Prune staged resources and copy source resources into the bundle.
# No resource file that the source tree no longer has may survive a rebuild,
# and no source resource may be dropped from it.
stage-resources: $(ICON_SOURCE)
	@rm -rf $(RESOURCES_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp -R resources/. $(RESOURCES_DIR)/

$(SYNC_LIBRARY): $(SYNC_SOURCES)
	@mkdir -p $(SYNC_BUILD_DIR)
	$(SWIFTC) -O -module-name CopyQSync -lz -emit-library $(SYNC_SOURCES) -o $@

## Launch the built app.
run: build
	open $(BUNDLE)

## Print the path of the disk image `make dmg` produces.
dmg-path:
	@echo $(DMG)

## Package the app bundle into a compressed disk image.
dmg: build
	@rm -rf $(DMG_STAGE) $(DMG)
	@mkdir -p $(DMG_STAGE)
	@cp -R $(BUNDLE) $(DMG_STAGE)/
	@ln -s /Applications $(DMG_STAGE)/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_STAGE) -ov -format UDZO $(DMG)
	@rm -rf $(DMG_STAGE)
	@echo "Packaged $(DMG)"

## Run the app and CopyQSync headless test suites.
test: $(TEST_BINARY)
	$(TEST_BINARY)
	tools/copyq-sync-tests.sh
	@if [ -d $(BUNDLE) ]; then \
		tools/assert-bundle-resources.sh $(BUNDLE); \
	fi

$(TEST_BINARY): $(CORE_SOURCES) $(TEST_SOURCES) $(TEST_APP_SOURCES) app/PasteboardBridge.swift
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) -DCOPYQMAC_TESTING -framework AppKit -framework SwiftUI \
		-framework Carbon -framework ApplicationServices -framework CoreServices -framework CoreGraphics \
		-framework ImageIO -framework UniformTypeIdentifiers -framework ServiceManagement \
		$(CORE_SOURCES) $(TEST_SOURCES) $(TEST_APP_SOURCES) app/PasteboardBridge.swift -o $@

clean:
	@rm -rf build $(SYNC_BUILD_DIR)
	@echo "Cleaned build and $(SYNC_BUILD_DIR)"
