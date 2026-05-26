package usecase

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CloudPush reads all accounts + backup credentials, encrypts them with the
// given passphrase, and writes the bundle to iCloud Drive.
//
// V3 push pipeline:
//  1. Refresh inactive tokens (Option B).
//  2. Acquire push lock (R5).
//  3. Build the local view of the bundle from registry + keychain.
//  4. Read the existing remote bundle and merge per-record: any account the
//     remote knows about but local doesn't is preserved, and any per-record
//     UpdatedAtTime newer than ours on the remote wins (#3 — last-writer-wins
//     per record instead of per file).
//  5. Stamp seq = lastSeq + 1 and prevHash = SHA-256(prev ciphertext) for
//     anti-rollback (#5).
//  6. Double-encrypt MCP payloads (#8).
//  7. Rotate ring buffer (#6), atomic write (#4), save sync state.
func (s *Service) CloudPush(ctx context.Context, passphrase string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}

	// Option B: refresh inactive tokens before acquiring the lock so the bundle
	// contains fresh credentials without holding the lock during network calls.
	// Hard transient failures (network, 5xx) block the push — re-trying later
	// is the right move. Per-account "needs re-login" (400 invalid_grant) and
	// rate-limited (429) are soft: the affected account's existing backup blob
	// is still pushed so the rest of the bundle can sync, and the user can
	// re-login that one account independently.
	if err := s.RefreshAllTokens(ctx); err != nil {
		var refreshErr *RefreshAllError
		if !errors.As(err, &refreshErr) || refreshErr.BlocksPush() {
			return fmt.Errorf("refresh inactive credentials before push: %w", err)
		}
	}

	// R5: acquire the file lock before reading any keychain data to serialise
	// against SwitchAccount, which also holds the lock while overwriting live.
	if err := s.Lock.Acquire(ctx); err != nil {
		return fmt.Errorf("acquire push lock: %w", err)
	}
	defer s.Lock.Release()

	bundle, err := s.buildLocalBundle(ctx, passphrase)
	if err != nil {
		return err
	}

	dest := cloudsync.BundlePath()
	prevCiphertext, _ := os.ReadFile(dest) // ok if missing
	mergeRemoteIntoBundle(bundle, prevCiphertext, passphrase)

	state, err := cloudsync.LoadSyncState(adapter.CloudSyncStateFile())
	if err != nil {
		return fmt.Errorf("load sync state: %w", err)
	}
	bundle.Seq = nextSeq(state.LastSeq, prevCiphertext, passphrase)
	if len(prevCiphertext) > 0 {
		bundle.PrevHash = cloudsync.HashCiphertext(prevCiphertext)
	}

	encrypted, err := cloudsync.Encrypt(bundle, passphrase)
	if err != nil {
		return fmt.Errorf("encrypt: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return fmt.Errorf("create iCloud dir: %w", err)
	}
	if err := cloudsync.RotateBackups(dest); err != nil {
		return fmt.Errorf("rotate backups: %w", err)
	}
	if err := cloudsync.WriteBundleAtomic(dest, encrypted); err != nil {
		return fmt.Errorf("write bundle: %w", err)
	}

	state.LastSeq = bundle.Seq
	state.LastBundleHash = cloudsync.HashCiphertext(encrypted)
	if err := cloudsync.SaveSyncState(adapter.CloudSyncStateFile(), state); err != nil {
		return fmt.Errorf("save sync state: %w", err)
	}
	return nil
}

// buildLocalBundle reads the registry + shared MCP + per-account credentials
// and returns a V3 bundle stamped with the current push time. Seq/PrevHash are
// left zero — the caller fills those in for iCloud push, or leaves them zero
// for file-export (anti-rollback is bypassed on the receiving side).
//
// Caller must hold the push lock so live-credential reads don't race
// SwitchAccount.
func (s *Service) buildLocalBundle(ctx context.Context, passphrase string) (*cloudsync.CloudBundle, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, fmt.Errorf("load registry: %w", err)
	}

	now := time.Now().UTC()
	bundle := &cloudsync.CloudBundle{
		Version:  3,
		PushedAt: now,
	}
	// Metadata-only push. The bundle intentionally omits CredentialBlob,
	// per-account MCPConnectors, and SharedMCPConnectors — those are
	// service tokens the user explicitly opted out of syncing. What
	// crosses iCloud is the account *roster* (email, nickname, org) so a
	// new Mac can see "these are the accounts that exist" and prompt the
	// user to run `claude /login` locally for each one. `passphrase` is
	// still required because the bundle ciphertext stays AES-GCM-sealed —
	// even an empty-credential bundle should not leak the email list to
	// anyone who can read the iCloud Drive file.
	_ = passphrase
	for _, acc := range reg.Accounts {
		bundle.Accounts = append(bundle.Accounts, cloudsync.BundleAccount{
			Number:           acc.Number,
			Email:            acc.Email,
			Nickname:         acc.Nickname,
			OrganizationName: acc.OrganizationName,
			OrganizationUUID: acc.OrganizationUUID,
			UpdatedAt:        now.Format(time.RFC3339),
			UpdatedAtTime:    now,
			CreatedAt:        acc.CreatedAt,
		})
	}

	if len(bundle.Accounts) == 0 {
		return nil, fmt.Errorf("no accounts to push")
	}
	return bundle, nil
}

// readAccountBlobForPush returns the credential blob to push for one account.
// Active account must come from Live with backup as fallback; inactive
// accounts come from Backup. An empty blob means the account has no
// credentials to publish (skip it).
func (s *Service) readAccountBlobForPush(ctx context.Context, reg *domain.Registry, acc *domain.Account) (string, error) {
	if acc.Number == reg.ActiveAccountNumber {
		live, liveErr := s.Live.Read(ctx)
		if liveErr == nil && live != "" {
			return string(live), nil
		}
		bak, _ := s.Backup.Read(ctx, acc.Number, acc.Email)
		if bak == "" {
			return "", fmt.Errorf("active account %d (%s): live credential unreadable and no backup — cannot push", acc.Number, acc.Email)
		}
		return string(bak), nil
	}
	bak, err := s.Backup.Read(ctx, acc.Number, acc.Email)
	if err != nil || bak == "" {
		return "", nil
	}
	return string(bak), nil
}

// mergeRemoteIntoBundle keeps remote-only records and records with a strictly
// newer UpdatedAtTime than the local bundle entry. Local always wins on ties
// so a re-push without local changes is idempotent.
//
// MCP payloads remain in their stored form (already double-encrypted on the
// remote side) — we do not need to re-encrypt them.
func mergeRemoteIntoBundle(local *cloudsync.CloudBundle, remoteCiphertext []byte, passphrase string) {
	if len(remoteCiphertext) == 0 {
		return
	}
	remote, err := cloudsync.Decrypt(remoteCiphertext, passphrase)
	if err != nil {
		// Remote unreadable (wrong passphrase, corrupt) → cannot safely merge.
		// Proceed with local-only push; the user gets a clean overwrite.
		return
	}

	byKey := map[string]int{} // identity key -> index into local.Accounts
	for i, a := range local.Accounts {
		byKey[accountKey(a)] = i
	}

	for _, ra := range remote.Accounts {
		idx, exists := byKey[accountKey(ra)]
		if !exists {
			// Remote has an account this device doesn't know about — preserve it.
			local.Accounts = append(local.Accounts, ra)
			continue
		}
		// Same identity in both. Newer UpdatedAtTime wins. Local wins on tie.
		if ra.UpdatedAtTime.After(local.Accounts[idx].UpdatedAtTime) {
			local.Accounts[idx] = ra
		}
	}

	// Shared MCP: prefer local. If local has zero connectors and remote has some,
	// preserve remote (another device may have just connected one).
	if len(local.SharedMCPConnectors) == 0 && len(remote.SharedMCPConnectors) > 0 {
		local.SharedMCPConnectors = remote.SharedMCPConnectors
	}
}

// accountKey identifies an account across devices. Org UUID + email is the
// stablest pair (numbers are device-local registry slots).
func accountKey(a cloudsync.BundleAccount) string {
	return a.OrganizationUUID + "|" + a.Email
}

// nextSeq returns the seq to stamp on the new bundle. We trust whichever is
// larger: our last known seq, or the seq inside the remote bundle (another
// device may have pushed a higher seq we never synced from).
func nextSeq(localLast uint64, remoteCiphertext []byte, passphrase string) uint64 {
	best := localLast
	if len(remoteCiphertext) > 0 {
		if remote, err := cloudsync.Decrypt(remoteCiphertext, passphrase); err == nil {
			if remote.Seq > best {
				best = remote.Seq
			}
		}
	}
	return best + 1
}

func (s *Service) bundleMCPConnectors(ctx context.Context, accountNum int, metas domain.AccountConnectors, passphrase string) ([]cloudsync.BundleMCPConnector, error) {
	if len(metas) == 0 {
		return nil, nil
	}
	out := make([]cloudsync.BundleMCPConnector, 0, len(metas))
	for _, svc := range domain.AllMCPServices {
		meta, ok := metas[svc]
		if !ok || meta == nil {
			continue
		}
		payload, err := s.MCPSecrets.Read(ctx, accountNum, svc)
		if err != nil {
			return nil, fmt.Errorf("read mcp secret %s/%d: %w", svc, accountNum, err)
		}
		if payload == "" {
			continue
		}
		sealed, err := cloudsync.EncryptMCPPayload(payload, passphrase)
		if err != nil {
			return nil, fmt.Errorf("seal mcp payload %s/%d: %w", svc, accountNum, err)
		}
		out = append(out, cloudsync.BundleMCPConnector{
			Service:          svc,
			Payload:          sealed,
			PayloadEncrypted: true,
			Enabled:          meta.Enabled,
			DisplayName:      meta.DisplayName,
			Account:          meta.Account,
			Scopes:           append([]string(nil), meta.Scopes...),
			ConnectedAt:      meta.ConnectedAt,
			LastVerified:     meta.LastVerified,
			NeedsReauth:      meta.NeedsReauth,
		})
	}
	return out, nil
}

