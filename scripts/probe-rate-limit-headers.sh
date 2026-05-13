#!/usr/bin/env bash
# One-shot probe: read OAuth token from macOS Keychain, send a 1-token
# request to api.anthropic.com, print rate-limit response headers.
#
# macOS will prompt "Claude Widget" or "security" to access keychain — click "Allow".
# Costs ~2 tokens of your Claude quota.
set -euo pipefail

echo "▶ Trying common keychain service names for Claude Code credentials…"

SERVICES=(
    "Claude Code-credentials"
    "claude-code-credentials"
    "Claude Code"
    "anthropic-claude-code"
)

TOKEN_JSON=""
for svc in "${SERVICES[@]}"; do
    if out=$(security find-generic-password -s "$svc" -w 2>/dev/null); then
        echo "✓ Found credentials under service: \"$svc\""
        TOKEN_JSON="$out"
        break
    fi
done

if [[ -z "$TOKEN_JSON" ]]; then
    echo "✗ Could not find Claude Code credentials in keychain."
    echo "  Try: security dump-keychain | grep -i claude"
    echo "  Then tell me the service name."
    exit 1
fi

# Token is either a raw JWT or a JSON blob.
if echo "$TOKEN_JSON" | python3 -c "import sys,json;json.loads(sys.stdin.read())" 2>/dev/null; then
    ACCESS_TOKEN=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('claudeAiOauth',{}).get('accessToken') or d.get('accessToken') or '')")
else
    ACCESS_TOKEN="$TOKEN_JSON"
fi

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "None" ]]; then
    echo "✗ Token shape unrecognized. First 30 chars:"
    echo "  ${TOKEN_JSON:0:30}…"
    exit 1
fi

echo "▶ Token length: ${#ACCESS_TOKEN} chars"
echo "▶ Sending probe request (max_tokens=1)…"
echo

HEADERS_FILE=$(mktemp)
BODY_FILE=$(mktemp)
trap 'rm -f "$HEADERS_FILE" "$BODY_FILE"' EXIT

curl -sS -D "$HEADERS_FILE" -o "$BODY_FILE" \
    -X POST https://api.anthropic.com/v1/messages \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "content-type: application/json" \
    -H "user-agent: claude-cli/2.1.132 (external, cli)" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' || true

echo "=== Response status ==="
head -1 "$HEADERS_FILE"
echo
echo "=== anthropic-* headers ==="
grep -iE '^(anthropic-|x-ratelimit|retry-after)' "$HEADERS_FILE" || echo "(none found)"
echo
echo "=== Body (first 400 chars) ==="
head -c 400 "$BODY_FILE"; echo
