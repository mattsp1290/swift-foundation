import Foundation
import SessionCredentials

/// A separate native consumer of the public Keychain product.
@MainActor
final class CatalogSessionFixture: ObservableObject {
    @Published private(set) var result = "Keychain unchecked"
    private let store = KeychainSessionCredentialStore(
        service: "homes.birb.foundationconsumers.catalog.fixture", account: "refresh"
    )

    func roundTrip() async {
        do {
            try await store.clear()
            try await store.store(RefreshCredential(value: "catalog-fixture-credential"))
            guard try await store.load()?.value == "catalog-fixture-credential" else {
                result = "Keychain round trip failed"
                return
            }
            try await store.clear()
            result = try await store.load() == nil
                ? "Keychain store, load, clear passed" : "Keychain clear failed"
        } catch {
            result = "Keychain round trip failed"
        }
    }
}
