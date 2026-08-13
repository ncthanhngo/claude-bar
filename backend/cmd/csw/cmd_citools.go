package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/citools"
)

// runCITools dispatches `csw citools <status|install>`. The Daily → Tools
// "CI" surface calls this to install the machine-wide ci-watch/glpush tooling.
// PATs stay in the backend (read from Keychain) — never returned to the UI.
func runCITools(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw citools <status|install>")
	}
	switch args[0] {
	case "status":
		return json.NewEncoder(os.Stdout).Encode(citools.Inspect(ctx))
	case "install":
		return json.NewEncoder(os.Stdout).Encode(citools.Install(ctx))
	default:
		return fmt.Errorf("unknown citools subcommand: %s", args[0])
	}
}
