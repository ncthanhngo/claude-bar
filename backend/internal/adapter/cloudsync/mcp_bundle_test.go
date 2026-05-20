package cloudsync

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func TestCloudBundleCanCarryEncryptedMCPConnectors(t *testing.T) {
	bundle := &CloudBundle{
		Version: 2,
		Accounts: []BundleAccount{{
			Number:         1,
			Email:          "a@b.c",
			CredentialBlob: "claude-secret",
			MCPConnectors: []BundleMCPConnector{{
				Service: domain.MCPServiceSlack,
				Payload: "xoxp-secret",
				Enabled: true,
			}},
		}},
		SharedMCPConnectors: []BundleMCPConnector{{
			Service: domain.MCPServiceGDrive,
			Payload: `{"refreshToken":"refresh-secret"}`,
			Enabled: true,
		}},
	}

	encrypted, err := Encrypt(bundle, "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encrypted), "xoxp-secret") || strings.Contains(string(encrypted), "refresh-secret") {
		t.Fatal("encrypted bundle leaked plaintext connector secret")
	}
	back, err := Decrypt(encrypted, "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	if back.Accounts[0].MCPConnectors[0].Payload != "xoxp-secret" {
		t.Fatalf("account connector did not round-trip: %+v", back.Accounts[0].MCPConnectors)
	}
	if back.SharedMCPConnectors[0].Payload == "" {
		t.Fatalf("shared connector did not round-trip: %+v", back.SharedMCPConnectors)
	}
}

func TestCloudBundleMCPConnectorsAreExplicitSecretFields(t *testing.T) {
	b, err := json.Marshal(CloudBundle{
		Version: 2,
		SharedMCPConnectors: []BundleMCPConnector{{
			Service: domain.MCPServiceClickUp,
			Payload: "pk_secret",
			Enabled: true,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)
	for _, want := range []string{"sharedMcpConnectors", "payload", "pk_secret"} {
		if !strings.Contains(out, want) {
			t.Fatalf("bundle JSON missing %q: %s", want, out)
		}
	}
}
