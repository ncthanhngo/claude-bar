package mcp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// sharedSecretReader is the slice of *keychain.MCPSecretStore this file needs.
// Declared here (rather than importing keychain) to keep the mcp package free
// of an adapter import and any cycle risk — the CLI passes a concrete store.
type sharedSecretReader interface {
	GetShared(ctx context.Context, service domain.MCPService) (string, error)
}

// ListPipelines fetches recent pipelines for a project on a configured GitLab
// instance, reusing the same instance registry and Keychain PAT slot as the
// MCP `cb_gitlab_list_pipelines` tool. It returns the raw GitLab JSON array so
// callers (the `csw gitlab pipelines` verb that the menu-bar poller drives) can
// stream it straight to stdout.
//
// Kept free-standing (no *Gateway) so the CLI needn't build the whole MCP
// gateway just to poll pipeline status. The token read path mirrors
// gitlabResolve: shared slot `gitlab:<instanceID>`.
func ListPipelines(ctx context.Context, instances *GitLabInstanceStore, secrets sharedSecretReader, instanceRef, project, ref, status string, perPage int) ([]byte, error) {
	if instances == nil {
		return nil, errors.New("gitlab not configured")
	}
	if strings.TrimSpace(project) == "" {
		return nil, errors.New("project is required")
	}
	inst, err := instances.Resolve(ctx, instanceRef)
	if err != nil {
		return nil, err
	}
	token, err := secrets.GetShared(ctx, gitlabService(inst.ID))
	if err != nil {
		return nil, fmt.Errorf("gitlab secret read: %w", err)
	}
	if token == "" {
		return nil, fmt.Errorf("gitlab instance %q has no PAT stored", inst.Name)
	}

	q := url.Values{}
	if v := strings.TrimSpace(ref); v != "" {
		q.Set("ref", v)
	}
	if v := strings.TrimSpace(status); v != "" {
		q.Set("status", v)
	}
	if perPage < 1 {
		perPage = 20
	}
	if perPage > 100 {
		perPage = 100
	}
	q.Set("per_page", strconv.Itoa(perPage))

	u := strings.TrimRight(inst.BaseURL, "/") + "/projects/" + encodeProject(project) + "/pipelines"
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ClaudeBar-csw")

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gitlab http: %w", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("gitlab http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(b))))
	}
	return b, nil
}
