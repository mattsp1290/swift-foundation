import Foundation

/// An opaque credential that a host may exchange for a new access token.
/// Access tokens and account details are intentionally outside this value.
public struct RefreshCredential: Sendable, Equatable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// Storage boundary for one refresh credential. Implementations may choose their own persistence.
public protocol SessionCredentialStore: Sendable {
    func load() async throws -> RefreshCredential?
    func store(_ credential: RefreshCredential) async throws
    func clear() async throws
}

/// Ephemeral storage useful to synthetic hosts and tests.
public actor InMemorySessionCredentialStore: SessionCredentialStore {
    private var credential: RefreshCredential?

    public init() {}

    public func load() async throws -> RefreshCredential? {
        credential
    }

    public func store(_ credential: RefreshCredential) async throws {
        self.credential = credential
    }

    public func clear() async throws {
        credential = nil
    }
}
