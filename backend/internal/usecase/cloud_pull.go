package usecase

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CloudPull decrypts the iCloud Drive bundle and restores all accounts.
// Existing accounts are overwritten; the active account is NOT changed.
//
// V3 additions:
//   - Anti-rollback check (#5): a bundle with seq < lastSeq is rejected before
//     any keychain write.
//   - MCP payload double-decrypt (#8): payloads with PayloadEncrypted=true are
//     unwrapped through the HKDF sub-key before being written to keychain.
//   - Hash chain drift is logged (not fatal) so the user can see when another
//     device pushed between syncs.
func (s *Service) CloudPull(ctx context.Context, passphrase string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}

	// Read and decrypt outside the lock: decrypt is CPU-intensive and the window
	// between read and lock-acquire is small. A concurrent push that lands here
	// means the pull restores a bundle that is at most one push cycle stale —
	// acceptable for a best-effort sync.
	data, err := readBundleWithFallback(cloudsync.BundlePath())
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}

	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return err
	}

	state, err := cloudsync.LoadSyncState(adapter.CloudSyncStateFile())
	if err != nil {
		return fmt.Errorf("load sync state: %w", err)
	}
	if err := checkAntiRollback(bundle, state); err != nil {
		return err
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	if err := s.applyBundle(ctx, bundle, passphrase, nil); err != nil {
		return err
	}

	state.LastSeq = maxU64(state.LastSeq, bundle.Seq)
	state.LastBundleHash = cloudsync.HashCiphertext(data)
	if err := cloudsync.SaveSyncState(adapter.CloudSyncStateFile(), state); err != nil {
		return fmt.Errorf("save sync state: %w", err)
	}
	return nil
}

// readBundleWithFallback returns the primary bundle if readable, otherwise
// tries each ring-buffer backup in newest-first order. Decrypt failures are
// the caller's job to detect — this layer only handles missing/empty files.
func readBundleWithFallback(primary string) ([]byte, error) {
	data, err := os.ReadFile(primary)
	if err == nil && len(data) > 0 {
		return data, nil
	}
	primaryErr := err
	for _, p := range cloudsync.BackupPaths(primary) {
		if d, e := os.ReadFile(p); e == nil && len(d) > 0 {
			return d, nil
		}
	}
	if primaryErr != nil {
		return nil, primaryErr
	}
	return nil, fmt.Errorf("bundle empty and no backups available")
}

// checkAntiRollback rejects bundles whose seq has gone backwards relative to
// what this device last saw. Equal seq is allowed (same bundle, repeat pull);
// strictly less is a rollback attempt.
//
// State-zero (lastSeq=0) is a fresh device — accept anything.
// Bundle-zero (seq=0) is a V1/V2 legacy bundle — accept and let the next push
// stamp a real seq.
func checkAntiRollback(bundle *cloudsync.CloudBundle, state *cloudsync.SyncState) error {
	if state.LastSeq == 0 || bundle.Seq == 0 {
		return nil
	}
	if bundle.Seq < state.LastSeq {
		return fmt.Errorf("rollback rejected: bundle seq %d < last seen %d", bundle.Seq, state.LastSeq)
	}
	return nil
}

func maxU64(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}

// Cloud bundles carry the source machine's account numbers, but numbers are
// local registry slots. Preserve local identities when a bundle slot collides.
func pullAccountNumber(reg *domain.Registry, ba cloudsync.BundleAccount) (int, bool) {
	if num := reg.FindByIdentity(ba.Email, ba.OrganizationUUID); num != 0 {
		return num, true
	}
	if _, exists := reg.Accounts[ba.Number]; !exists {
		return ba.Number, false
	}
	return reg.NextAccountNumber(), false
}

// CloudStatus returns metadata about the iCloud Drive bundle.
//
// BackupCount counts ring-buffer rotations available for manual restore.
// LastSeenSeq is the highest bundle seq this device has applied — useful for
// the UI to indicate "you have unsynced local changes" when the remote seq
// (visible via list-backups) is behind it.
type CloudStatusResult struct {
	Exists      bool      `json:"exists"`
	Path        string    `json:"path"`
	PushedAt    time.Time `json:"pushedAt,omitempty"`
	SizeKB      int64     `json:"sizeKb,omitempty"`
	BackupCount int       `json:"backupCount"`
	LastSeenSeq uint64    `json:"lastSeenSeq,omitempty"`
}

// CloudStatus checks whether a bundle exists and when it was last pushed.
func (s *Service) CloudStatus(_ context.Context) (*CloudStatusResult, error) {
	path := cloudsync.BundlePath()
	res := &CloudStatusResult{Path: path}

	if state, err := cloudsync.LoadSyncState(adapter.CloudSyncStateFile()); err == nil {
		res.LastSeenSeq = state.LastSeq
	}
	res.BackupCount = len(cloudsync.BackupPaths(path))

	info, err := os.Stat(path)
	if err != nil {
		return res, nil
	}
	res.Exists = true
	res.PushedAt = info.ModTime().UTC()
	res.SizeKB = info.Size() / 1024
	return res, nil
}

// CloudBackupInfo describes one bundle copy available for restore. Slot 0 is
// the current bundle; slots >=1 are ring-buffer rotations (1 = newest backup).
//
// Seq and PushedAtInBundle require successful decryption. If Decrypted is
// false, the caller saw the file metadata only — typical when passphrase is
// wrong or the file is V1/V2 legacy without a seq stamp.
type CloudBackupInfo struct {
	Slot              int       `json:"slot"`
	Path              string    `json:"path"`
	FileModTime       time.Time `json:"fileModTime"`
	SizeKB            int64     `json:"sizeKb"`
	Decrypted         bool      `json:"decrypted"`
	Seq               uint64    `json:"seq,omitempty"`
	PushedAtInBundle  time.Time `json:"pushedAtInBundle,omitempty"`
	AccountCount      int       `json:"accountCount,omitempty"`
}

// CloudListBackups enumerates the current bundle (slot 0) plus every existing
// ring-buffer rotation, decrypting each with the given passphrase so the UI
// can show real seq/pushedAt for each.
//
// An empty passphrase is allowed: in that case only file metadata is returned.
// A wrong passphrase produces entries with Decrypted=false rather than an
// error so the user still sees the list.
func (s *Service) CloudListBackups(_ context.Context, passphrase string) ([]CloudBackupInfo, error) {
	primary := cloudsync.BundlePath()
	all := []string{primary}
	all = append(all, cloudsync.BackupPaths(primary)...)

	var out []CloudBackupInfo
	for i, path := range all {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		entry := CloudBackupInfo{
			Slot:        i,
			Path:        path,
			FileModTime: info.ModTime().UTC(),
			SizeKB:      info.Size() / 1024,
		}
		if passphrase != "" {
			if data, rErr := os.ReadFile(path); rErr == nil {
				if bundle, dErr := cloudsync.Decrypt(data, passphrase); dErr == nil {
					entry.Decrypted = true
					entry.Seq = bundle.Seq
					entry.PushedAtInBundle = bundle.PushedAt
					entry.AccountCount = len(bundle.Accounts)
				}
			}
		}
		out = append(out, entry)
	}
	return out, nil
}

// CloudRestoreBackup restores accounts from a specific ring-buffer slot rather
// than the current bundle. Slot 0 is the current bundle (equivalent to
// CloudPull); slots >=1 are progressively older copies.
//
// Anti-rollback is intentionally bypassed: an explicit restore is a deliberate
// rewind by the user. After a successful restore we set LastSeq to the
// restored bundle's seq so future pulls operate from this baseline.
func (s *Service) CloudRestoreBackup(ctx context.Context, passphrase string, slot int) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}
	if slot < 0 {
		return fmt.Errorf("slot must be >= 0")
	}

	primary := cloudsync.BundlePath()
	path := primary
	if slot > 0 {
		backups := cloudsync.BackupPaths(primary)
		if slot > len(backups) {
			return fmt.Errorf("slot %d does not exist (have %d backups)", slot, len(backups))
		}
		path = backups[slot-1]
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read backup slot %d: %w", slot, err)
	}
	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return err
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	if err := s.applyBundle(ctx, bundle, passphrase, nil); err != nil {
		return err
	}

	// Rewind sync state to this bundle's seq so the next push uses seq+1 and a
	// fresh device pulling sees a consistent chain.
	state, _ := cloudsync.LoadSyncState(adapter.CloudSyncStateFile())
	state.LastSeq = bundle.Seq
	state.LastBundleHash = cloudsync.HashCiphertext(data)
	if err := cloudsync.SaveSyncState(adapter.CloudSyncStateFile(), state); err != nil {
		return fmt.Errorf("save sync state: %w", err)
	}
	return nil
}

// applyBundle writes bundle contents into the registry + keychain. Extracted
// so CloudPull and CloudRestoreBackup share one code path for everything
// after the decrypt + lock-acquire dance.
//
// If selectedIdentities is non-nil, only bundle accounts whose identity key
// (email|orgUUID) is in the set are applied. A nil selection means "all".
func (s *Service) applyBundle(ctx context.Context, bundle *cloudsync.CloudBundle, passphrase string, selectedIdentities map[string]bool) error {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return fmt.Errorf("load registry: %w", err)
	}
	restoreMCP := bundle.Version >= 2
	if restoreMCP {
		shared, err := s.restoreMCPConnectors(ctx, 0, bundle.SharedMCPConnectors, passphrase)
		if err != nil {
			return err
		}
		reg.SharedMCPConnectors = shared
	}

	var failures []string
	for _, ba := range bundle.Accounts {
		if selectedIdentities != nil && !selectedIdentities[bundleIdentityKey(ba)] {
			continue
		}
		accountNum, exists := pullAccountNumber(reg, ba)
		bundleBlob := domain.CredentialBlob(ba.CredentialBlob)
		writeBlob := bundleBlob

		localBlob, localErr := s.Backup.Read(ctx, accountNum, ba.Email)
		if localErr == nil && localBlob != "" {
			bundlePayload, bErr := bundleBlob.Extract()
			localPayload, lErr := localBlob.Extract()
			if bErr == nil && lErr == nil && localPayload.ExpiresAt > bundlePayload.ExpiresAt {
				writeBlob = localBlob
			}
		}

		if writeErr := s.Backup.Write(ctx, accountNum, ba.Email, writeBlob); writeErr != nil {
			failures = append(failures, fmt.Sprintf("account %d (%s): %v", accountNum, ba.Email, writeErr))
			continue
		}

		if !exists {
			reg.Accounts[accountNum] = &domain.Account{}
			reg.Sequence = append(reg.Sequence, accountNum)
		}
		acc := reg.Accounts[accountNum]
		acc.Number = accountNum
		acc.Email = ba.Email
		acc.Nickname = ba.Nickname
		acc.OrganizationName = ba.OrganizationName
		acc.OrganizationUUID = ba.OrganizationUUID
		if restoreMCP {
			connectors, err := s.restoreMCPConnectors(ctx, accountNum, ba.MCPConnectors, passphrase)
			if err != nil {
				return err
			}
			acc.MCPConnectors = connectors
		}
		if acc.CreatedAt.IsZero() {
			if !ba.CreatedAt.IsZero() {
				acc.CreatedAt = ba.CreatedAt.UTC()
			} else {
				acc.CreatedAt = time.Now().UTC()
			}
		}
	}

	if saveErr := s.Registry.Save(ctx, reg); saveErr != nil {
		return fmt.Errorf("save registry: %w", saveErr)
	}

	if len(failures) > 0 {
		return fmt.Errorf("partial restore (%d/%d): %s",
			len(bundle.Accounts)-len(failures), len(bundle.Accounts),
			strings.Join(failures, "; "))
	}
	return nil
}

// bundleIdentityKey is the cross-device identity for a bundle account.
// Matches domain.Account.IdentityKey on the local side.
func bundleIdentityKey(a cloudsync.BundleAccount) string {
	return a.Email + "|" + a.OrganizationUUID
}

// CloudPreviewRow describes one account that exists locally, in the bundle,
// or both. Used by the restore-preview UI to let the user pick which entries
// to apply.
//
// Status:
//   - "both"        — same identity exists locally and in the bundle
//   - "remoteOnly"  — only in the bundle (new account on restore)
//   - "localOnly"   — only locally (restore does not touch this row)
type CloudPreviewRow struct {
	Identity         string    `json:"identity"`
	Email            string    `json:"email"`
	Nickname         string    `json:"nickname,omitempty"`
	OrganizationName string    `json:"organizationName,omitempty"`
	OrganizationUUID string    `json:"organizationUuid,omitempty"`
	LocalCreatedAt   time.Time `json:"localCreatedAt,omitempty"`
	RemoteCreatedAt  time.Time `json:"remoteCreatedAt,omitempty"`
	Status           string    `json:"status"`
}

// CloudPreview decrypts the bundle at the given slot and returns a merged
// list comparing local registry vs bundle accounts by identity (email|orgUUID).
// Slot 0 is the current bundle; slot >= 1 walks the ring-buffer backups.
// Read-only — does not touch keychain or registry.
func (s *Service) CloudPreview(ctx context.Context, passphrase string, slot int) ([]CloudPreviewRow, error) {
	if passphrase == "" {
		return nil, fmt.Errorf("passphrase must not be empty")
	}
	if slot < 0 {
		return nil, fmt.Errorf("slot must be >= 0")
	}

	primary := cloudsync.BundlePath()
	path := primary
	if slot > 0 {
		backups := cloudsync.BackupPaths(primary)
		if slot > len(backups) {
			return nil, fmt.Errorf("slot %d does not exist (have %d backups)", slot, len(backups))
		}
		path = backups[slot-1]
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read bundle slot %d: %w", slot, err)
	}
	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return nil, err
	}

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, fmt.Errorf("load registry: %w", err)
	}

	rows := map[string]*CloudPreviewRow{}
	for _, acc := range reg.Accounts {
		key := acc.IdentityKey()
		rows[key] = &CloudPreviewRow{
			Identity:         key,
			Email:            acc.Email,
			Nickname:         acc.Nickname,
			OrganizationName: acc.OrganizationName,
			OrganizationUUID: acc.OrganizationUUID,
			LocalCreatedAt:   acc.CreatedAt,
			Status:           "localOnly",
		}
	}
	for _, ba := range bundle.Accounts {
		key := bundleIdentityKey(ba)
		if row, ok := rows[key]; ok {
			row.RemoteCreatedAt = ba.CreatedAt
			row.Status = "both"
			// Prefer remote nickname/orgName if the local copy is missing them
			// — small UX nicety so the table is not blank.
			if row.Nickname == "" {
				row.Nickname = ba.Nickname
			}
			if row.OrganizationName == "" {
				row.OrganizationName = ba.OrganizationName
			}
			continue
		}
		rows[key] = &CloudPreviewRow{
			Identity:         key,
			Email:            ba.Email,
			Nickname:         ba.Nickname,
			OrganizationName: ba.OrganizationName,
			OrganizationUUID: ba.OrganizationUUID,
			RemoteCreatedAt:  ba.CreatedAt,
			Status:           "remoteOnly",
		}
	}

	out := make([]CloudPreviewRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, *r)
	}
	// Stable order: remoteOnly first, then both, then localOnly; alpha by email within.
	statusRank := map[string]int{"remoteOnly": 0, "both": 1, "localOnly": 2}
	sortPreviewRows(out, statusRank)
	return out, nil
}

func sortPreviewRows(rows []CloudPreviewRow, rank map[string]int) {
	// Tiny insertion sort — rows are O(10s), not worth importing sort for one place.
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0; j-- {
			a, b := rows[j-1], rows[j]
			ra, rb := rank[a.Status], rank[b.Status]
			if ra < rb || (ra == rb && a.Email <= b.Email) {
				break
			}
			rows[j-1], rows[j] = b, a
		}
	}
}

// CloudPullSelective restores only the bundle accounts whose identity key is
// present in `identities`. Identities = "email|orgUUID". Slot 0 enforces
// anti-rollback; slot > 0 bypasses it (same as CloudRestoreBackup).
func (s *Service) CloudPullSelective(ctx context.Context, passphrase string, slot int, identities []string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}
	if slot < 0 {
		return fmt.Errorf("slot must be >= 0")
	}
	if len(identities) == 0 {
		return fmt.Errorf("no accounts selected")
	}

	primary := cloudsync.BundlePath()
	path := primary
	if slot > 0 {
		backups := cloudsync.BackupPaths(primary)
		if slot > len(backups) {
			return fmt.Errorf("slot %d does not exist (have %d backups)", slot, len(backups))
		}
		path = backups[slot-1]
	}

	data, err := readBundleWithFallback(path)
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}
	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return err
	}

	state, err := cloudsync.LoadSyncState(adapter.CloudSyncStateFile())
	if err != nil {
		return fmt.Errorf("load sync state: %w", err)
	}
	if slot == 0 {
		if err := checkAntiRollback(bundle, state); err != nil {
			return err
		}
	}

	selected := make(map[string]bool, len(identities))
	for _, id := range identities {
		selected[id] = true
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	if err := s.applyBundle(ctx, bundle, passphrase, selected); err != nil {
		return err
	}

	if slot == 0 {
		state.LastSeq = maxU64(state.LastSeq, bundle.Seq)
	} else {
		state.LastSeq = bundle.Seq
	}
	state.LastBundleHash = cloudsync.HashCiphertext(data)
	if err := cloudsync.SaveSyncState(adapter.CloudSyncStateFile(), state); err != nil {
		return fmt.Errorf("save sync state: %w", err)
	}
	return nil
}

// CloudForget deletes the encrypted bundle from iCloud Drive, all backup
// rotations, and the local sync state.
func (s *Service) CloudForget(_ context.Context) error {
	primary := cloudsync.BundlePath()
	for _, p := range append([]string{primary}, cloudsync.BackupPaths(primary)...) {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := os.Remove(adapter.CloudSyncStateFile()); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *Service) restoreMCPConnectors(ctx context.Context, accountNum int, connectors []cloudsync.BundleMCPConnector, passphrase string) (domain.AccountConnectors, error) {
	if len(connectors) == 0 {
		if accountNum == 0 {
			for _, svc := range domain.AllMCPServices {
				if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
					return nil, fmt.Errorf("delete stale shared mcp secret %s: %w", svc, err)
				}
			}
		}
		return nil, nil
	}
	out := domain.AccountConnectors{}
	seen := map[domain.MCPService]bool{}
	for _, c := range connectors {
		if c.Service == "" || c.Payload == "" {
			continue
		}
		payload := c.Payload
		if c.PayloadEncrypted {
			pt, err := cloudsync.DecryptMCPPayload(c.Payload, passphrase)
			if err != nil {
				return nil, fmt.Errorf("decrypt mcp payload %s/%d: %w", c.Service, accountNum, err)
			}
			payload = pt
		}
		if err := s.MCPSecrets.Write(ctx, accountNum, c.Service, payload); err != nil {
			return nil, fmt.Errorf("restore mcp secret %s/%d: %w", c.Service, accountNum, err)
		}
		out[c.Service] = &domain.MCPConnector{
			Enabled:      c.Enabled,
			DisplayName:  c.DisplayName,
			Account:      c.Account,
			Scopes:       append([]string(nil), c.Scopes...),
			ConnectedAt:  c.ConnectedAt,
			LastVerified: c.LastVerified,
			NeedsReauth:  c.NeedsReauth,
		}
		seen[c.Service] = true
	}
	for _, svc := range domain.AllMCPServices {
		if !seen[svc] {
			if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
				return nil, fmt.Errorf("delete stale mcp secret %s/%d: %w", svc, accountNum, err)
			}
		}
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}
