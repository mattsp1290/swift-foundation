import AuthenticatedHTTP
import Foundation
import SessionCredentials
import XCTest

final class SessionCoordinatorTests: XCTestCase {
    func testConcurrentInvalidSessionsShareRefreshAndReplayOnce() async throws {
        let fixture = SessionFixture()
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let refreshes = RefreshRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionFixtureProtocol.self]
        let refreshSession = URLSession(configuration: configuration)
        defer { refreshSession.invalidateAndCancel() }
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/api/")!)
        let refreshClient = AuthenticatedHTTPClient(endpoint: endpoint, session: refreshSession)
        let coordinator = try makeCoordinator(fixture: fixture, store: store) { credential in
            await refreshes.record(credential)
            try await Task.sleep(for: .milliseconds(100))
            let (data, response) = try await refreshClient.request(
                path: "refresh", method: "POST", accessToken: credential.value
            )
            guard response.statusCode == 200 else {
                throw SessionServerError(response: response, data: data)
            }
            return SessionRefreshResult(
                accessToken: "access-new",
                refreshCredential: RefreshCredential(value: "refresh-new")
            )
        }

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let (data, _) = try await coordinator.request(path: "profile")
                    return String(decoding: data, as: UTF8.self)
                }
            }
            for try await result in group { XCTAssertEqual(result, "ok") }
        }

        let refreshCount = await refreshes.count
        let stored = try await store.load()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(stored, RefreshCredential(value: "refresh-new"))
        XCTAssertEqual(fixture.requestCount, 32)
        XCTAssertEqual(fixture.refreshRequestCount, 1)
    }

    func testReplayDoesNotRecursivelyRefresh() async throws {
        let fixture = SessionFixture(replayStatus: 401, replayCode: "invalid_session")
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let refreshes = RefreshRecorder()
        let signOuts = RefreshRecorder()
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { credential in
                await refreshes.record(credential)
                return SessionRefreshResult(
                    accessToken: "access-new",
                    refreshCredential: RefreshCredential(value: "refresh-new")
                )
            },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        do {
            _ = try await coordinator.request(path: "profile")
            XCTFail("Expected replay failure")
        } catch let error as SessionServerError {
            XCTAssertEqual(error, SessionServerError(statusCode: 401, code: "invalid_session"))
        }
        let refreshCount = await refreshes.count
        let signOutCount = await signOuts.count
        let stored = try await store.load()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(signOutCount, 1)
        XCTAssertNil(stored)
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testRefreshConflictPreservesCredentialAndAllowsNextAttempt() async throws {
        let fixture = SessionFixture()
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let attempts = RefreshRecorder()
        let coordinator = try makeCoordinator(fixture: fixture, store: store) { credential in
            let count = await attempts.record(credential)
            if count == 1 {
                throw SessionServerError(statusCode: 409, code: "refresh_conflict")
            }
            return SessionRefreshResult(
                accessToken: "access-new",
                refreshCredential: RefreshCredential(value: "refresh-new")
            )
        }
        do {
            _ = try await coordinator.request(path: "profile")
            XCTFail("Expected conflict")
        } catch SessionCoordinatorError.refreshConflict {}
        let preserved = try await store.load()
        XCTAssertEqual(preserved, RefreshCredential(value: "refresh-old"))
        _ = try await coordinator.request(path: "profile")
        let attemptCount = await attempts.count
        let replaced = try await store.load()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(replaced, RefreshCredential(value: "refresh-new"))
    }

    func testRevocationClearsCredentialAndCallsSignOutOnce() async throws {
        for failure in [
            SessionServerError(statusCode: 401, code: "invalid_session"),
            SessionServerError(statusCode: 403, code: "access_forbidden"),
        ] {
            let fixture = SessionFixture()
            let store = InMemorySessionCredentialStore()
            try await store.store(RefreshCredential(value: "refresh-old"))
            let signOuts = RefreshRecorder()
            let coordinator = try makeCoordinator(
                fixture: fixture, store: store,
                refresh: { _ in throw failure },
                onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
            )
            do {
                _ = try await coordinator.request(path: "profile")
                XCTFail("Expected revocation")
            } catch let error as SessionServerError {
                XCTAssertEqual(error, failure)
            }
            let stored = try await store.load()
            let signOutCount = await signOuts.count
            XCTAssertNil(stored)
            XCTAssertEqual(signOutCount, 1)
            do {
                _ = try await coordinator.request(path: "profile")
                XCTFail("Expected signed-out state")
            } catch SessionCoordinatorError.missingAccessToken {}
        }
    }

    func testConcurrentRevocationCallsSignOutOnce() async throws {
        let fixture = SessionFixture()
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let refreshes = RefreshRecorder()
        let signOuts = RefreshRecorder()
        let failure = SessionServerError(statusCode: 401, code: "invalid_session")
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { credential in
                await refreshes.record(credential)
                try await Task.sleep(for: .milliseconds(100))
                throw failure
            },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await coordinator.request(path: "profile")
                        XCTFail("Expected revocation")
                    } catch let error as SessionServerError {
                        XCTAssertEqual(error, failure)
                    } catch SessionCoordinatorError.missingAccessToken {
                        // A request may start after another request has signed out.
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
        let refreshCount = await refreshes.count
        let signOutCount = await signOuts.count
        let stored = try await store.load()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(signOutCount, 1)
        XCTAssertNil(stored)
    }

    func testConcurrentProtectedForbiddenRevokesWithoutRefreshing() async throws {
        let fixture = SessionFixture(initialStatus: 403, initialCode: "access_forbidden")
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let refreshes = RefreshRecorder()
        let signOuts = RefreshRecorder()
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { credential in
                await refreshes.record(credential)
                throw SessionServerError(statusCode: 500, code: "unexpected")
            },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await coordinator.request(path: "profile")
                        XCTFail("Expected forbidden response")
                    } catch let error as SessionServerError {
                        XCTAssertEqual(error, SessionServerError(statusCode: 403, code: "access_forbidden"))
                    } catch SessionCoordinatorError.missingAccessToken {
                        // A request may start after another request has signed out.
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
        let refreshCount = await refreshes.count
        let signOutCount = await signOuts.count
        let stored = try await store.load()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(signOutCount, 1)
        XCTAssertNil(stored)
    }

    func testTransientRefreshFailurePreservesCredential() async throws {
        for failure in [
            SessionServerError(statusCode: 503, code: "unavailable") as Error,
            URLError(.timedOut) as Error,
        ] {
            let fixture = SessionFixture()
            let store = InMemorySessionCredentialStore()
            try await store.store(RefreshCredential(value: "refresh-old"))
            let signOuts = RefreshRecorder()
            let coordinator = try makeCoordinator(
                fixture: fixture, store: store,
                refresh: { _ in throw failure },
                onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
            )
            do {
                _ = try await coordinator.request(path: "profile")
                XCTFail("Expected refresh failure")
            } catch {}
            let stored = try await store.load()
            let signOutCount = await signOuts.count
            XCTAssertEqual(stored, RefreshCredential(value: "refresh-old"))
            XCTAssertEqual(signOutCount, 0)
        }
    }

    func testProtectedServerErrorPropagatesCodeWithoutRefreshing() async throws {
        let fixture = SessionFixture(initialStatus: 403, initialCode: "access_forbidden")
        let store = InMemorySessionCredentialStore()
        let refreshes = RefreshRecorder()
        let coordinator = try makeCoordinator(fixture: fixture, store: store) { credential in
            await refreshes.record(credential)
            throw SessionServerError(statusCode: 500, code: "unexpected")
        }
        do {
            _ = try await coordinator.request(path: "profile")
            XCTFail("Expected server error")
        } catch let error as SessionServerError {
            XCTAssertEqual(error, SessionServerError(statusCode: 403, code: "access_forbidden"))
        }
        let refreshCount = await refreshes.count
        XCTAssertEqual(refreshCount, 0)
    }

    private func makeCoordinator(
        fixture: SessionFixture,
        store: InMemorySessionCredentialStore,
        refresh: @escaping SessionCoordinator.RefreshOperation,
        onSignOut: @escaping SessionCoordinator.SignOutHook = {}
    ) throws -> SessionCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        fixture.install()
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/api/")!)
        return SessionCoordinator(
            client: AuthenticatedHTTPClient(endpoint: endpoint, session: session),
            credentialStore: store, accessToken: "access-old",
            refresh: refresh, onSignOut: onSignOut
        )
    }
}

private actor RefreshRecorder {
    private(set) var count = 0
    @discardableResult func record(_ credential: RefreshCredential) -> Int {
        count += 1
        return count
    }
}

private final class SessionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var refreshCount = 0
    let initialStatus: Int
    let initialCode: String
    let replayStatus: Int
    let replayCode: String

    init(initialStatus: Int = 401, initialCode: String = "invalid_session",
         replayStatus: Int = 200, replayCode: String = "") {
        self.initialStatus = initialStatus
        self.initialCode = initialCode
        self.replayStatus = replayStatus
        self.replayCode = replayCode
    }

    var requestCount: Int { lock.withLock { count } }
    var refreshRequestCount: Int { lock.withLock { refreshCount } }
    func increment() { lock.withLock { count += 1 } }
    func incrementRefresh() { lock.withLock { refreshCount += 1 } }
    func install() { SessionFixtureProtocol.fixture = self }
}

private final class SessionFixtureProtocol: URLProtocol {
    private static let state = FixtureState()
    static var fixture: SessionFixture? {
        get { state.fixture }
        set { state.fixture = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else { return }
        if request.url?.lastPathComponent == "refresh" {
            fixture.incrementRefresh()
            let authorized = request.httpMethod == "POST"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer refresh-old"
            let status = authorized ? 200 : 401
            let body = authorized ? Data("refreshed".utf8) : Data(#"{"code":"invalid_session"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        fixture.increment()
        let replay = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-new"
        let status = replay ? fixture.replayStatus : fixture.initialStatus
        let code = replay ? fixture.replayCode : fixture.initialCode
        let body = status == 200 ? Data("ok".utf8) : Data(#"{"code":"\#(code)"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionFixture?
    var fixture: SessionFixture? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
