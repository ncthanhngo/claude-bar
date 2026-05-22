package chatstorage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	// Side-effect: registers the SQLCipher-enabled "sqlite3" driver.
	_ "github.com/mutecomm/go-sqlcipher/v4"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// openEncryptedDB opens (and creates if missing) the SQLCipher DB for
// accountUUID. Key material flows: keyStore → master → HKDF → dbKey.
// Idempotent — re-opening returns a connection on the existing schema.
func openEncryptedDB(ctx context.Context, accountUUID string, keyStore port.ChatDBKeyStore, dbPath string) (*sql.DB, []byte, error) {
	master, err := loadOrCreateMasterKey(ctx, accountUUID, keyStore)
	if err != nil {
		return nil, nil, err
	}
	dbKey, attachKey := DeriveKeys(master)

	// Make the DB's parent dir exist + 0700 perms. Caller passes the path
	// (production = adapter.ChatDBFile, tests = t.TempDir()/chat.db) so
	// this method never touches the production tree from a test.
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		return nil, nil, fmt.Errorf("ensure chat dir: %w", err)
	}

	// _pragma_key takes the hex-encoded SQLCipher raw key (no quotes
	// around the hex string in the URI form — driver wraps in x'…').
	q := url.Values{}
	q.Set("_pragma_key", "x'"+hex.EncodeToString(dbKey)+"'")
	q.Set("_pragma_cipher_page_size", "4096")
	q.Set("_journal_mode", "WAL")
	q.Set("_synchronous", "NORMAL")
	q.Set("_foreign_keys", "1")
	dsn := "file:" + dbPath + "?" + q.Encode()

	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, nil, fmt.Errorf("sql.Open: %w", err)
	}
	// One open conn per DB — SQLite isn't built for high concurrency and
	// extra conns would each need their own _pragma_key dance.
	db.SetMaxOpenConns(1)

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("ping (wrong key?): %w", err)
	}
	if err := applyMigrations(ctx, db); err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("migrations: %w", err)
	}
	return db, attachKey, nil
}

func loadOrCreateMasterKey(ctx context.Context, accountUUID string, keyStore port.ChatDBKeyStore) ([]byte, error) {
	master, err := keyStore.Read(ctx, accountUUID)
	if err == nil {
		if len(master) != MasterKeySize {
			return nil, fmt.Errorf("master key size = %d, want %d", len(master), MasterKeySize)
		}
		return master, nil
	}
	if !errors.Is(err, port.ErrKeyNotFound) {
		return nil, fmt.Errorf("key store read: %w", err)
	}
	// First open for this account → mint a fresh key.
	master = make([]byte, MasterKeySize)
	if _, err := rand.Read(master); err != nil {
		return nil, fmt.Errorf("generate master key: %w", err)
	}
	if err := keyStore.Write(ctx, accountUUID, master); err != nil {
		return nil, fmt.Errorf("key store write: %w", err)
	}
	return master, nil
}
