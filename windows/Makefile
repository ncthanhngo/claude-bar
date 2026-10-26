# Builds Claude Swap for Windows from any OS (pure Go, no cgo).
#   make build     -> dist/windows-{amd64,arm64}/{ClaudeSwap.exe,csw.exe}
#   make zip       -> dist/ClaudeSwap-<version>-windows-<arch>.zip
#   make test      -> unit tests (backend + tray client)
# The installer (installer/claudeswap.iss) is built on Windows by CI.

VERSION := $(shell cat VERSION)
ARCHES  := amd64 arm64
DIST    := dist
WINRES  := go run github.com/tc-hib/go-winres@v0.3.3
LDFLAGS := -s -w -X github.com/soi/claude-swap-widget/windows/internal/tray.Version=$(VERSION)

.PHONY: build zip test clean resources

build: resources
	@for arch in $(ARCHES); do \
		out=$(DIST)/windows-$$arch; mkdir -p $$out; \
		echo "==> $$arch"; \
		GOOS=windows GOARCH=$$arch go build -trimpath -ldflags "$(LDFLAGS) -H windowsgui" -o $$out/ClaudeSwap.exe ./cmd/claudeswap || exit 1; \
		(cd ../backend && GOOS=windows GOARCH=$$arch go build -trimpath -ldflags "-s -w" -o ../windows/$$out/csw.exe ./cmd/csw) || exit 1; \
	done

# Icon, version info and the GUI manifest (DPI aware, asInvoker) for the tray exe.
resources:
	cd cmd/claudeswap && $(WINRES) simply --arch amd64,arm64 \
		--icon ../../internal/tray/icon.ico --manifest gui \
		--product-name "Claude Swap" --file-description "Claude Swap" \
		--product-version $(VERSION) --file-version $(VERSION) --original-filename ClaudeSwap.exe

zip: build
	@for arch in $(ARCHES); do \
		(cd $(DIST)/windows-$$arch && zip -q -9 ../ClaudeSwap-$(VERSION)-windows-$$arch.zip ClaudeSwap.exe csw.exe) || exit 1; \
	done
	@ls -l $(DIST)/*.zip

test:
	go test ./...
	cd ../backend && go test ./...

clean:
	rm -rf $(DIST) cmd/claudeswap/*.syso
