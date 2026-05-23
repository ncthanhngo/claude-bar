# Claude Bar — build & package
#
# Targets:
#   make backend    build csw binary          -> backend/bin/csw
#   make widget     build SwiftPM executable
#   make app        bundle ClaudeBar.app       -> release/ClaudeBar.app
#   make release    build app + create zip     -> release/ClaudeBar.zip
#   make install    copy to /Applications/ClaudeBar.app
#   make test       go vet + swift test
#   make clean      wipe release/ + .build/ + backend/bin/

SHELL        := /bin/bash
DISPLAY_NAME := ClaudeBar
EXECUTABLE   := ClaudeSwapWidget
BUNDLE_ID    := dev.ncthanhngo.claude-bar
SIGN_ID      := ClaudeSwapWidgetLocalDev

BACKEND_BIN  := backend/bin/csw
WIDGET_BUILD := widget/.build/release/$(EXECUTABLE)
APP_BUNDLE   := release/$(DISPLAY_NAME).app

# sqlite_fts5: enables SQLite FTS5 full-text search inside the SQLCipher
# amalgamation used by chatstorage/messages_repo.go. Without this tag the
# messages_fts virtual-table migration fails with "no such module: fts5".
GO_TAGS := sqlite_fts5

.PHONY: all backend widget app release install test clean

all: app

backend:
	@mkdir -p backend/bin
	cd backend && CGO_ENABLED=1 go build -trimpath -tags $(GO_TAGS) \
	  -ldflags="-s -w -X main.defaultGDriveClientID=$(GDRIVE_CLIENT_ID)" \
	  -o bin/csw ./cmd/csw

widget:
	cd widget && swift build -c release

app: backend widget
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	cp $(WIDGET_BUILD)              $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE)
	cp $(BACKEND_BIN)               $(APP_BUNDLE)/Contents/Resources/csw
	cp packaging/icon.png           $(APP_BUNDLE)/Contents/Resources/icon.png
	cp packaging/AppIcon.icns       $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp packaging/Info.plist         $(APP_BUNDLE)/Contents/Info.plist
	# Sparkle 2 lives at @rpath/Sparkle.framework — copy the built framework
	# next to the executable so dyld can resolve it. SwiftPM produces it at
	# widget/.build/<arch>-apple-macosx/release/Sparkle.framework.
	@arch=$$(uname -m); \
	  if [ "$$arch" = "arm64" ]; then triple=arm64-apple-macosx; \
	  else triple=x86_64-apple-macosx; fi; \
	  cp -R widget/.build/$$triple/release/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	codesign --force --deep --sign "$(SIGN_ID)" $(APP_BUNDLE) 2>/dev/null || \
	  codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

release: app
	@rm -f release/$(DISPLAY_NAME).zip
	cd release && zip -r --symlinks $(DISPLAY_NAME).zip $(DISPLAY_NAME).app
	@echo "SHA256: $$(shasum -a 256 release/$(DISPLAY_NAME).zip | cut -d' ' -f1)"
	@echo "Release: release/$(DISPLAY_NAME).zip"

install: app
	@rm -rf /Applications/$(DISPLAY_NAME).app
	cp -R $(APP_BUNDLE) /Applications/$(DISPLAY_NAME).app
	codesign --force --deep --sign "$(SIGN_ID)" /Applications/$(DISPLAY_NAME).app 2>/dev/null || \
	  codesign --force --deep --sign - /Applications/$(DISPLAY_NAME).app
	@echo "Installed /Applications/$(DISPLAY_NAME).app"

test:
	cd backend && CGO_ENABLED=1 go vet -tags $(GO_TAGS) ./... && \
	  CGO_ENABLED=1 go test -tags $(GO_TAGS) ./...
	cd widget && swift test

clean:
	rm -rf release backend/bin widget/.build
