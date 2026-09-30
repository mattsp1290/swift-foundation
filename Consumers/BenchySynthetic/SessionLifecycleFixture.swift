import AuthenticatedHTTP
import Foundation
import SessionCredentials

/// Exercises the package's coordinator against a fully in-process transport.
enum SessionLifecycleFixture {
    static func run() async throws -> String {
        let store = KeychainSessionCredentialStore(
            service: "homes.birb.foundationconsumers.benchysynthetic.lifecycle", account: "refresh"
        )
        try await store.clear()
        try await store.store(RefreshCredential(value: "lifecycle-refresh-initial"))
        guard try await store.load()?.value == "lifecycle-refresh-initial" else {
            throw FixtureLifecycleError.invalidResult
        }
        SessionLifecycleProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionLifecycleProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://session.fixture.test/")!)
        let signOuts = SignOutCounter()
        let coordinator = SessionCoordinator(
            client: AuthenticatedHTTPClient(endpoint: endpoint, session: session),
            credentialStore: store,
            accessToken: "lifecycle-access-expired",
            refresh: { credential in
                var request = URLRequest(url: try endpoint.url(for: "refresh"))
                request.httpMethod = "POST"
                request.setValue(credential.value, forHTTPHeaderField: "X-Fixture-Refresh")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw FixtureLifecycleError.invalidResult
                }
                guard response.statusCode == 200 else {
                    throw SessionServerError(response: response, data: data)
                }
                let exchange = try JSONDecoder().decode(LifecycleExchange.self, from: data)
                return SessionRefreshResult(
                    accessToken: exchange.accessToken,
                    refreshCredential: RefreshCredential(value: exchange.refreshCredential)
                )
            },
            onSignOut: { await signOuts.record() }
        )
        async let first = coordinator.request(path: "profile")
        async let second = coordinator.request(path: "profile")
        let (firstData, _) = try await first
        let (secondData, _) = try await second
        let firstName = try JSONDecoder().decode(LifecycleProfile.self, from: firstData).username
        let secondName = try JSONDecoder().decode(LifecycleProfile.self, from: secondData).username
        guard firstName == "fixture-alice", secondName == "fixture-alice",
              SessionLifecycleProtocol.invalidSessionCount == 2,
              SessionLifecycleProtocol.refreshCount == 1,
              SessionLifecycleProtocol.replayCount == 2,
              try await store.load()?.value == "lifecycle-refresh-replaced" else {
            throw FixtureLifecycleError.invalidResult
        }
        do {
            _ = try await coordinator.request(path: "revoke")
            throw FixtureLifecycleError.invalidResult
        } catch let error as SessionServerError {
            guard error == SessionServerError(statusCode: 403, code: "access_forbidden") else {
                throw error
            }
        }
        guard try await store.load() == nil, await signOuts.count == 1 else {
            throw FixtureLifecycleError.invalidResult
        }
        return "fixture-alice; Keychain round trip; two 401s; one refresh; two replays; revocation signed out"
    }
}

private enum FixtureLifecycleError: Error { case invalidResult }
private struct LifecycleExchange: Decodable {
    let accessToken: String
    let refreshCredential: String
}
private struct LifecycleProfile: Decodable { let username: String }
private actor SignOutCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class SessionLifecycleProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var invalidSessions = 0
    nonisolated(unsafe) private static var refreshes = 0
    nonisolated(unsafe) private static var replays = 0
    nonisolated(unsafe) private static var pendingExpired: [SessionLifecycleProtocol] = []

    static var invalidSessionCount: Int { lock.withLock { invalidSessions } }
    static var refreshCount: Int { lock.withLock { refreshes } }
    static var replayCount: Int { lock.withLock { replays } }
    static func reset() { lock.withLock { invalidSessions = 0; refreshes = 0; replays = 0; pendingExpired = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let status: Int
        let body: String
        switch request.url?.path {
        case "/refresh":
            Self.lock.withLock { Self.refreshes += 1 }
            if request.value(forHTTPHeaderField: "X-Fixture-Refresh") == "lifecycle-refresh-initial" {
                status = 200
                body = #"{"accessToken":"lifecycle-access-current","refreshCredential":"lifecycle-refresh-replaced"}"#
            } else {
                status = 401
                body = #"{"code":"invalid_session"}"#
            }
        case "/profile" where authorization == "Bearer lifecycle-access-expired":
            let ready = Self.lock.withLock { () -> [SessionLifecycleProtocol] in
                Self.pendingExpired.append(self)
                guard Self.pendingExpired.count == 2 else { return [] }
                let pair = Self.pendingExpired
                Self.pendingExpired = []
                Self.invalidSessions += 2
                return pair
            }
            for item in ready {
                item.send(status: 401, body: #"{"code":"invalid_session"}"#)
            }
            return
        case "/profile" where authorization == "Bearer lifecycle-access-current":
            Self.lock.withLock { Self.replays += 1 }
            status = 200
            body = #"{"username":"fixture-alice"}"#
        case "/revoke":
            status = 403
            body = #"{"code":"access_forbidden"}"#
        default:
            status = 401
            body = #"{"code":"invalid_session"}"#
        }
        send(status: status, body: body)
    }

    private func send(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.pendingExpired.removeAll { $0 === self } }
    }
}
