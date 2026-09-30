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
}
