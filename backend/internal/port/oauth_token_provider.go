package port

import "context"

// OAuthTokenProvider gives the chat usecase a single "give me a fresh token
// for this account" call. The concrete adapter (composition root wires it in
// cmd/csw) reads the credential blob, decides if it's expired, calls
// TokenRefresher when needed, persists the rotated blob, and returns the
// access token plus the account UUID (so downstream guards have something
// to scope conversations by).
//
// Splitting this out from TokenRefresher / LiveCredentialStore lets the chat
// usecase stay testable with a single fake — no need to assemble three
// collaborating fakes just to get a string back.
type OAuthTokenProvider interface {
	// GetFresh returns a non-expired access token and the account UUID for
	// the given account number. Errors:
	// - domain.ErrTokenRefreshFailed on a non-transient refresh failure
	//   (revoked grant, 400 from /oauth/token).
	// - wrapped network / context errors for transient failures.
	GetFresh(ctx context.Context, accountNum int) (accessToken string, accountUUID string, err error)
}
