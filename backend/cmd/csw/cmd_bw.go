package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// runBW dispatches `csw bw <status|unlock|lock>`. The widget Diagnostics
// Bitwarden card calls these. The unlock token IS persisted to a local
// file under `~/Library/Application Support/.../bw-session` so that the
// `csw mcp serve` subprocess (which runs in a different process) can read
// it at tool-call time. File is 0600.
func runBW(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw bw <status|unlock|lock>")
	}
	switch args[0] {
	case "status":
		return runBWStatus(ctx)
	case "unlock":
		return runBWUnlock(ctx, args[1:])
	case "lock":
		return runBWLock(ctx)
	default:
		return fmt.Errorf("unknown bw subcommand: %s", args[0])
	}
}

func bwSessionFile() string {
	dir, _ := os.UserHomeDir()
	return dir + "/Library/Application Support/claude-swap-widget/bw-session"
}

type bwStatus struct {
	BinaryFound bool   `json:"binaryFound"`
	BinaryPath  string `json:"binaryPath,omitempty"`
	Unlocked    bool   `json:"unlocked"`
	UnlockedAt  string `json:"unlockedAt,omitempty"`
	ServerURL   string `json:"serverUrl,omitempty"`
	UserEmail   string `json:"userEmail,omitempty"`
}

func runBWStatus(_ context.Context) error {
	st := bwStatus{}
	if p, err := exec.LookPath("bw"); err == nil {
		st.BinaryFound = true
		st.BinaryPath = p
	}
	if info, err := os.Stat(bwSessionFile()); err == nil {
		st.Unlocked = true
		st.UnlockedAt = info.ModTime().UTC().Format(time.RFC3339)
	}
	return json.NewEncoder(os.Stdout).Encode(st)
}

func runBWUnlock(_ context.Context, _ []string) error {
	// Passphrase comes from stdin. `bw unlock --raw` prints session token.
	pass, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	passphrase := strings.TrimSpace(string(pass))
	if passphrase == "" {
		return errors.New("passphrase required on stdin")
	}
	cmd := exec.Command("bw", "unlock", "--raw", passphrase)
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("bw unlock: %w", err)
	}
	tok := strings.TrimSpace(string(out))
	if tok == "" {
		return errors.New("bw returned empty session")
	}
	if err := adapter.EnsureDataDir(); err != nil {
		return err
	}
	if err := os.WriteFile(bwSessionFile(), []byte(tok), 0o600); err != nil {
		return err
	}
	fmt.Println("unlocked")
	return nil
}

func runBWLock(_ context.Context) error {
	_ = os.Remove(bwSessionFile())
	cmd := exec.Command("bw", "lock")
	_ = cmd.Run()
	fmt.Println("locked")
	return nil
}
