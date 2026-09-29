# Ditto for macOS
#
#   make            build a release Ditto.app into ./build
#   make debug      build a debug Ditto.app into ./build
#   make universal  build a release Ditto.app for arm64 and x86_64
#   make run        build and launch Ditto.app
#   make install    copy Ditto.app to /Applications
#   make clean      remove build products

APP_NAME    := Ditto
BUNDLE      := build/$(APP_NAME).app
CONFIG      ?= release

# Architectures to build. Empty means "whatever this Mac is", which is what you
# want while developing; CI sets it to both so the app runs on Intel Macs too.
ARCHS       ?=
ARCH_FLAGS  := $(foreach arch,$(ARCHS),--arch $(arch))
SWIFT_BUILD := swift build -c $(CONFIG) $(ARCH_FLAGS)

.PHONY: all debug release universal run install clean bundle

all: release

release:
	@$(MAKE) bundle CONFIG=release

debug:
	@$(MAKE) bundle CONFIG=debug

universal:
	@$(MAKE) bundle CONFIG=release ARCHS="arm64 x86_64"

bundle:
	$(SWIFT_BUILD)
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp "$(shell $(SWIFT_BUILD) --show-bin-path)/DittoMac" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then \
		cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"; \
		/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$(BUNDLE)/Contents/Info.plist" >/dev/null 2>&1 || true; \
	fi
	@printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@# An ad-hoc signature keeps the Accessibility grant stable across rebuilds
	@codesign --force --deep --sign - \
		--entitlements Ditto.entitlements \
		"$(BUNDLE)" >/dev/null 2>&1 || \
		codesign --force --deep --sign - "$(BUNDLE)" >/dev/null 2>&1 || true
	@echo "built $(BUNDLE)"

run: bundle
	@killall $(APP_NAME) 2>/dev/null || true
	open "$(BUNDLE)"

install: release
	@rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUNDLE)" /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build .build
