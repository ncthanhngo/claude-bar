package ssh

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
)

// sshPasswordServiceFormat is the Keychain service for a host's SSH password:
// "claude-bar-ssh:<host-name>". The password lives ONLY here — never in
// hosts.json — so a leaked profile file exposes no credentials.
const sshPasswordServiceFormat = "claude-bar-ssh:%s"

func sshPasswordKeychain(hostName string) *keychain.Keychain {
	user := os.Getenv("USER")
	if user == "" {
		user = "user"
	}
	return keychain.New(fmt.Sprintf(sshPasswordServiceFormat, hostName), user)
}

// ReadPassword returns the stored password for a host, or "" when none is set
// (or the Keychain read fails). A missing password simply means key-only auth.
func ReadPassword(ctx context.Context, hostName string) string {
	pw, err := sshPasswordKeychain(hostName).Read(ctx)
	if err != nil {
		return ""
	}
	return pw
}

// WritePassword upserts a host's SSH password in the Keychain.
func WritePassword(ctx context.Context, hostName, password string) error {
	return sshPasswordKeychain(hostName).Write(ctx, password)
}

// DeletePassword removes a host's stored password. Absent is not an error.
func DeletePassword(ctx context.Context, hostName string) error {
	if err := sshPasswordKeychain(hostName).Delete(ctx); err != nil && !errors.Is(err, keychain.ErrNotFound) {
		return err
	}
	return nil
}
