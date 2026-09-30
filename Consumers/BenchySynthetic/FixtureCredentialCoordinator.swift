import Foundation
import SessionCredentials

/// Serializes Keychain writes with sign-out and invalidates older network results.
@MainActor
final class FixtureCredentialCoordinator {
    private let store = KeychainSessionCredentialStore(
        service: "homes.birb.foundationconsumers.benchysynthetic.fixture",
        account: "refresh"
    )
    private var generation = 0
    private var writes: [UUID: Task<Void, Error>] = [:]
    private var clearBarrier: Task<Void, Error>?

    func begin() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ operation: Int) -> Bool { operation == generation }

    func load() async throws -> RefreshCredential? { try await store.load() }

    func store(_ credential: RefreshCredential, for operation: Int) async throws {
        if let clearBarrier { _ = try? await clearBarrier.value }
        guard isCurrent(operation) else { return }
        let id = UUID()
        let write = Task { try await store.store(credential) }
        writes[id] = write
        defer { writes.removeValue(forKey: id) }
        try await write.value
    }

    func clear(for operation: Int) async throws {
        guard isCurrent(operation) else { return }
        let precedingClear = clearBarrier
        let precedingWrites = Array(writes.values)
        let barrier = Task {
            if let precedingClear { _ = try? await precedingClear.value }
            for write in precedingWrites { _ = try? await write.value }
            try await store.clear()
        }
        clearBarrier = barrier
        try await barrier.value
    }
}
