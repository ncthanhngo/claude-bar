# Documentation

Reference material for Claude Bar, grouped by audience. Start with the [project README](../README.md) for install and feature overview.

## User guides

- [Add account — safe flow](./add-account-flow.md) — how account add/switch works and how to avoid a broken switch (bilingual: English / Tiếng Việt)
- [Sync between two Macs over iCloud](../sync.md) — step-by-step guide to mirror Claude Bar onto a second Mac sharing your Apple ID (Tiếng Việt)

## Architecture & design

- [Architecture](./architecture.md) — clean / hexagonal layout, the SwiftUI ↔ Go backend bridge, and the account-swap transaction

## Security & privacy

- [SECURITY.md](../SECURITY.md) — data flows, trust boundaries, threat model, and how to report a vulnerability
- [Local MCP threat model](./local-mcp-threat-model.md) — trust boundaries for the shared connector tokens and the local stdio gateway
- [iCloud sync risks (tech note)](./tech-note-icloud-sync-risks.md) — what the passphrase-encrypted iCloud bundle does and does not protect

## Engineering journals

- [journals/](./journals/) — dated notes on notable changes (e.g. iCloud sync hardening)
