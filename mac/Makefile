# Ditto for macOS
#
#   make            build a release Ditto.app into ./build
#   make debug      build a debug Ditto.app into ./build
#   make run        build and launch Ditto.app
#   make install    copy Ditto.app to /Applications
#   make clean      remove build products

APP_NAME    := Ditto
BUNDLE      := build/$(APP_NAME).app
CONFIG      ?= release
BIN_DIR     := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)

.PHONY: all debug release run install clean bundle

all: release

release:
	@$(MAKE) bundle CONFIG=release

debug:
	@$(MAKE) bundle CONFIG=debug

bundle:
	swift build -c $(CONFIG)
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp "$(shell swift build -c $(CONFIG) --show-bin-path)/DittoMac" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
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
