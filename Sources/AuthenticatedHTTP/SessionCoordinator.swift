import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionCredentials

/// A server response whose machine-readable code can be handled without inspecting message text.
public struct SessionServerError: Error, Sendable, Equatable {
    public let statusCode: Int
    public let code: String?

    public init(statusCode: Int, code: String?) {
        self.statusCode = statusCode
        self.code = code
    }

    public init(response: HTTPURLResponse, data: Data) {
        self.statusCode = response.statusCode
        self.code = Self.code(in: data)
    }

    private static func code(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The host controls the wire format for refresh; protected responses use the
        // conventional top-level `code` field only.
        return object["code"] as? String
    }
}

/// A successful host-owned refresh exchange. The new credential is persisted before
/// the access token becomes available to protected requests.
public struct SessionRefreshResult: Sendable {
    public let accessToken: String
    public let refreshCredential: RefreshCredential

    public init(accessToken: String, refreshCredential: RefreshCredential) {
        self.accessToken = accessToken
        self.refreshCredential = refreshCredential
    }
}

public enum SessionCoordinatorError: Error, Sendable, Equatable {
    case missingAccessToken
    case missingRefreshCredential
    case refreshConflict
}

/// Owns one in-memory access token and coordinates protected requests for a host.
/// The host supplies the refresh HTTP operation, including its route and payload policy.
public actor SessionCoordinator {
    public typealias RefreshOperation = @Sendable (RefreshCredential) async throws -> SessionRefreshResult
    public typealias SignOutHook = @Sendable () async -> Void

    private let client: AuthenticatedHTTPClient
    private let credentialStore: any SessionCredentialStore
    private let refresh: RefreshOperation
    private let onSignOut: SignOutHook
    private var accessToken: String?
    private var tokenGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Error>?
    private var revocationTask: Task<Void, Error>?

    public init(
        client: AuthenticatedHTTPClient,
        credentialStore: any SessionCredentialStore,
        accessToken: String?,
        refresh: @escaping RefreshOperation,
        onSignOut: @escaping SignOutHook = {}
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.accessToken = accessToken
        self.refresh = refresh
        self.onSignOut = onSignOut
    }

    /// Requests a protected resource. Only a 401 `invalid_session` can trigger a
    /// refresh, and each request is replayed at most once.
    public func request(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let accessToken else { throw SessionCoordinatorError.missingAccessToken }
        let generation = tokenGeneration
        let (data, response) = try await client.request(
            path: path, method: method, accessToken: accessToken, body: body
        )
        let error = SessionServerError(response: response, data: data)
        if response.statusCode == 401 && error.code == "invalid_session" {
            try await refreshIfNeeded(for: generation)
            guard let replayToken = self.accessToken else {
                throw SessionCoordinatorError.missingAccessToken
            }
            let replayGeneration = tokenGeneration
            let (replayData, replayResponse) = try await client.request(
                path: path, method: method, accessToken: replayToken, body: body
            )
            let replayError = SessionServerError(response: replayResponse, data: replayData)
            if Self.isRevocation(replayError) {
                try await revokeSession(for: replayGeneration)
            }
            guard (200..<300).contains(replayResponse.statusCode) else {
                throw replayError
            }
            return (replayData, replayResponse)
        }
        if Self.isRevocation(error) {
            try await revokeSession(for: generation)
        }
        guard (200..<300).contains(response.statusCode) else { throw error }
        return (data, response)
    }

    private func refreshIfNeeded(for generation: UInt64) async throws {
        if tokenGeneration != generation { return }
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let task = Task { try await self.performRefresh(for: generation) }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh(for generation: UInt64) async throws {
        guard let credential = try await credentialStore.load() else {
            throw SessionCoordinatorError.missingRefreshCredential
        }
        do {
            let result = try await refresh(credential)
            guard tokenGeneration == generation else {
                throw SessionCoordinatorError.missingAccessToken
            }
            // A failed store must leave the existing access token in place.
            try await credentialStore.store(result.refreshCredential)
            if tokenGeneration != generation {
                // A protected response may have revoked the session while the
                // asynchronous store was replacing the credential.
                try await credentialStore.clear()
                throw SessionCoordinatorError.missingAccessToken
            }
            accessToken = result.accessToken
            tokenGeneration &+= 1
        } catch let error as SessionServerError {
            if error.statusCode == 409 && error.code == "refresh_conflict" {
                throw SessionCoordinatorError.refreshConflict
            }
            if Self.isRevocation(error) {
                try await revokeSession(for: generation)
            }
            throw error
        }
    }

    private static func isRevocation(_ error: SessionServerError) -> Bool {
        (error.statusCode == 401 && error.code == "invalid_session")
            || (error.statusCode == 403 && error.code == "access_forbidden")
    }

    private func revokeSession(for generation: UInt64) async throws {
        if tokenGeneration != generation { return }
        if let revocationTask {
            try await revocationTask.value
            return
        }
        let task = Task { try await self.performRevocation() }
        revocationTask = task
        do {
            try await task.value
            revocationTask = nil
        } catch {
            revocationTask = nil
            throw error
        }
    }

    private func performRevocation() async throws {
        try await credentialStore.clear()
        accessToken = nil
        tokenGeneration &+= 1
        await onSignOut()
    }
}
