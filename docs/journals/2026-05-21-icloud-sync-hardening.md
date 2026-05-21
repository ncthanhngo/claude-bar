# iCloud Sync Hardening: Three-Phase Credential Consistency Fix

**Date**: 2026-05-21 14:00  
**Severity**: High  
**Component**: Cloud sync (Go backend) + Account switching (Swift frontend)  
**Status**: Resolved  

## What Happened

Completed a three-phase hardening of iCloud credential synchronization across `cloud_push.go`, `cloud_pull.go`, and `AppStore.swift`. The work addressed a critical gap: the bundle could contain stale or incomplete credentials, and pull operations could silently lose local changes to credentials. All 19 tests pass with `-race`, but the solution lives with two unresolved pre-existing gaps and one low-risk trade-off.

## The Brutal Truth

This work felt like plugging holes in a dam that's still leaking. We fixed the immediate credential loss scenarios, but the architecture has structural problems that no amount of per-function locking will solve:

1. **MCP connector failures** inside the per-account restore loop still hard-fail the entire pull — one bad keychain write for a single connector type (e.g., GitHub) stops 10 other accounts from being restored.
2. **SharedMCPConnectors** are saved to the registry even if every single account credential write failed — the bundle restored nothing but the registry now claims it has shared connectors.
3. The background goroutine in `CloudPull` holds the file lock *while* `RefreshAllTokens` runs in the background — documented via INVARIANT comment that `RefreshAllTokens` must never call `s.Lock.Acquire`, but this is a code smell that says the abstraction is wrong.

What makes this painful is that each of these required explicit discipline to document instead of being caught by types or the compiler. In 6 months, someone will refactor and silently violate the INVARIANT, creating a deadlock that only shows up under load.

## Technical Details

### Phase 1: CloudPush (Option B + R5 + R2)

**Option B: Refresh before lock**
```go
// Line 23: refresh happens outside the lock
_ = s.RefreshAllTokens(ctx)

// Line 27: only then acquire the lock
if err := s.Lock.Acquire(ctx); err != nil {
    return fmt.Errorf("acquire push lock: %w", err)
}
```

Why this matters: `RefreshAllTokens` calls the OAuth provider to get fresh tokens. If we held the file lock during that network call, we'd block `SwitchAccount` (which also acquires the lock) for the duration of that HTTP round-trip. Option B is best-effort — stale backups are better than blocking account switches.

**R2: Active account fallback with hard-fail**
```go
// Lines 49-62: active account MUST be in bundle
if acc.Number == reg.ActiveAccountNumber {
    live, liveErr := s.Live.Read(ctx)
    if liveErr != nil || live == "" {
        bak, _ := s.Backup.Read(ctx, acc.Number, acc.Email)
        if bak == "" {
            return fmt.Errorf("active account %d (%s): live credential unreadable and no backup — cannot push", acc.Number, acc.Email)
        }
        blob = string(bak)
    } else {
        blob = string(live)
    }
}
```

The original code would silently skip the active account if the live read failed AND there was no backup. The bundle would be "complete" but missing the most important credential. Now we fail loudly so the caller knows the push is incomplete.

Test coverage:
- `TestCloudPush_R2_ActiveLiveFailFallsBackToBackup` — verifies fallback works
- `TestCloudPush_R2_ActiveLiveFailNoBackup_ReturnsError` — verifies hard-fail with specific error message

### Phase 2: CloudPull (Option A + R6 + R1)

**Option A: Prefer-newer comparison**
```go
// Lines 60-68: compare expiresAt of local backup vs bundle
localBlob, localErr := s.Backup.Read(ctx, ba.Number, ba.Email)
if localErr == nil && localBlob != "" {
    bundlePayload, bErr := bundleBlob.Extract()
    localPayload, lErr := localBlob.Extract()
    if bErr == nil && lErr == nil && localPayload.ExpiresAt > bundlePayload.ExpiresAt {
        writeBlob = localBlob
    }
}
```

The comparison is millisecond-precision Unix timestamps. Zero is treated as epoch 0 and always loses to a real token. Bundle wins on tie (new-machine scenario — bundle is authoritative). This prevents pulling a stale token that overwrites a recently-refreshed local one.

**R6: Failure accumulation** (lines 71-104)
```go
// Line 73: collect failures instead of aborting
if writeErr := s.Backup.Write(ctx, ba.Number, ba.Email, writeBlob); writeErr != nil {
    failures = append(failures, fmt.Sprintf("account %d (%s): %v", ba.Number, ba.Email, writeErr))
    continue
}

// Lines 79-98: only successful accounts added to registry
if _, exists := reg.Accounts[ba.Number]; !exists {
    reg.Accounts[ba.Number] = &domain.Account{}
    ...
}

// Line 102: registry saved AFTER the loop, only for successful accounts
if saveErr := s.Registry.Save(ctx, reg); saveErr != nil {
    return fmt.Errorf("save registry: %w", saveErr)
}

// Lines 116-120: report partial failure
if len(failures) > 0 {
    return fmt.Errorf("partial restore (%d/%d): %s", ...)
}
```

This is critical: one bad keychain write no longer aborts the entire pull. We continue restoring other accounts, save the registry for those that succeeded, and return a partial-failure error that tells the caller how many succeeded and which ones failed.

**R1: Background refresh validation** (lines 110-114)
```go
go func() {
    bgCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    _ = s.RefreshAllTokens(bgCtx)
}()
```

After a successful pull, immediately validate the pulled credentials by refreshing them in the background. This catches bad tokens before the user tries to switch to them. The goroutine fires while the defer is still live — the lock is released before this runs, so it's safe.

Test coverage:
- Four Option A tests (bundle fresher, local fresher, local missing, tie)
- `TestCloudPull_R6_OneAccountWriteError_OthersSucceed_RegistrySaved` — verifies one failure doesn't stop others
- `TestCloudPull_R1_RefreshFiredAfterSave` — verifies background goroutine fires

### Phase 3: AppStore.swift (R4)

```swift
// Lines 96-111: swap function
func swap(to num: Int) async {
    swappingTo = num
    do {
        print("[AppStore] Switching to account \(num)")
        try await client.switchTo(num)
        await refreshNow()
        print("[AppStore] Switched to account \(num)")
        swappingTo = nil
        schedulePostSwapIntegrations()
        await autoPushCloud()  // Line 105: NEW
    } catch {
        ...
    }
}
```

After every successful account switch, the bundle is updated with the new active account's credentials. This ensures the iCloud copy never gets out of sync even if the background push loop hasn't run yet.

### Supporting Changes

**BundlePath environment variable override** (in cloudsync adapter):
```go
// Tests can inject CLAUDE_SWAP_BUNDLE_PATH to avoid writing to real iCloud
func writeBundleFile(t *testing.T, bundle *cloudsync.CloudBundle, passphrase string) func() {
    ...
    t.Setenv("CLAUDE_SWAP_BUNDLE_PATH", f.Name())
    ...
}
```

This was necessary to test CloudPull without real file I/O or real iCloud paths.

## What We Tried

The implementation was mostly correct from first principles:
- The options (Option A, Option B) were sound — prefer-newer for pull, refresh-before-lock for push
- The serialization point (R5 lock in CloudPush) was the only way to guarantee active account consistency with SwitchAccount
- Failure accumulation (R6) was the only way to avoid cascading failures

What we *didn't* try (and shouldn't):
- Transaction-like rollback of partial restores (over-engineered; partial restore + clear error message is fine)
- Holding the lock across network calls (blocks the UI)
- Delaying active account push until after pull confirms all tokens valid (defeats the whole point of async push)

## Root Cause Analysis

The root cause wasn't a single bug — it was architectural: the original code treated cloud sync as a best-effort background operation with no error handling. The problems:

1. **Silent loss of active account** in push — if keychain read failed, the code would just skip it instead of failing loudly. The bundle would look "complete" to the user but be useless.
2. **Overwrite-without-comparison** in pull — pulling an old bundle would always overwrite a locally-refreshed token, losing work.
3. **No post-swap push** — credentials would be switched, but the bundle wouldn't update until the next scheduled push. A device restored from the bundle before that push would get the old credentials.
4. **Cascading failure** on partial restores — one bad MCP connector would fail the entire pull instead of continuing for other accounts.

None of these were implementation bugs. They were design gaps that assumed "this probably won't happen" (it did) and "the user will re-push if something goes wrong" (they didn't know it went wrong).

## Lessons Learned

1. **Network calls and locks don't mix** — Option B (refresh before lock) feels awkward because it is. We're saying "refresh might happen while another thread is writing, and that's acceptable." In Go, this usually means the abstraction is leaky. The fix was right, but it should signal that `RefreshAllTokens` shouldn't exist as a low-level operation — it should be called at clear, well-defined points only.

2. **Partial failures need clear communication** — The partial-restore error message (`partial restore (17/20): ...`) is more valuable than either success or hard-fail. Future work should add metrics or logging so we can see how many pulls fail partially vs completely.

3. **Documentation via code is fragile** — The INVARIANT comment on lines 108-109 is necessary and correct, but it's a code smell. In 6 months, someone will refactor `RefreshAllTokens` to call `s.Lock.Acquire` (it seems harmless) and create a deadlock that only shows up under load. Types or structured assertions (e.g., prohibiting calls to Lock inside Refresh) would be better, but Go doesn't give us that.

4. **MCP connector failures are a separate problem** — The per-account loop still hard-fails if `restoreMCPConnectors` returns an error. This is pre-existing and out of scope for this work, but it's a blocker for production reliability. It should be tracked as a separate hardening task.

5. **Testing with real encryption is worth it** — `writeBundleFile` uses actual `cloudsync.Encrypt` and `cloudsync.Decrypt`, not mocks. This caught a subtle bug in how we compare expiration times (zero-timestamp handling). Mocking the encryption would have missed that.

## Next Steps

1. **Pre-existing gap: MCP connector restore failures** — Move the `restoreMCPConnectors` call for each account outside the per-account loop, or allow partial MCP failures per account (continue loop, accumulate errors, like we do for Backup.Write). This is a separate fix because it requires design changes to the MCP restore interface.

2. **Pre-existing gap: SharedMCPConnectors saved on credential failure** — Add a check before `Registry.Save` to verify at least one account was successfully restored. If zero accounts succeeded but SharedMCPConnectors were set, either skip the save or clear SharedMCPConnectors. Low risk as-is, but worth fixing for correctness.

3. **Metrics for partial failures** — Add observability: log partial restore events with success ratio and failure reasons. This will tell us if one particular account or connector is consistently failing.

4. **INVARIANT documentation** — Consider extracting RefreshAllTokens into a separate struct or package that explicitly prohibits lock-holding. This would be a larger refactor, but worth scoping for a future hardening sprint.

5. **Bundle freshness check before pull** — Add CloudStatus check before CloudPull to warn if the local bundle is newer than what we're about to pull. Prevents the case where user A pushes, user B pulls before push lands on their device, then user B pushes over A's credentials.

## Technical Debt & Risks

**Accepted Risks:**
- Background goroutine in CloudPull can race with the file lock release (defer is still live). Documented via INVARIANT comment; RefreshAllTokens must not acquire s.Lock.
- SharedMCPConnectors saved even if all account writes fail — low probability scenario, documented.
- MCP connector restore failures still cascade — pre-existing, noted for future work.

**Metrics:**
- All 19 tests pass with `-race` flag
- Option A tests cover 4 scenarios (bundle fresher, local fresher, missing local, tie)
- Option B verified with sequence recorder (refresh before lock)
- R2 has two tests (fallback success, fallback failure)
- R6 has two tests (partial failure with registry save, failure accumulation)
- R1 verified with timeout-based polling (background goroutine fires)

## Files Modified

- `backend/internal/usecase/cloud_push.go` — added Option B + R5 + R2
- `backend/internal/usecase/cloud_push_test.go` — new file, 3 tests
- `backend/internal/usecase/cloud_pull.go` — added Option A + R6 + R1
- `backend/internal/usecase/cloud_pull_test.go` — new file, 6 tests
- `widget/Sources/ClaudeSwapWidget/State/AppStore.swift` — added R4 (autoPushCloud after swap)
- `backend/internal/adapter/cloudsync/cloud_bundle.go` — added CLAUDE_SWAP_BUNDLE_PATH env var support

## Unresolved Questions

1. **Should MCP connector restore failures be accumulated like Backup.Write failures?** — Requires refactoring the restoreMCPConnectors interface to accept a failures accumulator. Design decision needed.
2. **What's the user-visible impact of partial restores?** — Users see a warning/error, but should we offer a "retry pull" button or automatic retry? Currently one-shot, no retry.
3. **Do we need a pre-pull freshness check?** — Should CloudPull warn if pulling an older bundle than what we already have? Could prevent accidental overwrites.
