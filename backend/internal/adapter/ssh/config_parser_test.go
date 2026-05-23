package ssh

import (
	"os"
	"path/filepath"
	"testing"
)

const sampleConfig = `
# top-level comment
Host gem-prod
    HostName 10.0.0.1
    Port 2222
    User deploy
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump bastion

Host bastion
    HostName bastion.example.com
    User admin

Host *.staging
    User stage-user
    Port 22
    StrictHostKeyChecking no

Host *
    ServerAliveInterval 60
`

func TestParseSSHConfigBasicStanzas(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config")
	if err := os.WriteFile(p, []byte(sampleConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	hosts, err := ParseSSHConfig(p)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(hosts) != 4 {
		t.Fatalf("want 4 hosts, got %d (%+v)", len(hosts), hosts)
	}

	prod := hosts[0]
	if prod.Name != "gem-prod" || prod.HostName != "10.0.0.1" || prod.Port != 2222 || prod.User != "deploy" {
		t.Errorf("gem-prod parsed wrong: %+v", prod)
	}
	if prod.JumpHost != "bastion" {
		t.Errorf("expected ProxyJump=bastion, got %q", prod.JumpHost)
	}
	if prod.IdentityFile != "~/.ssh/id_ed25519" {
		t.Errorf("identity file: %q", prod.IdentityFile)
	}

	if !hosts[2].IsWildcard() {
		t.Errorf("*.staging should be wildcard")
	}

	if got := hosts[2].Extra["StrictHostKeyChecking"]; got != "no" {
		t.Errorf("extra StrictHostKeyChecking = %q", got)
	}
}

func TestParseSSHConfigIncludeDirective(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "config")
	inc := filepath.Join(dir, "include.conf")

	if err := os.WriteFile(inc, []byte("Host included\n  HostName 1.2.3.4\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(main, []byte("Include "+inc+"\nHost main\n  HostName main.example.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	hosts, err := ParseSSHConfig(main)
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 {
		t.Fatalf("want 2 (1 from include + 1 from main), got %d (%+v)", len(hosts), hosts)
	}
	names := []string{hosts[0].Name, hosts[1].Name}
	want := map[string]bool{"included": true, "main": true}
	for _, n := range names {
		if !want[n] {
			t.Errorf("unexpected host name %q", n)
		}
	}
}

func TestParseSSHConfigMissingFileReturnsEmpty(t *testing.T) {
	hosts, err := ParseSSHConfig(filepath.Join(t.TempDir(), "does-not-exist"))
	if err != nil {
		t.Fatalf("missing file should not error, got %v", err)
	}
	if len(hosts) != 0 {
		t.Fatalf("want empty, got %v", hosts)
	}
}
