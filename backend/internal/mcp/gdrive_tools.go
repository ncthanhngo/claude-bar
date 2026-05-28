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

var gdriveAPIBase = "https://www.googleapis.com/drive/v3"

func (g *Gateway) registerGDriveTools(srv *server.MCPServer) {
	g.addTool(srv, "cb_gdrive_search_files",
		"Search Google Drive files visible to the active Claude Bar account's Drive token. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required(), mcpgo.Description("Drive search query, e.g. \"name contains 'report'\" or \"mimeType='application/vnd.google-apps.document'\".")),
			mcpgo.WithNumber("page_size", mcpgo.Description("Max results (1-100). Default 25.")),
		},
		g.gdriveSearchFiles,
	)

	g.addTool(srv, "cb_gdrive_get_file_metadata",
		"Get metadata for a Google Drive file by ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("file_id", mcpgo.Required(), mcpgo.Description("Google Drive file ID.")),
		},
		g.gdriveGetFileMetadata,
	)

	g.addTool(srv, "cb_gdrive_get_doc_text",
		"Export a Google Doc as plain text. Only works for Google Docs (mimeType application/vnd.google-apps.document).",
		[]mcpgo.ToolOption{
			mcpgo.WithString("file_id", mcpgo.Required(), mcpgo.Description("Google Doc file ID.")),
		},
		g.gdriveGetDocText,
	)

	g.addTool(srv, "cb_gdrive_list_folder",
		"List the children of a Google Drive folder by folder ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("folder_id", mcpgo.Required(), mcpgo.Description("Drive folder ID. Use 'root' for My Drive root.")),
			mcpgo.WithNumber("page_size", mcpgo.Description("Max children (1-100). Default 50.")),
			mcpgo.WithBoolean("include_trashed", mcpgo.Description("Include trashed items. Default false.")),
		},
		g.gdriveListFolder,
	)

	g.addTool(srv, "cb_gdrive_download_file",
		"Download a Google Drive file's bytes as text (for binary files like PDFs, the bytes are returned as-is — the agent should size-check first via get_file_metadata). Read-only. For Google Docs use get_doc_text instead.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("file_id", mcpgo.Required(), mcpgo.Description("Drive file ID (non-Google-Doc).")),
		},
		g.gdriveDownloadFile,
	)

	g.registerGDrivePermissionTools(srv)
}

// gdriveDo issues a JSON request to the Drive v3 REST API. body is JSON-
// marshalled when non-nil; nil body sends an empty request (the existing
// read tools all use this path).
func (g *Gateway) gdriveDo(ctx context.Context, accessToken, method, path string, params url.Values, body any) (*http.Response, error) {
	u := gdriveAPIBase + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	var reqBody io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("marshal: %w", err)
		}
		reqBody = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, reqBody)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("User-Agent", g.UserAgent)
	return g.HTTP.Do(req)
}

func (g *Gateway) gdriveSearchFiles(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	query, err := req.RequireString("query")
	if err != nil {
		return toolErrorf("query is required"), nil
	}
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	params := url.Values{}
	params.Set("q", query)
	params.Set("pageSize", strconv.Itoa(clampInt(req.GetInt("page_size", 25), 1, 100)))
	params.Set("fields", "files(id,name,mimeType,modifiedTime,owners(emailAddress),webViewLink)")

	resp, err := g.gdriveDo(ctx, access, http.MethodGet, "/files", params, nil)
	if err != nil {
		return toolErrorf("gdrive search: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var out struct {
		Files []map[string]any `json:"files"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("gdrive decode: %v", err), nil
	}
	return jsonResult(out.Files)
}

func (g *Gateway) gdriveGetFileMetadata(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	fileID, err := req.RequireString("file_id")
	if err != nil {
		return toolErrorf("file_id is required"), nil
	}
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	params := url.Values{}
	params.Set("fields", "id,name,mimeType,modifiedTime,size,owners(emailAddress),webViewLink,parents")
	resp, err := g.gdriveDo(ctx, access, http.MethodGet, "/files/"+fileID, params, nil)
	if err != nil {
		return toolErrorf("gdrive metadata: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gdriveListFolder(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	folderID, err := req.RequireString("folder_id")
	if err != nil {
		return toolErrorf("folder_id is required"), nil
	}
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	q := "'" + strings.ReplaceAll(folderID, "'", "\\'") + "' in parents"
	if !req.GetBool("include_trashed", false) {
		q += " and trashed = false"
	}
	params := url.Values{}
	params.Set("q", q)
	params.Set("pageSize", strconv.Itoa(clampInt(req.GetInt("page_size", 50), 1, 100)))
	params.Set("fields", "files(id,name,mimeType,modifiedTime,size,webViewLink)")

	resp, err := g.gdriveDo(ctx, access, http.MethodGet, "/files", params, nil)
	if err != nil {
		return toolErrorf("gdrive list folder: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var out struct {
		Files []map[string]any `json:"files"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("gdrive decode: %v", err), nil
	}
	return jsonResult(out.Files)
}

func (g *Gateway) gdriveDownloadFile(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	fileID, err := req.RequireString("file_id")
	if err != nil {
		return toolErrorf("file_id is required"), nil
	}
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	params := url.Values{}
	params.Set("alt", "media")
	resp, err := g.gdriveDo(ctx, access, http.MethodGet, "/files/"+fileID, params, nil)
	if err != nil {
		return toolErrorf("gdrive download: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gdriveGetDocText(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	fileID, err := req.RequireString("file_id")
	if err != nil {
		return toolErrorf("file_id is required"), nil
	}
	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gdrive auth: %v", err), nil
	}
	params := url.Values{}
	params.Set("mimeType", "text/plain")
	resp, err := g.gdriveDo(ctx, access, http.MethodGet, "/files/"+fileID+"/export", params, nil)
	if err != nil {
		return toolErrorf("gdrive export: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gdrive http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

