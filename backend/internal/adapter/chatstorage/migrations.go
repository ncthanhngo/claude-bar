package chatstorage

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// applyMigrations brings the DB schema up to the latest version. Linear,
// no rollback. Each migration runs in its own transaction with the
// schema_version row inserted in the same txn so a crash mid-migration
// leaves the DB at the prior consistent version.
func applyMigrations(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx,
		`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)`,
	); err != nil {
		return fmt.Errorf("create schema_version: %w", err)
	}

	var current int
	if err := db.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(version), 0) FROM schema_version`,
	).Scan(&current); err != nil {
		return fmt.Errorf("read schema_version: %w", err)
	}

	entries, err := fs.Glob(migrationFS, "migrations/*.sql")
	if err != nil {
		return fmt.Errorf("list migrations: %w", err)
	}
	sort.Strings(entries)

	for _, entry := range entries {
		v, err := parseVersion(entry)
		if err != nil {
			return fmt.Errorf("parse %s: %w", entry, err)
		}
		if v <= current {
			continue
		}
		body, err := migrationFS.ReadFile(entry)
		if err != nil {
			return fmt.Errorf("read %s: %w", entry, err)
		}
		if err := runMigration(ctx, db, v, string(body)); err != nil {
			return err
		}
	}
	return nil
}

func runMigration(ctx context.Context, db *sql.DB, version int, body string) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin migration %d: %w", version, err)
	}
	if _, err := tx.ExecContext(ctx, body); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("apply migration %d: %w", version, err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO schema_version VALUES (?)`, version); err != nil {
		_ = tx.Rollback()
		return fmt.Errorf("record migration %d: %w", version, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migration %d: %w", version, err)
	}
	return nil
}

// parseVersion reads "0001_init.sql" → 1. Anything else returns an error so
// stray files in the migrations dir don't silently break the runner.
func parseVersion(filename string) (int, error) {
	base := filename
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	if i := strings.Index(base, "_"); i > 0 {
		return strconv.Atoi(base[:i])
	}
	return 0, fmt.Errorf("missing _ separator in %s", filename)
}
