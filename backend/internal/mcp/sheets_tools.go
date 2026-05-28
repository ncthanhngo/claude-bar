package mcp

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const sheetsAPIBase = "https://sheets.googleapis.com/v4/spreadsheets"

// registerGSheetsTools wires the three write-side Google Sheets tools the
// Daily / Chat agent needs to turn an ad-hoc data structure (a markdown
// table from a GitHub issue, a CSV scrape, etc.) into a real spreadsheet
// with addressable cells — not just an uploaded CSV blob.
//
// All three share the GDrive connector's OAuth grant (same Google account,
// same token refresh path). Adding the `spreadsheets` scope to that grant
// is what makes these tools usable; users on a pre-v11.2 token must
// re-Connect the Google connector once to upgrade the scope set.
//
// The gateway only registers Sheets tools inside the GDrive `enabled`
// branch so the same shared/per-account Enabled gating that hides the
// readonly Drive/Calendar/Gmail tools also hides these.
func (g *Gateway) registerGSheetsTools(srv *server.MCPServer) {
	g.addTool(srv, "cb_gsheets_create_spreadsheet",
		"Create a brand-new Google Sheet under the active Claude Bar account's Google Drive. Returns the spreadsheetId + URL so follow-up tools can write cells into it. Title is what shows up in My Drive.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("title", mcpgo.Required(), mcpgo.Description("Spreadsheet title shown in Google Drive.")),
			mcpgo.WithString("first_sheet_title", mcpgo.Description("Optional name for the initial sheet/tab. Defaults to 'Sheet1'.")),
		},
		g.gsheetsCreate,
	)

	g.addTool(srv, "cb_gsheets_update_values",
		"Overwrite a rectangular range of cells in an existing Google Sheet. Use A1 notation for the range (e.g. 'Sheet1!A1:C10'). Values are interpreted as if a user typed them — formulas like '=SUM(A1:A5)' work, numbers parse as numbers, dates parse as dates. To append rows instead of overwriting, use cb_gsheets_append_values.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("spreadsheet_id", mcpgo.Required(), mcpgo.Description("Spreadsheet ID returned by create_spreadsheet, or extracted from the URL /d/SPREADSHEET_ID/edit.")),
			mcpgo.WithString("range", mcpgo.Required(), mcpgo.Description("A1 notation range, e.g. 'Sheet1!A1:C10' or 'Sheet1!A1' for a single cell. Range determines where writes start; oversized payloads spill into adjacent cells.")),
			mcpgo.WithArray("values", mcpgo.Required(), mcpgo.Description("2D array of row arrays — each inner array is one row of cell values. Strings, numbers, booleans, or null. Example: [[\"Name\", \"Score\"], [\"Alice\", 42]].")),
		},
		g.gsheetsUpdate,
	)

	g.addTool(srv, "cb_gsheets_append_values",
		"Append rows to the end of an existing Google Sheet table. Google scans the table at `range` to find the first empty row below it and inserts there. Use this when you want to grow a sheet without overwriting; use cb_gsheets_update_values when you want exact cell placement.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("spreadsheet_id", mcpgo.Required(), mcpgo.Description("Spreadsheet ID.")),
			mcpgo.WithString("range", mcpgo.Required(), mcpgo.Description("A1 notation of the table to append to, e.g. 'Sheet1!A1'. Google extends the table from this anchor.")),
			mcpgo.WithArray("values", mcpgo.Required(), mcpgo.Description("2D array of row arrays — each inner array is one new row.")),
		},
		g.gsheetsAppend,
	)

	g.addTool(srv, "cb_gsheets_create_from_csv",
		"Create a brand-new Google Sheet and populate it from a CSV payload in one call. Saves the agent from chaining create_spreadsheet + update_values. The CSV is parsed with Go's encoding/csv (RFC 4180 — quoted fields, embedded commas/newlines OK). Header row is treated identically to data rows; the agent can post-process via update_values if it wants to bold it. Returns the new spreadsheetId + URL.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("title", mcpgo.Required(), mcpgo.Description("Spreadsheet title shown in Google Drive.")),
			mcpgo.WithString("csv", mcpgo.Required(), mcpgo.Description("Raw CSV text. Each line is one row; commas separate cells; fields containing commas/newlines/quotes must be quoted per RFC 4180.")),
			mcpgo.WithString("first_sheet_title", mcpgo.Description("Optional name for the initial sheet/tab. Defaults to 'Sheet1'.")),
		},
		g.gsheetsCreateFromCSV,
	)
}

func (g *Gateway) gsheetsCreate(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	title, err := req.RequireString("title")
	if err != nil {
		return toolErrorf("title is required"), nil
	}
	sheetTitle := strings.TrimSpace(req.GetString("first_sheet_title", ""))

	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gsheets auth: %v", err), nil
	}

	payload := map[string]any{
		"properties": map[string]any{"title": title},
	}
	if sheetTitle != "" {
		payload["sheets"] = []map[string]any{
			{"properties": map[string]any{"title": sheetTitle}},
		}
	}

	resp, err := g.sheetsDo(ctx, access, http.MethodPost, "", nil, payload)
	if err != nil {
		return toolErrorf("gsheets create: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gsheets http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	// Slim down the response — the full payload includes empty grid data
	// the agent never needs. Surface the identifiers + URL + sheet titles.
	var raw struct {
		SpreadsheetID  string `json:"spreadsheetId"`
		SpreadsheetURL string `json:"spreadsheetUrl"`
		Properties     struct {
			Title string `json:"title"`
		} `json:"properties"`
		Sheets []struct {
			Properties struct {
				SheetID int    `json:"sheetId"`
				Title   string `json:"title"`
				Index   int    `json:"index"`
			} `json:"properties"`
		} `json:"sheets"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return toolErrorf("gsheets decode: %v", err), nil
	}
	sheetNames := make([]string, 0, len(raw.Sheets))
	for _, s := range raw.Sheets {
		sheetNames = append(sheetNames, s.Properties.Title)
	}
	return jsonResult(map[string]any{
		"spreadsheetId":  raw.SpreadsheetID,
		"spreadsheetUrl": raw.SpreadsheetURL,
		"title":          raw.Properties.Title,
		"sheets":         sheetNames,
	})
}

// gsheetsCreateFromCSV is a thin convenience over create + update_values:
// the agent supplies a single CSV string and we do the two API round-trips
// internally. This shows up in workflows like "post this 15-row checklist
// as a sheet and share it with X" where chaining tools at the agent layer
// burns context for no gain.
func (g *Gateway) gsheetsCreateFromCSV(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	title, err := req.RequireString("title")
	if err != nil {
		return toolErrorf("title is required"), nil
	}
	csvText, err := req.RequireString("csv")
	if err != nil {
		return toolErrorf("csv is required"), nil
	}
	sheetTitle := strings.TrimSpace(req.GetString("first_sheet_title", ""))

	values, err := parseCSVToValues(csvText)
	if err != nil {
		return toolErrorf("csv parse: %v", err), nil
	}
	if len(values) == 0 {
		return toolErrorf("csv is empty"), nil
	}

	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gsheets auth: %v", err), nil
	}

	// Step 1: create the spreadsheet.
	createPayload := map[string]any{
		"properties": map[string]any{"title": title},
	}
	if sheetTitle != "" {
		createPayload["sheets"] = []map[string]any{
			{"properties": map[string]any{"title": sheetTitle}},
		}
	}
	createResp, err := g.sheetsDo(ctx, access, http.MethodPost, "", nil, createPayload)
	if err != nil {
		return toolErrorf("gsheets create: %v", err), nil
	}
	createBody, _ := io.ReadAll(createResp.Body)
	createResp.Body.Close()
	if createResp.StatusCode/100 != 2 {
		return toolErrorf("gsheets http %d: %s", createResp.StatusCode, Redact(strings.TrimSpace(string(createBody)))), nil
	}
	var created struct {
		SpreadsheetID  string `json:"spreadsheetId"`
		SpreadsheetURL string `json:"spreadsheetUrl"`
		Sheets         []struct {
			Properties struct {
				Title string `json:"title"`
			} `json:"properties"`
		} `json:"sheets"`
	}
	if err := json.Unmarshal(createBody, &created); err != nil {
		return toolErrorf("gsheets decode: %v", err), nil
	}
	firstTab := "Sheet1"
	if len(created.Sheets) > 0 && created.Sheets[0].Properties.Title != "" {
		firstTab = created.Sheets[0].Properties.Title
	}

	updateRange := firstTab + "!A1"
	params := url.Values{}
	params.Set("valueInputOption", "USER_ENTERED")
	updatePayload := map[string]any{
		"range":          updateRange,
		"majorDimension": "ROWS",
		"values":         values,
	}
	updateResp, err := g.sheetsDo(ctx, access, http.MethodPut, "/"+created.SpreadsheetID+"/values/"+url.PathEscape(updateRange), params, updatePayload)
	if err != nil {
		// Sheet was created but population failed. Surface enough for the
		// agent to follow up — the spreadsheet exists and is shareable
		// even if empty.
		return toolErrorf("gsheets populate (sheet created at %s): %v", created.SpreadsheetURL, err), nil
	}
	updateBody, _ := io.ReadAll(updateResp.Body)
	updateResp.Body.Close()
	if updateResp.StatusCode/100 != 2 {
		return toolErrorf("gsheets populate http %d (sheet created at %s): %s", updateResp.StatusCode, created.SpreadsheetURL, Redact(strings.TrimSpace(string(updateBody)))), nil
	}

	return jsonResult(map[string]any{
		"spreadsheetId":  created.SpreadsheetID,
		"spreadsheetUrl": created.SpreadsheetURL,
		"title":          title,
		"sheet":          firstTab,
		"rowCount":       len(values),
	})
}

func (g *Gateway) gsheetsUpdate(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.gsheetsWrite(ctx, req, sheetsWriteUpdate)
}

func (g *Gateway) gsheetsAppend(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.gsheetsWrite(ctx, req, sheetsWriteAppend)
}

type sheetsWriteMode int

const (
	sheetsWriteUpdate sheetsWriteMode = iota
	sheetsWriteAppend
)

// gsheetsWrite is the shared body for update vs append — only the HTTP
// shape (PUT /values/{range} vs POST /values/{range}:append + the extra
// `insertDataOption` query) differs.
func (g *Gateway) gsheetsWrite(ctx context.Context, req mcpgo.CallToolRequest, mode sheetsWriteMode) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	spreadsheetID, err := req.RequireString("spreadsheet_id")
	if err != nil {
		return toolErrorf("spreadsheet_id is required"), nil
	}
	rangeA1, err := req.RequireString("range")
	if err != nil {
		return toolErrorf("range is required"), nil
	}
	rawValues := req.GetArguments()["values"]
	if rawValues == nil {
		return toolErrorf("values is required"), nil
	}
	values, ok := normalizeSheetValues(rawValues)
	if !ok {
		return toolErrorf("values must be a 2D array of cells (array of row arrays)"), nil
	}

	access, err := g.gdriveRefresh(ctx, cc)
	if err != nil {
		return toolErrorf("gsheets auth: %v", err), nil
	}

	body := map[string]any{
		"range":          rangeA1,
		"majorDimension": "ROWS",
		"values":         values,
	}

	params := url.Values{}
	// USER_ENTERED parses formulas / dates / numbers the way the user would
	// expect when typing into a cell. RAW would store everything as the
	// literal string — useful for forensic snapshots but surprising as a
	// default for an LLM-driven flow.
	params.Set("valueInputOption", "USER_ENTERED")

	var (
		method string
		path   string
	)
	switch mode {
	case sheetsWriteUpdate:
		method = http.MethodPut
		path = "/" + spreadsheetID + "/values/" + url.PathEscape(rangeA1)
	case sheetsWriteAppend:
		method = http.MethodPost
		path = "/" + spreadsheetID + "/values/" + url.PathEscape(rangeA1) + ":append"
		// INSERT_ROWS shifts existing rows down to make room for the new
		// payload. OVERWRITE (the API default) would clobber whatever
		// sits below the table — almost never what an agent wants when
		// "appending" data.
		params.Set("insertDataOption", "INSERT_ROWS")
	}

	resp, err := g.sheetsDo(ctx, access, method, path, params, body)
	if err != nil {
		return toolErrorf("gsheets write: %v", err), nil
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gsheets http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(respBody)))), nil
	}
	return mcpgo.NewToolResultText(string(respBody)), nil
}

// sheetsDo wraps the JSON-body HTTP call so individual tool handlers do
// not each re-build the same auth + content-type plumbing. body is JSON
// marshalled when non-nil; nil body sends an empty payload (used for
// read paths — currently none, but the helper is shaped to allow them).
func (g *Gateway) sheetsDo(ctx context.Context, accessToken, method, path string, params url.Values, body any) (*http.Response, error) {
	u := sheetsAPIBase + path
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

// parseCSVToValues parses a CSV payload (RFC 4180) into the 2D `[][]any`
// shape Sheets expects. FieldsPerRecord=-1 disables csv.Reader's
// "all rows must have the same column count" check — agents posting
// ad-hoc CSVs frequently omit trailing commas, and a parse failure
// there is much less useful than letting Sheets render the ragged data.
func parseCSVToValues(csvText string) ([][]any, error) {
	reader := csv.NewReader(strings.NewReader(csvText))
	reader.FieldsPerRecord = -1
	rows, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}
	out := make([][]any, len(rows))
	for i, r := range rows {
		row := make([]any, len(r))
		for j, cell := range r {
			row[j] = cell
		}
		out[i] = row
	}
	return out, nil
}

// normalizeSheetValues coerces a JSON-decoded `values` argument into the
// 2D `[][]any` shape Sheets expects. The MCP arguments map decodes JSON
// arrays as []any, so each row is itself an []any of cell scalars.
// Returns (values, true) on a valid 2D shape, (nil, false) if the input
// is not an array-of-arrays.
func normalizeSheetValues(raw any) ([][]any, bool) {
	rows, ok := raw.([]any)
	if !ok {
		return nil, false
	}
	out := make([][]any, 0, len(rows))
	for _, r := range rows {
		row, ok := r.([]any)
		if !ok {
			return nil, false
		}
		out = append(out, row)
	}
	return out, true
}
