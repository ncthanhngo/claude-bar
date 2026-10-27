//go:build windows

package main

// platformCommands is the account-swap subset the Windows build supports.
var platformCommands = map[string]bool{
	"list": true, "active": true, "switch": true, "add": true,
	"rename": true, "remove": true, "verify": true, "sessions": true,
	"login-url": true, "add-oauth-code": true, "snapshot-active": true,
	"help": true, "-h": true, "--help": true,
}
