package claudecli

import (
	"os"
	"strings"
	"testing"
)

func TestSanitisedEnvDropsSecretLeakage(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "sk-leak")
	t.Setenv("OPENAI_API_KEY", "sk-openai")
	t.Setenv("CB_CHAT_TOOL_MODE", "full")
	t.Setenv("CLAUDE_CONFIG_DIR", "/stale/dir")
	t.Setenv("PATH", "/usr/bin")
	t.Setenv("HOME", "/Users/test")

	env := sanitisedEnv("/locked/config")
	joined := strings.Join(env, "\n")

	for _, banned := range []string{"ANTHROPIC_", "OPENAI_", "CB_CHAT_TOOL_MODE", "/stale/dir"} {
		if strings.Contains(joined, banned) {
			t.Errorf("env should not contain %q; got %q", banned, joined)
		}
	}
	mustContain := []string{"PATH=/usr/bin", "HOME=/Users/test", "CLAUDE_CONFIG_DIR=/locked/config", "TERM=dumb"}
	for _, want := range mustContain {
		if !strings.Contains(joined, want) {
			t.Errorf("env missing %q; got %q", want, joined)
		}
	}
}

func TestSanitisedEnvOmitsAccountDirWhenEmpty(t *testing.T) {
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	env := sanitisedEnv("")
	for _, e := range env {
		if strings.HasPrefix(e, "CLAUDE_CONFIG_DIR=") {
			t.Errorf("empty configDir should omit env var, got %q", e)
		}
	}
}

func TestSlotMutexSingleHolderQueueDepth(t *testing.T) {
	commandCenterSlot = &slotMutex{}
	if !commandCenterSlot.tryAcquire() {
		t.Fatalf("first acquire must succeed")
	}
	if commandCenterSlot.tryAcquire() {
		t.Fatalf("second acquire while held must return false")
	}
	if got := QueueDepth(); got != 1 {
		t.Errorf("queue depth after rejected acquire = %d, want 1", got)
	}
	commandCenterSlot.release()
	if !commandCenterSlot.tryAcquire() {
		t.Errorf("acquire after release must succeed")
	}
	commandCenterSlot.release()
}

func TestSessionContextRendersOnlyPopulatedFields(t *testing.T) {
	ctx := SessionContext{
		RepoPath:      "/Users/me/proj",
		BriefingFocus: "3 PRs, 14:00 demo",
	}
	out := ctx.Render()
	if !strings.Contains(out, "/Users/me/proj") || !strings.Contains(out, "Briefing focus") {
		t.Errorf("render dropped fields: %q", out)
	}
	if strings.Contains(out, "Active SSH host") || strings.Contains(out, "Active Claude account") {
		t.Errorf("empty fields leaked into render: %q", out)
	}

	empty := SessionContext{}
	if empty.Render() != "" {
		t.Errorf("empty SessionContext should render to empty string")
	}
}
