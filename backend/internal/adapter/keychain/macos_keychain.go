// Package keychain wraps macOS Keychain generic password entries that hold
// Claude Code OAuth credentials and local MCP connector secrets.
package keychain

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>

// Expose as a plain C function so cgo can see the value — errSecItemNotFound
// is a macro/enum in some SDK versions and not always visible as C.errSecXxx.
static OSStatus kcItemNotFound() { return errSecItemNotFound; }
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"unsafe"
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
// Uses Security.framework directly (same process as Write) — no keychain
// permission dialog, no dependency on the /usr/bin/security CLI.
func (k *Keychain) Read(_ context.Context) (string, error) {
	service := []byte(k.service)
	account := []byte(k.account)

	servicePtr := C.CBytes(service)
	accountPtr := C.CBytes(account)
	defer C.free(servicePtr)
	defer C.free(accountPtr)

	var passwordLen C.UInt32
	var passwordData unsafe.Pointer
	var defaultKeychain C.CFTypeRef // zero value = default keychain list

	status := C.SecKeychainFindGenericPassword(
		defaultKeychain,
		C.UInt32(len(service)),
		(*C.char)(servicePtr),
		C.UInt32(len(account)),
		(*C.char)(accountPtr),
		&passwordLen,
		&passwordData,
		(*C.SecKeychainItemRef)(nil),
	)
	if status == C.kcItemNotFound() {
		return "", ErrNotFound
	}
	if status != C.errSecSuccess {
		return "", &Error{Op: "read", Stderr: fmt.Sprintf("security framework status %d", int(status))}
	}
	defer C.free(passwordData)

	return string(C.GoBytes(passwordData, C.int(passwordLen))), nil
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
func (k *Keychain) Delete(_ context.Context) error {
	service := []byte(k.service)
	account := []byte(k.account)

	servicePtr := C.CBytes(service)
	accountPtr := C.CBytes(account)
	defer C.free(servicePtr)
	defer C.free(accountPtr)

	var item C.SecKeychainItemRef
	var defaultKeychain C.CFTypeRef

	status := C.SecKeychainFindGenericPassword(
		defaultKeychain,
		C.UInt32(len(service)),
		(*C.char)(servicePtr),
		C.UInt32(len(account)),
		(*C.char)(accountPtr),
		(*C.UInt32)(nil),
		nil,
		&item,
	)
	if status == C.kcItemNotFound() {
		return nil
	}
	if status != C.errSecSuccess {
		return &Error{Op: "delete", Stderr: fmt.Sprintf("find status %d", int(status))}
	}
	defer C.CFRelease(C.CFTypeRef(item))

	if st := C.SecKeychainItemDelete(item); st != C.errSecSuccess {
		return &Error{Op: "delete", Stderr: fmt.Sprintf("security framework status %d", int(st))}
	}
	return nil
}

// Error carries the operation and status code for diagnostics.
type Error struct {
	Op     string
	Stderr string
	Err    error
}

func (e *Error) Error() string {
	if e.Stderr != "" {
		return "keychain " + e.Op + ": " + e.Stderr
	}
	return "keychain " + e.Op + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }
