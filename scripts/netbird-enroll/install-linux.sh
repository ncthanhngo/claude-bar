#!/usr/bin/env bash
# NetBird dev enrollment — Linux.
#
# Usage:  SETUP_KEY=<key> ./install-linux.sh
#
# Installs the official NetBird client and connects with the setup key. The
# machine lands in the dev-pending group (isolated) until the admin approves it.
set -euo pipefail

KEY="${SETUP_KEY:-${1:-}}"
# Self-hosted management server. A plain `netbird up` defaults to NetBird Cloud
# and rejects the self-host key — point it here. Override with MGMT_URL=…
MGMT_URL="${MGMT_URL:-https://netbird.evselab.com}"
if [[ -z "$KEY" ]]; then
  echo "error: pass the setup key:  SETUP_KEY=<key> $0" >&2
  exit 1
fi

if ! command -v netbird >/dev/null 2>&1; then
  curl -fsSL https://pkgs.netbird.io/install.sh | sh
fi

sudo netbird service install 2>/dev/null || true
sudo netbird service start 2>/dev/null || true
sudo netbird up --setup-key "$KEY" --management-url "$MGMT_URL"
echo "Connected. Báo admin để được duyệt trong app."
