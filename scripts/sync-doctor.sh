#!/bin/bash
# sync-doctor.sh — check ClaudeBar iCloud sync health on this Mac.
#
# Run on EACH Mac signed into the same Apple ID, then compare the two outputs.
# Designed for copy-paste comparison: account identity hashes (no emails),
# lastSeq, iCloud propagation state, auto-sync timestamps.
#
# Usage:
#   bash scripts/sync-doctor.sh            # human-readable
#   bash scripts/sync-doctor.sh --json     # one-line JSON for grep/diff
#   bash scripts/sync-doctor.sh --short    # just the comparison fields
#
# Exit code: 0 ok, 1 any check failed (use for ci/cron alerting).

set -u

JSON=0
SHORT=0
for arg in "$@"; do
    case "$arg" in
        --json)  JSON=1 ;;
        --short) SHORT=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# ---- locate csw binary ----
CSW=""
for candidate in \
    "/Applications/ClaudeBar.app/Contents/Resources/csw" \
    "$HOME/dev/02-claude-bar/backend/bin/csw" \
    "$(command -v csw 2>/dev/null)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        CSW="$candidate"
        break
    fi
done
if [ -z "$CSW" ]; then
    echo "ERR: csw binary not found in known locations" >&2
    exit 1
fi

BUNDLE_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBar"
BUNDLE_PATH="$BUNDLE_DIR/cloud-bundle.enc"
STATE_PATH="$HOME/Library/Application Support/claude-swap-widget/cloud-sync-state.json"
APP_PLIST="/Applications/ClaudeBar.app/Contents/Info.plist"
HOSTNAME_S="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

# ---- gather data ----

app_version=""
[ -f "$APP_PLIST" ] && app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null)"

bundle_exists=0
bundle_size=0
bundle_mtime_unix=0
bundle_mtime_human=""
icloud_state="?"
backup_count=0
backup_oldest=""
backup_newest=""

if [ -f "$BUNDLE_PATH" ]; then
    bundle_exists=1
    bundle_size=$(stat -f "%z" "$BUNDLE_PATH")
    bundle_mtime_unix=$(stat -f "%m" "$BUNDLE_PATH")
    bundle_mtime_human=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S %z" "$BUNDLE_PATH")
    # iCloud sync state via xattr: a file fully synced has com.apple.metadata:com_apple_backup_excludeItem
    # but more reliable: check brctl monitor output. Use a quick proxy: if a sibling .icloud placeholder
    # exists, the file is downloaded-only-as-stub. If not, the byte content is local + uploaded.
    if ls "$BUNDLE_DIR/.cloud-bundle.enc.icloud" >/dev/null 2>&1; then
        icloud_state="stub-not-downloaded"
    else
        # cross-check with brctl: parses one entry from monitor output. Short
        # timeout because brctl runs forever otherwise.
        bc_out=$(timeout 2 brctl monitor com.apple.CloudDocs 2>&1 | grep "ClaudeBar/cloud-bundle.enc" | head -1 || true)
        if echo "$bc_out" | grep -qi "uploading"; then
            icloud_state="uploading"
        elif echo "$bc_out" | grep -qi "not downloaded"; then
            icloud_state="not-downloaded"
        elif [ -n "$bc_out" ]; then
            icloud_state="in-sync"
        else
            # brctl didn't return anything — file likely fully local + uploaded
            icloud_state="in-sync"
        fi
    fi
fi

# Backup ring state
for f in "$BUNDLE_PATH".1 "$BUNDLE_PATH".2 "$BUNDLE_PATH".3 "$BUNDLE_PATH".4 "$BUNDLE_PATH".5; do
    [ -f "$f" ] && backup_count=$((backup_count + 1))
done
if [ "$backup_count" -gt 0 ]; then
    backup_newest=$(stat -f "%Sm" -t "%H:%M:%S" "$BUNDLE_PATH".1 2>/dev/null || echo "?")
    backup_oldest=$(stat -f "%Sm" -t "%H:%M:%S" "$BUNDLE_PATH"."$backup_count" 2>/dev/null || echo "?")
fi

# Local sync state
local_seq=0
local_hash=""
if [ -f "$STATE_PATH" ]; then
    local_seq=$(python3 -c "import json; print(json.load(open('$STATE_PATH')).get('lastSeq', 0))" 2>/dev/null || echo 0)
    local_hash=$(python3 -c "import json; h=json.load(open('$STATE_PATH')).get('lastBundleHash',''); print(h[:12])" 2>/dev/null || echo "")
fi

# Auto-sync timestamps from UserDefaults
last_at=$(defaults read dev.ncthanhngo.claude-bar lastAutoSyncAt 2>/dev/null || echo 0)
last_ok=$(defaults read dev.ncthanhngo.claude-bar lastAutoSyncSuccessAt 2>/dev/null || echo 0)
last_err=$(defaults read dev.ncthanhngo.claude-bar lastAutoSyncError 2>/dev/null || echo "")
now_unix=$(date +%s)
age_ok_min=$(python3 -c "print(int(($now_unix - $last_ok) / 60))" 2>/dev/null || echo 0)
age_at_min=$(python3 -c "print(int(($now_unix - $last_at) / 60))" 2>/dev/null || echo 0)

# Account identity hashes — pull from cloud preview (decrypts via passphrase
# in Keychain). Each identity is "email|orgUUID"; we hash so the doctor
# output can be pasted publicly for comparison without leaking emails.
PASS=$(security find-generic-password -s "claude-bar-cloudsync-passphrase" -a passphrase -w 2>/dev/null || true)
identities_block=""
account_total=0
account_status=""
if [ -n "$PASS" ] && [ "$bundle_exists" -eq 1 ]; then
    rows=$(echo "$PASS" | "$CSW" cloud preview 0 --json 2>/dev/null || true)
    if [ -n "$rows" ]; then
        identities_block=$(echo "$rows" | python3 -c "
import json, sys, hashlib
rows = json.load(sys.stdin)
for r in rows:
    h = hashlib.sha256(r['identity'].encode()).hexdigest()[:12]
    print(f'    {h}  [{r[\"status\"]:10s}]')
" 2>/dev/null || true)
        account_total=$(echo "$rows" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        account_status="decryptable"
    else
        account_status="decrypt-failed (wrong passphrase in keychain?)"
    fi
else
    account_status="passphrase not in keychain"
fi

# ---- verdict ----
verdict_lines=()
overall=0
if [ "$bundle_exists" -ne 1 ]; then
    verdict_lines+=("✗ Bundle file missing — sync not enabled or iCloud Drive disabled")
    overall=1
else
    verdict_lines+=("✓ Bundle file present (${bundle_size} bytes)")
fi
if [ "$icloud_state" = "in-sync" ]; then
    verdict_lines+=("✓ iCloud Drive has the file (status: $icloud_state)")
else
    verdict_lines+=("⚠ iCloud Drive state: $icloud_state — peer may not see latest yet")
    [ "$icloud_state" = "not-downloaded" ] && overall=1
fi
if [ "$last_ok" != "0" ] && [ "$age_ok_min" -lt 720 ]; then
    verdict_lines+=("✓ Auto-sync succeeded within 12h ($age_ok_min min ago)")
elif [ "$last_ok" = "0" ]; then
    verdict_lines+=("⚠ Auto-sync has never succeeded")
    overall=1
else
    verdict_lines+=("✗ Auto-sync stale: last success $age_ok_min min ago")
    overall=1
fi
if [ -n "$last_err" ]; then
    verdict_lines+=("⚠ Last sync error: $last_err")
fi
if [ "$account_status" = "decryptable" ]; then
    verdict_lines+=("✓ Bundle decryptable with stored passphrase ($account_total account(s))")
else
    verdict_lines+=("✗ Bundle decrypt: $account_status")
    overall=1
fi

# ---- output ----

if [ "$JSON" = "1" ]; then
    # Pass values via env vars so Python can read them safely — interpolating
    # into a Python heredoc gets fragile fast (booleans, quotes, newlines in
    # error strings, etc.).
    SYNC_OK=$([ $overall -eq 0 ] && echo 1 || echo 0) \
    SYNC_HOST="$HOSTNAME_S" \
    SYNC_APP_VERSION="$app_version" \
    SYNC_BUNDLE_EXISTS="$bundle_exists" \
    SYNC_BUNDLE_SIZE="$bundle_size" \
    SYNC_BUNDLE_MTIME="$bundle_mtime_human" \
    SYNC_ICLOUD_STATE="$icloud_state" \
    SYNC_BACKUP_COUNT="$backup_count" \
    SYNC_LOCAL_SEQ="$local_seq" \
    SYNC_LOCAL_HASH="$local_hash" \
    SYNC_LAST_AT_MIN="$age_at_min" \
    SYNC_LAST_OK_MIN="$age_ok_min" \
    SYNC_LAST_ERR="$last_err" \
    SYNC_ACCT_TOTAL="$account_total" \
    SYNC_ACCT_STATUS="$account_status" \
    python3 -c '
import os, json
print(json.dumps({
    "host": os.environ["SYNC_HOST"],
    "app_version": os.environ["SYNC_APP_VERSION"],
    "bundle_exists": bool(int(os.environ["SYNC_BUNDLE_EXISTS"])),
    "bundle_size": int(os.environ["SYNC_BUNDLE_SIZE"]),
    "bundle_mtime": os.environ["SYNC_BUNDLE_MTIME"],
    "icloud_state": os.environ["SYNC_ICLOUD_STATE"],
    "backup_count": int(os.environ["SYNC_BACKUP_COUNT"]),
    "local_seq": int(os.environ["SYNC_LOCAL_SEQ"]),
    "local_hash_prefix": os.environ["SYNC_LOCAL_HASH"],
    "last_sync_attempt_min_ago": int(os.environ["SYNC_LAST_AT_MIN"]),
    "last_sync_success_min_ago": int(os.environ["SYNC_LAST_OK_MIN"]),
    "last_sync_error": os.environ["SYNC_LAST_ERR"],
    "account_total": int(os.environ["SYNC_ACCT_TOTAL"]),
    "account_status": os.environ["SYNC_ACCT_STATUS"],
    "overall_ok": bool(int(os.environ["SYNC_OK"])),
}))
'
    exit $overall
fi

if [ "$SHORT" = "1" ]; then
    echo "host=$HOSTNAME_S  seq=$local_seq  hash=$local_hash  icloud=$icloud_state  last_ok=${age_ok_min}m  accounts=$account_total"
    [ -n "$identities_block" ] && echo "$identities_block"
    exit $overall
fi

cat <<EOF
========================================
ClaudeBar sync doctor — $HOSTNAME_S
========================================
Time          : $(date '+%Y-%m-%d %H:%M:%S %z')
App version   : $app_version

[bundle file]
  path        : $BUNDLE_PATH
  exists      : $([ $bundle_exists -eq 1 ] && echo yes || echo no)
  size        : $bundle_size bytes
  mtime       : $bundle_mtime_human
  iCloud state: $icloud_state
  backup ring : $backup_count slot(s)$([ $backup_count -gt 0 ] && echo " (newest $backup_newest, oldest $backup_oldest)")

[local state]
  lastSeq     : $local_seq
  bundleHash  : ${local_hash}…

[auto-sync]
  lastAttempt : ${age_at_min} min ago
  lastSuccess : ${age_ok_min} min ago
  lastError   : $([ -z "$last_err" ] && echo "(none)" || echo "$last_err")

[accounts]
  total       : $account_total
  decrypt     : $account_status
$([ -n "$identities_block" ] && echo "  identities (sha256(email|orgUUID)[:12]):" && echo "$identities_block")

[verdict]
$(for line in "${verdict_lines[@]}"; do echo "  $line"; done)

To compare with the other Mac, run the same script there and diff:
  lastSeq should match (±2)
  identity hashes should match exactly
  both should show iCloud state "in-sync"
EOF

exit $overall
