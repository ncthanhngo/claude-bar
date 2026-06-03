# NetBird dev enrollment — Windows 11 (PowerShell, run as Administrator).
#
# Usage:  .\install-windows.ps1 -SetupKey "<key>"
#
# Installs the official NetBird client and connects with the setup key. The
# machine lands in the dev-pending group (isolated) until the admin approves it.
param(
  [Parameter(Mandatory = $true)][string]$SetupKey,
  # Self-hosted management server. A plain `netbird up` defaults to NetBird
  # Cloud and rejects the self-host key — point it here.
  [string]$ManagementUrl = "https://netbird.evselab.com"
)
$ErrorActionPreference = "Stop"

if (-not (Get-Command netbird -ErrorAction SilentlyContinue)) {
  Write-Host "Installing NetBird via winget…"
  winget install --id NetBird.NetBird --accept-source-agreements --accept-package-agreements
}

netbird service install 2>$null
netbird service start   2>$null
netbird up --setup-key $SetupKey --management-url $ManagementUrl
Write-Host "Connected. Báo admin để được duyệt trong app."
