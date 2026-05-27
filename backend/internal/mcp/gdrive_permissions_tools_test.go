package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func TestGDriveShareFileApproved(t *testing.T) {
	var sawMethod, sawPath, sawAuth, sawNotify string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawMethod = r.Method
		sawPath = r.URL.Path
		sawNotify = r.URL.Query().Get("sendNotificationEmail")
		sawAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"perm_123","type":"user","role":"writer","emailAddress":"vincentluan@example.com"}`))
	}))
	defer srv.Close()
	prevBase := gdriveAPIBase
	gdriveAPIBase = srv.URL
	defer func() { gdriveAPIBase = prevBase }()

	payload := &GDrivePayload{
		ClientID:        "client",
		RefreshToken:    "refresh",
		AccessToken:     "access-token",
		AccessExpiresAt: time.Now().Add(time.Hour),
		Scope:           gdriveScope,
	}
	encoded, err := payload.Marshal()
	if err != nil {
		t.Fatalf("payload marshal: %v", err)
	}
	gw := newGDriveShareTestGateway(srv.Client(), encoded)
	em := &approvingEmitter{}
	gate := NewGateService(em)
	em.g = gate
	gw.Gate = gate

	res, err := gw.gdriveShareFile(context.Background(), newCallRequest(map[string]any{
		"file_id": "sheet123",
		"email":   "vincentluan@example.com",
	}))
	if err != nil {
		t.Fatalf("share: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected error result: %+v text=%q", res, toolResultText(res))
	}
	if sawMethod != http.MethodPost || sawPath != "/files/sheet123/permissions" {
		t.Fatalf("method/path = %s %s", sawMethod, sawPath)
	}
	if sawNotify != "false" {
		t.Errorf("sendNotificationEmail = %q, want false", sawNotify)
	}
	if sawAuth != "Bearer access-token" {
		t.Errorf("Authorization = %q", sawAuth)
	}
	if gotBody["type"] != "user" || gotBody["role"] != "writer" || gotBody["emailAddress"] != "vincentluan@example.com" {
		t.Errorf("permission body = %#v", gotBody)
	}
}

func TestGDriveScopeIncludesSheetsAndDriveFile(t *testing.T) {
	for _, scope := range []string{
		"https://www.googleapis.com/auth/spreadsheets",
		"https://www.googleapis.com/auth/drive.file",
	} {
		if !strings.Contains(gdriveScope, scope) {
			t.Errorf("gdriveScope missing %s", scope)
		}
	}
}

func newGDriveShareTestGateway(client *http.Client, payload string) *Gateway {
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = 1
	reg.Sequence = []int{1}
	reg.Accounts[1] = &domain.Account{
		Number: 1,
		Email:  "google@example.com",
		MCPConnectors: domain.AccountConnectors{
			domain.MCPServiceGDrive: &domain.MCPConnector{Enabled: true},
		},
	}
	gw := newTestGateway()
	gw.HTTP = client
	gw.Resolver = &Resolver{
		Registry: &fakeRegistry{reg: reg},
		Secrets:  fakeSecrets{key(1, domain.MCPServiceGDrive): payload},
	}
	return gw
}
