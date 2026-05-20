// Package keychain wraps macOS Keychain generic password entries that hold
// Claude Code OAuth credentials and local MCP connector secrets.
package keychain

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// ErrNotFound is returned when the keychain has no entry for the given service.
var ErrNotFound = errors.New("keychain item not found")

// Keychain talks to /usr/bin/security.
type Keychain struct {
	service string
	account string
}

// New returns a Keychain bound to (service, account).
func New(service, account string) *Keychain {
	return &Keychain{service: service, account: account}
}

// Read returns the password payload for this (service, account).
func (k *Keychain) Read(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx,
		"/usr/bin/security",
		"find-generic-password",
		"-s", k.service,
		"-a", k.account,
		"-w",
	)
	var out, errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 44 {
			return "", ErrNotFound
		}
		return "", &Error{Op: "read", Stderr: errOut.String(), Err: err}
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

// Write upserts the password for this (service, account).
func (k *Keychain) Write(ctx context.Context, payload string) error {
	_ = ctx // Native Security.framework calls are synchronous and non-cancellable.
	service := []byte(k.service)
	account := []byte(k.account)
	password := []byte(payload)

	servicePtr := C.CBytes(service)
	accountPtr := C.CBytes(account)
	passwordPtr := C.CBytes(password)
	defer C.free(servicePtr)
	defer C.free(accountPtr)
	defer C.free(passwordPtr)

	var defaultKeychain C.SecKeychainRef
	status := C.SecKeychainAddGenericPassword(
		defaultKeychain,
		C.UInt32(len(service)),
		(*C.char)(servicePtr),
		C.UInt32(len(account)),
		(*C.char)(accountPtr),
		C.UInt32(len(password)),
		passwordPtr,
		(*C.SecKeychainItemRef)(nil),
	)
	if status == C.errSecDuplicateItem {
		var item C.SecKeychainItemRef
		var defaultSearchList C.CFTypeRef
		findStatus := C.SecKeychainFindGenericPassword(
			defaultSearchList,
			C.UInt32(len(service)),
			(*C.char)(servicePtr),
			C.UInt32(len(account)),
			(*C.char)(accountPtr),
			(*C.UInt32)(nil),
			nil,
			&item,
		)
		if findStatus != C.errSecSuccess {
			return &Error{Op: "write", Stderr: fmt.Sprintf("find existing item status %d", int(findStatus))}
		}
		defer C.CFRelease(C.CFTypeRef(item))
		status = C.SecKeychainItemModifyAttributesAndData(
			item,
			nil,
			C.UInt32(len(password)),
			passwordPtr,
		)
	}
	if status != C.errSecSuccess {
		return &Error{Op: "write", Stderr: fmt.Sprintf("security framework status %d", int(status))}
	}
	return nil
}

// Delete removes the entry. No error if absent.
func (k *Keychain) Delete(ctx context.Context) error {
	cmd := exec.CommandContext(ctx,
		"/usr/bin/security",
		"delete-generic-password",
		"-s", k.service,
		"-a", k.account,
	)
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 44 {
			return nil
		}
		return &Error{Op: "delete", Stderr: errOut.String(), Err: err}
	}
	return nil
}

// Error carries the security CLI stderr for diagnostics.
type Error struct {
	Op     string
	Stderr string
	Err    error
}

func (e *Error) Error() string {
	if e.Stderr != "" {
		return "keychain " + e.Op + ": " + strings.TrimSpace(e.Stderr)
	}
	return "keychain " + e.Op + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }
