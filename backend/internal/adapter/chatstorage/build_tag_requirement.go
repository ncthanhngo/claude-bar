//go:build !sqlite_fts5

// Compile-time guard: chatstorage requires SQLite FTS5 (messages_fts virtual
// table) to function. Build with `-tags sqlite_fts5` (or via `make backend`
// / `make test` which sets it automatically).
package chatstorage

// Importing this package without the `sqlite_fts5` build tag triggers the
// undefined-identifier error below. The error message is the actionable
// remediation — no need to chase a runtime "no such module: fts5" failure.
var _ = sqlite_fts5_build_tag_required
