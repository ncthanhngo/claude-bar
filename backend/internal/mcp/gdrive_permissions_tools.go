package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func (g *Gateway) registerGDrivePermissionTools(srv *server.MCPServer) {
	g.addTool(srv, "cb_gdrive_share_file",
		"Grant access to a Google Drive file by email. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("file_id", mcpgo.Required(), mcpgo.Description("Drive file ID, including a spreadsheetId returned by cb_gsheets_create_spreadsheet.")),
			mcpgo.WithString("email", mcpgo.Required(), mcpgo.Description("User or group email address to share with.")),
			mcpgo.WithString("role", mcpgo.Description("reader|commenter|writer. Defaults to writer.")),
			mcpgo.WithBoolean("send_notification_email", mcpgo.Description("Ask Google to email the recipient. Default false.")),
		},
		g.gdriveShareFile,
	)
}

func (g *Gateway) gdriveShareFile(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	fileID, err := req.RequireString("file_id")
	if err != nil {
		return toolErrorf("file_id is required"), nil
	}
	email, err := req.RequireString("email")
	if err != nil {
		return toolErrorf("email is required"), nil
	}
	role := strings.ToLower(strings.TrimSpace(req.GetString("role", "writer")))
	if role == "" {
		role = "writer"
	}
	if role != "reader" && role != "commenter" && role != "writer" {
		return toolErrorf("role must be reader, commenter, or writer"), nil
	}
	notify := req.GetBool("send_notification_email", false)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gdrive_share_file",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("Share Drive file %s with %s as %s", fileID, email, role),
		Args: map[string]any{
			"file_id":                 fileID,
			"email":                   email,
			"role":                    role,
			"send_notification_email": notify,
		},
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			return g.gdriveShareFileAfterApproval(ctx, cc, fileID, email, role, notify)
		},
	})
}

func (g *Gateway) gdriveShareFileAfterApproval(ctx context.Context, cc *CallContext, fileID, email, role string, notify bool) (*mcpgo.CallToolResult, error) {
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	params := url.Values{}
	params.Set("sendNotificationEmail", strconv.FormatBool(notify))
	params.Set("fields", "id,type,role,emailAddress")
	body := map[string]any{
		"type":         "user",
		"role":         role,
		"emailAddress": email,
	}
	resp, err := g.gdriveDoJSON(ctx, access, http.MethodPost, "/files/"+url.PathEscape(fileID)+"/permissions", params, body)
	if err != nil {
		return toolErrorf("gdrive share: %v", err), nil
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(respBody)))), nil
	}
	return mcpgo.NewToolResultText(string(respBody)), nil
}

func (g *Gateway) gdriveDoJSON(ctx context.Context, accessToken, method, path string, params url.Values, body any) (*http.Response, error) {
	u := gdriveAPIBase + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)
	return g.HTTP.Do(req)
}
