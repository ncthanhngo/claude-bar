import XCTest
@testable import ClaudeWidget

final class OAuthBlobInspectorTests: XCTestCase {

    func testReturnsNilForEmptyString() {
        XCTAssertNil(OAuthBlobInspector.identifier(from: ""))
    }

    func testReturnsNilForNonJSON() {
        XCTAssertNil(OAuthBlobInspector.identifier(from: "not json"))
        XCTAssertNil(OAuthBlobInspector.identifier(from: "{broken"))
    }

    func testReturnsNilWhenNoIdentifyingKeysPresent() {
        let blob = #"{"foo":"bar","nested":{"baz":42}}"#
        XCTAssertNil(OAuthBlobInspector.identifier(from: blob))
    }

    func testTopLevelUUIDFound() {
        let blob = #"{"uuid":"abc-123","other":"x"}"#
        XCTAssertEqual(OAuthBlobInspector.identifier(from: blob), "abc-123")
    }

    func testNestedAccountUUIDFound() {
        let blob = #"{"claudeAiOauth":{"account":{"uuid":"nested-uuid","email":"x@y.z"}}}"#
        // Either uuid OR email is valid — first match in tree.
        let id = OAuthBlobInspector.identifier(from: blob)
        XCTAssertNotNil(id)
        XCTAssertTrue(id == "nested-uuid" || id == "x@y.z")
    }

    func testEmailAddressKeyVariants() {
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: #"{"email_address":"a@b.c"}"#),
            "a@b.c"
        )
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: #"{"emailAddress":"a@b.c"}"#),
            "a@b.c"
        )
    }

    func testEmptyStringValuesIgnored() {
        let blob = #"{"uuid":"","email":"real@example.com"}"#
        XCTAssertEqual(OAuthBlobInspector.identifier(from: blob), "real@example.com")
    }

    func testSameIdentityBlobs_DifferentTokens_ShareIdentifier() {
        // Simulates two snapshots of the same user — tokens differ but
        // the embedded account UUID stays stable.
        let blobA = #"{"accessToken":"AAA","claudeAiOauth":{"account":{"uuid":"same-uuid"}}}"#
        let blobB = #"{"accessToken":"BBB","claudeAiOauth":{"account":{"uuid":"same-uuid"}}}"#
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: blobA),
            OAuthBlobInspector.identifier(from: blobB)
        )
    }

    func testDifferentIdentitiesDiffer() {
        let blobA = #"{"account":{"uuid":"id-a"}}"#
        let blobB = #"{"account":{"uuid":"id-b"}}"#
        XCTAssertNotEqual(
            OAuthBlobInspector.identifier(from: blobA),
            OAuthBlobInspector.identifier(from: blobB)
        )
    }

    func testArrayTraversal() {
        let blob = #"{"users":[{"uuid":"in-array"}]}"#
        XCTAssertEqual(OAuthBlobInspector.identifier(from: blob), "in-array")
    }

    func testExtendedKeySet_AccountUuid() {
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: #"{"account_uuid":"acc-1"}"#),
            "acc-1"
        )
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: #"{"accountUuid":"acc-2"}"#),
            "acc-2"
        )
    }

    func testExtendedKeySet_Sub() {
        // JWT-style "sub" claim
        XCTAssertEqual(
            OAuthBlobInspector.identifier(from: #"{"sub":"user-sub"}"#),
            "user-sub"
        )
    }

    // MARK: - stableSignature

    func testSignatureMatchesAcrossTokenRotation() {
        // Same identity, different tokens — should produce identical signatures.
        let blobA = #"{"access_token":"AAA","refresh_token":"R1","expires_at":1,"scope":"x","plan":"max"}"#
        let blobB = #"{"access_token":"BBB","refresh_token":"R2","expires_at":2,"scope":"x","plan":"max"}"#
        let sigA = OAuthBlobInspector.stableSignature(from: blobA)
        let sigB = OAuthBlobInspector.stableSignature(from: blobB)
        XCTAssertNotNil(sigA)
        XCTAssertEqual(sigA, sigB,
            "Stripping ephemeral fields should yield same signature for same account")
    }

    func testSignatureDiffersAcrossAccounts() {
        let blobA = #"{"access_token":"A","scope":"x","plan":"max","user":"alice"}"#
        let blobB = #"{"access_token":"A","scope":"x","plan":"max","user":"bob"}"#
        XCTAssertNotEqual(
            OAuthBlobInspector.stableSignature(from: blobA),
            OAuthBlobInspector.stableSignature(from: blobB)
        )
    }

    func testSignatureNilForPureTokenBlob() {
        // If stripping removes everything, signature is nil so we don't
        // false-positive every snapshot as a duplicate of every other.
        let blob = #"{"access_token":"X","refresh_token":"Y","expires_at":1}"#
        XCTAssertNil(OAuthBlobInspector.stableSignature(from: blob))
    }

    func testSignatureNilForEmptyJSON() {
        XCTAssertNil(OAuthBlobInspector.stableSignature(from: "{}"))
    }

    func testSignatureNilForInvalidJSON() {
        XCTAssertNil(OAuthBlobInspector.stableSignature(from: "not json"))
    }

    func testSignatureKeyOrderIndependent() {
        // sorted-keys serialization → field order in source shouldn't matter.
        let blobA = #"{"plan":"max","user":"x","access_token":"A"}"#
        let blobB = #"{"access_token":"B","user":"x","plan":"max"}"#
        XCTAssertEqual(
            OAuthBlobInspector.stableSignature(from: blobA),
            OAuthBlobInspector.stableSignature(from: blobB)
        )
    }
}

