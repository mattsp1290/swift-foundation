import SessionCredentials
import XCTest

final class SessionCredentialStoreTests: XCTestCase {
    func testInMemoryStoreReplacesAndClearsOnlyRefreshCredential() async throws {
        let store: any SessionCredentialStore = InMemorySessionCredentialStore()
        let empty = try await store.load()
        XCTAssertNil(empty)
        try await store.store(RefreshCredential(value: "opaque-refresh-1"))
        let first = try await store.load()
        XCTAssertEqual(first, RefreshCredential(value: "opaque-refresh-1"))
        try await store.store(RefreshCredential(value: "opaque-refresh-2"))
        let second = try await store.load()
        XCTAssertEqual(second, RefreshCredential(value: "opaque-refresh-2"))
        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    #if os(macOS)
    func testKeychainRoundTripAcrossStoreInstancesWithReplacementAndClear() async throws {
        let service = "homes.birb.swift-foundation.tests.\(UUID().uuidString)"
        let account = "refresh"
        let first: any SessionCredentialStore = KeychainSessionCredentialStore(service: service, account: account)
        let reopened: any SessionCredentialStore = KeychainSessionCredentialStore(service: service, account: account)
        defer {
            Task { try? await first.clear() }
        }

        let empty = try await first.load()
        XCTAssertNil(empty)
        try await first.store(RefreshCredential(value: "opaque-refresh-first"))
        let initial = try await reopened.load()
        XCTAssertEqual(initial, RefreshCredential(value: "opaque-refresh-first"))
        try await reopened.store(RefreshCredential(value: "opaque-refresh-replacement"))
        let replacement = try await first.load()
        XCTAssertEqual(replacement, RefreshCredential(value: "opaque-refresh-replacement"))

        try await first.clear()
        let cleared = try await reopened.load()
        XCTAssertNil(cleared)
        try await reopened.clear()
    }

    func testKeychainServiceAndAccountAreIndependent() async throws {
        let service = "homes.birb.swift-foundation.tests.\(UUID().uuidString)"
        let first = KeychainSessionCredentialStore(service: service, account: "first")
        let other = KeychainSessionCredentialStore(service: service, account: "other")
        defer {
            Task {
                try? await first.clear()
                try? await other.clear()
            }
        }
        try await first.store(RefreshCredential(value: "opaque-refresh-only-first"))
        let otherValue = try await other.load()
        XCTAssertNil(otherValue)
    }
    #endif
}
