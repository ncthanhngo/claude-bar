//go:build windows

package tray

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
)

// Each account signed in through Claude Swap keeps its own WebView2
// profile, so its claude.ai session survives and a lost login can be
// renewed in the background (like the macOS app's WKWebView cookies).
// Profiles never hold tokens: only the claude.ai web session.

func profilesDir() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "ClaudeSwap", "profiles")
}

// profileFor is the profile dir of an account, keyed by identity (account
// numbers can be reused after a remove).
func profileFor(acc cswclient.Account) string {
	return filepath.Join(profilesDir(), identityKey(acc))
}

// identityKey names an account's files by email + organization.
func identityKey(acc cswclient.Account) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(acc.Email)) + "|" + acc.OrganizationUUID))
	return hex.EncodeToString(sum[:8])
}

func hasProfile(acc cswclient.Account) bool {
	st, err := os.Stat(profileFor(acc))
	return err == nil && st.IsDir()
}

// newPendingProfile is a fresh profile for a sign-in whose account is not
// known yet; adoptProfile files it under that account afterwards.
func newPendingProfile() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return filepath.Join(profilesDir(), "pending-"+hex.EncodeToString(b))
}

// adoptProfile makes a finished sign-in's profile the account's profile,
// replacing an older one. The sign-in process has exited, but WebView2's
// helpers may hold files for a moment, so it retries.
func adoptProfile(pending string, acc cswclient.Account) {
	target := profileFor(acc)
	for i := 0; i < 20; i++ {
		_ = os.RemoveAll(target)
		if os.Rename(pending, target) == nil {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	removeProfileDir(pending)
}

// cleanPendingProfiles removes profiles left by interrupted sign-ins.
func cleanPendingProfiles() {
	matches, _ := filepath.Glob(filepath.Join(profilesDir(), "pending-*"))
	for _, m := range matches {
		_ = os.RemoveAll(m)
	}
}
