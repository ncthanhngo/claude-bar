package oauth

import "testing"

func TestParseProfile(t *testing.T) {
	raw := `{"account":{"uuid":"u1","email":"one@example.com","full_name":"One"},
	         "organization":{"uuid":"org-1","name":"One's Organization","organization_type":"claude_pro"}}`
	id, err := parseProfile([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if id.Email != "one@example.com" || id.OrgUUID != "org-1" {
		t.Fatalf("identity = %+v", id)
	}
}

func TestParseProfileRejectsMissingEmail(t *testing.T) {
	if _, err := parseProfile([]byte(`{"account":{},"organization":{"uuid":"o"}}`)); err == nil {
		t.Fatal("expected an error for a profile without an email")
	}
}
