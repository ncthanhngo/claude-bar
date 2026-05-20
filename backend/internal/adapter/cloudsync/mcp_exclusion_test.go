package cloudsync

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// TestBundleAccountExcludesMCPConnectors guards the privacy boundary in
// docs/local-mcp-threat-model.md §5: local MCP connector metadata must
// never be serialised into the iCloud bundle. If someone adds an
// MCPConnectors field to BundleAccount this test will fail loudly.
func TestBundleAccountExcludesMCPConnectors(t *testing.T) {
	tp := reflect.TypeOf(BundleAccount{})
	for i := 0; i < tp.NumField(); i++ {
		f := tp.Field(i)
		name := strings.ToLower(f.Name)
		if strings.Contains(name, "mcp") || strings.Contains(name, "connector") {
			t.Fatalf("BundleAccount must NOT contain MCP/connector field, found %q", f.Name)
		}
	}
}

// TestBundleAccountJSONExcludesMCPKeys ensures the marshalled JSON never
// carries an mcpConnectors key even if a future refactor adds a field
// with a different Go name.
func TestBundleAccountJSONExcludesMCPKeys(t *testing.T) {
	b, err := json.Marshal(BundleAccount{Number: 1, Email: "a@b.c"})
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)
	for _, banned := range []string{"mcpConnectors", "mcp_connectors", "mcp:"} {
		if strings.Contains(out, banned) {
			t.Fatalf("BundleAccount JSON must not contain %q, got %s", banned, out)
		}
	}
}
