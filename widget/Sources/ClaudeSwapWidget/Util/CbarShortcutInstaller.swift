import Foundation

/// Installs a `cbar` command-line shortcut on every launch so users can drive
/// the bundled `csw` CLI (e.g. `cbar switch work`, `cbar list`) without typing
/// the full app-bundle path.
///
/// Mechanism: a symlink in the first writable Homebrew / local bin dir pointing
/// at THIS app's bundled csw binary. Unlike the `claude-watch` alias, no
/// shell-rc file is edited — a symlink on PATH works in interactive shells,
/// scripts, and cron alike, and leaves `.zshrc` untouched.
///
/// Removal: the symlink points INTO the app bundle, so trashing the app makes
/// `cbar` dangle and stop working. Full cleanup is handled by `brew uninstall`
/// (cask zap) or the manual `rm` line documented in the README.
///
/// `cbar` is a FIXED, shared name across the Claude Bar and AI Bar tracks (the
/// two intentionally manage the same accounts and are not meant to run at
/// once), so it is not varied by `AppInfo.displayName`.
enum CbarShortcutInstaller {

    private static let linkCandidates = [
        "/opt/homebrew/bin/cbar",
        "/usr/local/bin/cbar"
    ]

    static func install() {
        guard let target = CswBinary.resolve() else { return }
        let fm = FileManager.default

        for linkPath in linkCandidates {
            let binDir = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
            guard fm.isWritableFile(atPath: binDir) else { continue }

            // Never clobber a real `cbar` binary another tool may have
            // installed — only replace a symlink we own (or a dangling one).
            // fileExists follows symlinks, so a dangling link reads as absent
            // and falls through to the refresh below.
            if fm.fileExists(atPath: linkPath),
               (try? fm.destinationOfSymbolicLink(atPath: linkPath)) == nil {
                continue
            }

            try? fm.removeItem(atPath: linkPath)
            do {
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target.path)
                break
            } catch {
                // Try the next candidate dir on failure.
                continue
            }
        }
    }
}
