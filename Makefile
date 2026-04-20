# Cyberdeck Screensaver — Build System
# Builds a universal macOS .saver bundle (arm64 + x86_64) with Metal shaders

BUNDLE_NAME  = CyberdeckSaver
BUNDLE       = build/$(BUNDLE_NAME).saver
INSTALL_DIR  = $(HOME)/Library/Screen\ Savers
SDK          = macosx
MIN_MACOS    = 14.0

SWIFT_SOURCES = $(wildcard Sources/*.swift)
METAL_SOURCES = $(wildcard Shaders/*.metal)

# Tool paths
SWIFTC   = xcrun -sdk $(SDK) swiftc
METAL    = $(shell xcrun --find metal)
METALLIB = $(shell xcrun --find metallib)
LIPO     = xcrun lipo

.PHONY: all clean install reinstall universal edit-config config-path zip

all: universal

# 1. Compile Metal shaders (universal by default)
build/Shaders.air: $(METAL_SOURCES)
	@mkdir -p build
	$(METAL) -c Shaders/Shaders.metal -o build/Shaders.air

build/default.metallib: build/Shaders.air
	$(METALLIB) build/Shaders.air -o build/default.metallib

# 2. Compile Swift — arm64
build/CyberdeckSaver-arm64: $(SWIFT_SOURCES)
	@mkdir -p build
	$(SWIFTC) \
		-emit-library \
		-module-name $(BUNDLE_NAME) \
		-target arm64-apple-macos$(MIN_MACOS) \
		-framework ScreenSaver \
		-framework Metal \
		-framework QuartzCore \
		-framework AppKit \
		-framework CoreText \
		-Xlinker -bundle \
		-o $@ \
		$(SWIFT_SOURCES)

# 3. Compile Swift — x86_64
build/CyberdeckSaver-x86_64: $(SWIFT_SOURCES)
	@mkdir -p build
	$(SWIFTC) \
		-emit-library \
		-module-name $(BUNDLE_NAME) \
		-target x86_64-apple-macos$(MIN_MACOS) \
		-framework ScreenSaver \
		-framework Metal \
		-framework QuartzCore \
		-framework AppKit \
		-framework CoreText \
		-Xlinker -bundle \
		-o $@ \
		$(SWIFT_SOURCES)

# 4. Lipo into universal binary
build/CyberdeckSaver-universal: build/CyberdeckSaver-arm64 build/CyberdeckSaver-x86_64
	$(LIPO) -create -output $@ $^

CONFIG_PATH = $(HOME)/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application\ Support/CyberdeckSaver/config.json

# 5. Assemble .saver bundle
universal: build/CyberdeckSaver-universal build/default.metallib Resources/Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	cp build/CyberdeckSaver-universal $(BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp build/default.metallib $(BUNDLE)/Contents/Resources/default.metallib
	@echo ""
	@echo "✓ Built universal $(BUNDLE)"
	@lipo -archs $(BUNDLE)/Contents/MacOS/$(BUNDLE_NAME)

# Install locally. User config lives in the sandbox container and is untouched.
install: universal
	@rm -rf $(INSTALL_DIR)/$(BUNDLE_NAME).saver
	cp -R $(BUNDLE) $(INSTALL_DIR)/
	@killall legacyScreenSaver 2>/dev/null || true
	@echo "✓ Installed to ~/Library/Screen Savers/"

# Open the user config. Path is inside the legacyScreenSaver sandbox container
# so it survives `make install`. Create on first use if the screensaver hasn't
# run yet and no config exists.
edit-config:
	@if [ ! -f $(CONFIG_PATH) ]; then \
		echo "Config not found — run the screensaver once to write defaults, or creating a minimal one now"; \
		mkdir -p $(dir $(CONFIG_PATH)); \
		echo '{"render":{"textRedrawHz":60,"glitch":false,"fontSize":12}}' > $(CONFIG_PATH); \
	fi
	$${EDITOR:-vim} $(CONFIG_PATH)
	@killall legacyScreenSaver 2>/dev/null || true
	@echo "✓ Config saved; screensaver will reload on next start"

# Print the config path (handy for scripting or Finder navigation).
config-path:
	@echo $(CONFIG_PATH)

# Rebuild + reinstall
reinstall: clean install

# Create a zip for AirDrop
zip: universal
	cd build && zip -r $(BUNDLE_NAME).saver.zip $(BUNDLE_NAME).saver
	@echo ""
	@echo "✓ Ready to AirDrop: build/$(BUNDLE_NAME).saver.zip"
	@echo "  On iMac: unzip → double-click .saver → Install"

clean:
	rm -rf build
	@echo "✓ Cleaned"
