import AuthenticatedHTTP
import Foundation
import SessionCredentials

/// A Catalog-owned request journey against an in-process server fixture.
enum CatalogRequestFixture {
    static let passed = "Catalog protected login, refresh, replay, revocation passed"

    static func run() async throws -> String {
        let store = KeychainSessionCredentialStore(
            service: "homes.birb.foundationconsumers.catalog.request", account: "refresh"
        )
        try await store.clear()
        CatalogRequestProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://catalog.fixture.test/")!)

        var loginRequest = URLRequest(url: try endpoint.url(for: "login"))
        loginRequest.httpMethod = "POST"
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        guard (loginResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw CatalogRequestError.unexpectedResponse
        }
        let login = try JSONDecoder().decode(CatalogLogin.self, from: loginData)
        try await store.store(RefreshCredential(value: login.refreshCredential))
        guard try await store.load()?.value == "catalog-refresh-first" else {
            throw CatalogRequestError.unexpectedResponse
        }

        let signOuts = CatalogSignOuts()
        let coordinator = SessionCoordinator(
            client: AuthenticatedHTTPClient(endpoint: endpoint, session: session),
            credentialStore: store,
            accessToken: login.accessToken,
            refresh: { credential in
                var request = URLRequest(url: try endpoint.url(for: "renew"))
                request.httpMethod = "POST"
                request.setValue(credential.value, forHTTPHeaderField: "X-Catalog-Refresh")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw CatalogRequestError.unexpectedResponse
                }
                guard response.statusCode == 200 else {
                    throw SessionServerError(response: response, data: data)
                }
                let renewal = try JSONDecoder().decode(CatalogRenewal.self, from: data)
                return SessionRefreshResult(
                    accessToken: renewal.accessToken,
                    refreshCredential: RefreshCredential(value: renewal.refreshCredential)
                )
            },
            onSignOut: { await signOuts.record() }
        )
        let (data, _) = try await coordinator.request(path: "reader")
        let profile = try JSONDecoder().decode(CatalogReader.self, from: data)
        guard profile.name == "catalog-reader", CatalogRequestProtocol.expiredCount == 1,
              CatalogRequestProtocol.renewalCount == 1, CatalogRequestProtocol.replayCount == 1,
              try await store.load()?.value == "catalog-refresh-next" else {
            throw CatalogRequestError.unexpectedResponse
        }
        do {
            _ = try await coordinator.request(path: "withdraw")
            throw CatalogRequestError.unexpectedResponse
        } catch let error as SessionServerError {
            guard error == SessionServerError(statusCode: 403, code: "access_forbidden") else {
                throw error
            }
        }
        guard try await store.load() == nil, await signOuts.count == 1 else {
            throw CatalogRequestError.unexpectedResponse
        }
        return passed
    }
}

private enum CatalogRequestError: Error { case unexpectedResponse }
private struct CatalogLogin: Decodable {
    let accessToken: String
    let refreshCredential: String
}
private struct CatalogRenewal: Decodable {
    let accessToken: String
    let refreshCredential: String
}
private struct CatalogReader: Decodable { let name: String }
private actor CatalogSignOuts {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class CatalogRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var expired = 0
    nonisolated(unsafe) private static var renewals = 0
    nonisolated(unsafe) private static var replays = 0

    static var expiredCount: Int { lock.withLock { expired } }
    static var renewalCount: Int { lock.withLock { renewals } }
    static var replayCount: Int { lock.withLock { replays } }
    static func reset() { lock.withLock { expired = 0; renewals = 0; replays = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        let body: String
        switch (request.url?.path, request.httpMethod) {
        case ("/login", "POST"):
            status = 200
            body = #"{"accessToken":"catalog-access-old","refreshCredential":"catalog-refresh-first"}"#
        case ("/reader", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer catalog-access-old":
            Self.lock.withLock { Self.expired += 1 }
            status = 401
            body = #"{"code":"invalid_session"}"#
        case ("/renew", "POST") where request.value(forHTTPHeaderField: "X-Catalog-Refresh") == "catalog-refresh-first":
            Self.lock.withLock { Self.renewals += 1 }
            status = 200
            body = #"{"accessToken":"catalog-access-new","refreshCredential":"catalog-refresh-next"}"#
        case ("/reader", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer catalog-access-new":
            Self.lock.withLock { Self.replays += 1 }
            status = 200
            body = #"{"name":"catalog-reader"}"#
        case ("/withdraw", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer catalog-access-new":
            status = 403
            body = #"{"code":"access_forbidden"}"#
        default:
            status = 401
            body = #"{"code":"invalid_session"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
