package netbird

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// DefaultBaseURL is used when the saved config has no explicit base URL.
const DefaultBaseURL = "https://netbird.evselab.com/api"

// sharedAccount is the account number under which the NetBird credential lives.
// NetBird is a single self-hosted instance, not per-Claude-Bar-account, so it
// is stored under the shared slot (0).
const sharedAccount = 0

// ErrNotConfigured means no NetBird token has been saved yet.
var ErrNotConfigured = errors.New("netbird not configured — set a token in Settings")

// Config is the non-tool credential payload stored in the Keychain secret slot.
type Config struct {
	BaseURL string `json:"baseURL"`
	Token   string `json:"token"`
}

// LoadConfig reads the NetBird credential from the secret store and applies the
// default base URL when none is saved. Returns ErrNotConfigured when no token
// has been written yet.
func LoadConfig(ctx context.Context, secrets port.MCPSecretStore) (Config, error) {
	payload, err := secrets.Read(ctx, sharedAccount, domain.MCPServiceNetbird)
	if err != nil {
		return Config{}, err
	}
	if strings.TrimSpace(payload) == "" {
		return Config{}, ErrNotConfigured
	}
	var cfg Config
	if err := json.Unmarshal([]byte(payload), &cfg); err != nil {
		return Config{}, err
	}
	cfg.BaseURL = normalizeBaseURL(cfg.BaseURL)
	if cfg.Token == "" {
		return Config{}, ErrNotConfigured
	}
	return cfg, nil
}

// SaveConfig writes the credential payload to the secret store. An empty
// base URL falls back to the default; the token must be non-empty.
func SaveConfig(ctx context.Context, secrets port.MCPSecretStore, cfg Config) error {
	cfg.BaseURL = normalizeBaseURL(cfg.BaseURL)
	if strings.TrimSpace(cfg.Token) == "" {
		return errors.New("token is required")
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return secrets.Write(ctx, sharedAccount, domain.MCPServiceNetbird, string(b))
}

// normalizeBaseURL turns whatever the user typed into a full NetBird API root.
// The user only needs the host (e.g. "netbird.evselab.com"); the scheme and the
// /api path are added automatically:
//   - prepend https:// when no scheme is present
//   - append /api when missing (without it the request hits the web UI and
//     returns HTML, which fails to decode as JSON)
func normalizeBaseURL(u string) string {
	u = strings.TrimSpace(u)
	if u == "" {
		return DefaultBaseURL
	}
	if !strings.Contains(u, "://") {
		u = "https://" + u
	}
	u = strings.TrimRight(u, "/")
	if !strings.HasSuffix(u, "/api") {
		u += "/api"
	}
	return u
}
