package port

import "errors"

// ErrKeyNotFound: ChatDBKeyStore.Read returned no entry for the given
// account. Caller should generate a new master key (crypto/rand 32 bytes),
// Write it, and proceed. Distinct from a transport / Keychain access
// failure so the storage opener can take the right path.
var ErrKeyNotFound = errors.New("port: key not found in store")
