package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// runAudit dispatches `csw audit <tail|path>`. The widget Diagnostics
// Audit card calls tail to render the last N events and uses path to open
// the active file in a text editor.
func runAudit(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw audit <tail|path>")
	}
	switch args[0] {
	case "tail":
		return runAuditTail(ctx, args[1:])
	case "path":
		fmt.Println(adapter.AuditLogFile())
		return nil
	default:
		return fmt.Errorf("unknown audit subcommand: %s", args[0])
	}
}

func runAuditTail(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("audit-tail", flag.ExitOnError)
	n := fs.Int("n", 50, "lines from the end of audit.log")
	_ = fs.Parse(args)

	path := adapter.AuditLogFile()
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			// No events yet — emit empty array so the widget can render zero.
			_, _ = io.WriteString(os.Stdout, "[]\n")
			return nil
		}
		return err
	}
	defer f.Close()

	lines := []json.RawMessage{}
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 8192), 1<<20)
	for scanner.Scan() {
		raw := append([]byte(nil), scanner.Bytes()...)
		var probe map[string]any
		if json.Unmarshal(raw, &probe) != nil {
			continue
		}
		lines = append(lines, raw)
	}
	if *n > 0 && *n < len(lines) {
		lines = lines[len(lines)-*n:]
	}
	return json.NewEncoder(os.Stdout).Encode(lines)
}
