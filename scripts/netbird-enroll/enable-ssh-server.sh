#!/usr/bin/env bash
# Enable NetBird SSH on a SERVER (Model B — no key management).
#
# Run once per server. The server joins the mesh AND turns on NetBird's built-in
# SSH server, so granted devs reach it with `netbird ssh <user>@<host>` — no
# authorized_keys to manage.
#
# Usage:  SETUP_KEY=<server-key> ./enable-ssh-server.sh
#
# Notes / security (Model B):
#   - NetBird SSH lets a peer that has a policy log in as ANY existing local
#     user. To restrict (e.g. forbid root via this path), do it server-side in
#     sshd_config / PAM or by not creating unwanted users.
#   - Put this server into a group named srv-<name> in the app so it shows up
#     as a matrix column.
set -euo pipefail

KEY="${SETUP_KEY:-${1:-}}"
# Self-hosted management server. A plain `netbird up` defaults to NetBird Cloud
# and rejects the self-host key — point it here. Override with MGMT_URL=…
MGMT_URL="${MGMT_URL:-https://netbird.evselab.com}"
if [[ -z "$KEY" ]]; then
  echo "error: pass the server setup key:  SETUP_KEY=<key> $0" >&2
  exit 1
fi

if ! command -v netbird >/dev/null 2>&1; then
  curl -fsSL https://pkgs.netbird.io/install.sh | sh
fi

sudo netbird service install 2>/dev/null || true
sudo netbird service start 2>/dev/null || true
sudo netbird up --setup-key "$KEY" --management-url "$MGMT_URL" --allow-server-ssh --enable-ssh
echo "Server connected with NetBird SSH enabled."
echo "Đặt máy này vào group srv-<tên> trong app để cấp quyền qua ma trận."
