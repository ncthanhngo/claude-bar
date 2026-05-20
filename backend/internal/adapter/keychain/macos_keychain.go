// Package keychain wraps macOS Keychain generic password entries that hold
// Claude Code OAuth credentials and local MCP connector secrets.
package keychain

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

// kcRead looks up a generic-password item using the modern SecItem API.
// The item does not need per-app ACL trust — kSecAttrAccessibleAfterFirstUnlock
// items are accessible by any process after the first post-boot unlock.
// Returns errSecItemNotFound when absent; caller must free(*outData).
static OSStatus kcRead(const char* svc, UInt32 svcLen,
                       const char* acc, UInt32 accLen,
                       char** outData, UInt32* outLen) {
    CFStringRef service = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)svc, svcLen, kCFStringEncodingUTF8, false);
    CFStringRef account = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)acc, accLen, kCFStringEncodingUTF8, false);

    const void* keys[]   = { kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit };
    const void* values[] = { kSecClassGenericPassword, service, account, kCFBooleanTrue, kSecMatchLimitOne };
    CFDictionaryRef query = CFDictionaryCreate(kCFAllocatorDefault,
        keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(query, &result);

    CFRelease(service);
    CFRelease(account);
    CFRelease(query);

    if (status == errSecSuccess && result != NULL) {
        CFDataRef data = (CFDataRef)result;
        *outLen = (UInt32)CFDataGetLength(data);
        *outData = (char*)malloc(*outLen + 1);
        memcpy(*outData, CFDataGetBytePtr(data), *outLen);
        (*outData)[*outLen] = '\0';
        CFRelease(result);
    }
    return status;
}

// kcWrite upserts a generic-password item with kSecAttrAccessibleAfterFirstUnlock,
// which carries no per-app ACL. It deletes any existing item first (which may
// have been created by another app with a restrictive ACL, e.g. the claude CLI).
static OSStatus kcWrite(const char* svc, UInt32 svcLen,
                        const char* acc, UInt32 accLen,
                        const char* pwd, UInt32 pwdLen) {
    CFStringRef service = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)svc, svcLen, kCFStringEncodingUTF8, false);
    CFStringRef account = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)acc, accLen, kCFStringEncodingUTF8, false);
    CFDataRef password = CFDataCreate(kCFAllocatorDefault, (const UInt8*)pwd, pwdLen);

    // Delete any existing item so we can recreate with our own accessible attribute.
    const void* dKeys[]   = { kSecClass, kSecAttrService, kSecAttrAccount };
    const void* dValues[] = { kSecClassGenericPassword, service, account };
    CFDictionaryRef delQuery = CFDictionaryCreate(kCFAllocatorDefault,
        dKeys, dValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecItemDelete(delQuery);
    CFRelease(delQuery);

    // Add fresh item — kSecAttrAccessibleAfterFirstUnlock = no per-app ACL prompt.
    const void* aKeys[]   = { kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData, kSecAttrAccessible };
    const void* aValues[] = { kSecClassGenericPassword, service, account, password, kSecAttrAccessibleAfterFirstUnlock };
    CFDictionaryRef addQuery = CFDictionaryCreate(kCFAllocatorDefault,
        aKeys, aValues, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = SecItemAdd(addQuery, NULL);

    CFRelease(service);
    CFRelease(account);
    CFRelease(password);
    CFRelease(addQuery);
    return status;
}

// kcDelete removes a generic-password item; returns errSecSuccess if absent.
static OSStatus kcDelete(const char* svc, UInt32 svcLen,
                         const char* acc, UInt32 accLen) {
    CFStringRef service = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)svc, svcLen, kCFStringEncodingUTF8, false);
    CFStringRef account = CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)acc, accLen, kCFStringEncodingUTF8, false);

    const void* keys[]   = { kSecClass, kSecAttrService, kSecAttrAccount };
    const void* values[] = { kSecClassGenericPassword, service, account };
    CFDictionaryRef query = CFDictionaryCreate(kCFAllocatorDefault,
        keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = SecItemDelete(query);

    CFRelease(service);
    CFRelease(account);
    CFRelease(query);
    return (status == errSecItemNotFound) ? errSecSuccess : status;
}
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

// Keychain talks to the macOS Keychain via Security.framework (SecItem API).
type Keychain struct {
	service string
	account string
}

// New returns a Keychain bound to (service, account).
func New(service, account string) *Keychain {
	return &Keychain{service: service, account: account}
}

// Read returns the password payload for this (service, account).
func (k *Keychain) Read(_ context.Context) (string, error) {
	svc := []byte(k.service)
	acc := []byte(k.account)
	svcPtr := C.CBytes(svc)
	accPtr := C.CBytes(acc)
	defer C.free(svcPtr)
	defer C.free(accPtr)

	var outData *C.char
	var outLen C.UInt32

	status := C.kcRead(
		(*C.char)(svcPtr), C.UInt32(len(svc)),
		(*C.char)(accPtr), C.UInt32(len(acc)),
		&outData, &outLen,
	)
	if status == C.errSecItemNotFound {
		return "", ErrNotFound
	}
	if status != C.errSecSuccess {
		return "", &Error{Op: "read", Stderr: fmt.Sprintf("SecItem status %d", int(status))}
	}
	defer C.free(unsafe.Pointer(outData))
	return string(C.GoBytes(unsafe.Pointer(outData), C.int(outLen))), nil
}

// Write upserts the password for this (service, account).
// Recreates the item with kSecAttrAccessibleAfterFirstUnlock so any
// process can read it without a per-app ACL prompt.
func (k *Keychain) Write(_ context.Context, payload string) error {
	svc := []byte(k.service)
	acc := []byte(k.account)
	pwd := []byte(payload)
	svcPtr := C.CBytes(svc)
	accPtr := C.CBytes(acc)
	pwdPtr := C.CBytes(pwd)
	defer C.free(svcPtr)
	defer C.free(accPtr)
	defer C.free(pwdPtr)

	status := C.kcWrite(
		(*C.char)(svcPtr), C.UInt32(len(svc)),
		(*C.char)(accPtr), C.UInt32(len(acc)),
		(*C.char)(pwdPtr), C.UInt32(len(pwd)),
	)
	if status != C.errSecSuccess {
		return &Error{Op: "write", Stderr: fmt.Sprintf("SecItem status %d", int(status))}
	}
	return nil
}

// Delete removes the entry. No error if absent.
func (k *Keychain) Delete(_ context.Context) error {
	svc := []byte(k.service)
	acc := []byte(k.account)
	svcPtr := C.CBytes(svc)
	accPtr := C.CBytes(acc)
	defer C.free(svcPtr)
	defer C.free(accPtr)

	status := C.kcDelete(
		(*C.char)(svcPtr), C.UInt32(len(svc)),
		(*C.char)(accPtr), C.UInt32(len(acc)),
	)
	if status != C.errSecSuccess {
		return &Error{Op: "delete", Stderr: fmt.Sprintf("SecItem status %d", int(status))}
	}
	return nil
}

// Error carries the operation and status for diagnostics.
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
