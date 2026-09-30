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

    func testDelayedProtectedForbiddenRevokesAfterConcurrentRefreshCommits() async throws {
        let fixture = SessionFixture(forbiddenDelay: 0.2)
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let signOuts = RefreshRecorder()
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { _ in
                SessionRefreshResult(
                    accessToken: "access-new",
                    refreshCredential: RefreshCredential(value: "refresh-new")
                )
            },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        let forbidden = Task { try await coordinator.request(path: "forbidden") }
        while fixture.forbiddenRequestCount == 0 { await Task.yield() }
        _ = try await coordinator.request(path: "profile")
        let committed = try await store.load()
        XCTAssertEqual(committed, RefreshCredential(value: "refresh-new"))
        do {
            _ = try await forbidden.value
            XCTFail("Expected forbidden response")
        } catch let error as SessionServerError {
            XCTAssertEqual(error, SessionServerError(statusCode: 403, code: "access_forbidden"))
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

    func testStaleReplayUnauthorizedDoesNotRevokeNewerRefresh() async throws {
        let fixture = SessionFixture(staleReplayDelay: 0.2)
        let store = InMemorySessionCredentialStore()
        try await store.store(RefreshCredential(value: "refresh-old"))
        let refreshes = RefreshRecorder()
        let signOuts = RefreshRecorder()
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { credential in
                let attempt = await refreshes.record(credential)
                return SessionRefreshResult(
                    accessToken: attempt == 1 ? "access-new" : "access-latest",
                    refreshCredential: RefreshCredential(value: attempt == 1 ? "refresh-new" : "refresh-latest")
                )
            },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        let staleRequest = Task { try await coordinator.request(path: "stale-replay") }
        while fixture.staleReplayRequestCount == 0 { await Task.yield() }
        _ = try await coordinator.request(path: "rotate")
        let storedAfterSecondRefresh = try await store.load()
        XCTAssertEqual(storedAfterSecondRefresh, RefreshCredential(value: "refresh-latest"))
        do {
            _ = try await staleRequest.value
            XCTFail("Expected stale replay failure")
        } catch let error as SessionServerError {
            XCTAssertEqual(error, SessionServerError(statusCode: 401, code: "invalid_session"))
        }
        let (data, _) = try await coordinator.request(path: "latest")
        let stored = try await store.load()
        let refreshCount = await refreshes.count
        let signOutCount = await signOuts.count
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(stored, RefreshCredential(value: "refresh-latest"))
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(signOutCount, 0)
    }

    func testRevocationWaitsForCredentialWriteAndSignsOutWhenClearFails() async throws {
        for clearFails in [false, true] {
            let fixture = SessionFixture()
            let gate = StoreGate()
            let store = GatedCredentialStore(gate: gate, clearFails: clearFails)
            let signOuts = RefreshRecorder()
            let coordinator = try makeCoordinator(
                fixture: fixture, store: store,
                refresh: { _ in
                    SessionRefreshResult(
                        accessToken: "access-new",
                        refreshCredential: RefreshCredential(value: "refresh-new")
                    )
                },
                onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
            )
            let refreshing = Task { try await coordinator.request(path: "profile") }
            await gate.waitUntilEntered()
            let forbidden = Task { try await coordinator.request(path: "forbidden") }
            while fixture.forbiddenRequestCount == 0 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(30))
            let clearCountBeforeRelease = await store.clearCount
            XCTAssertEqual(clearCountBeforeRelease, 0)
            await gate.release()
            _ = try? await refreshing.value
            do {
                _ = try await forbidden.value
                XCTFail("Expected revocation error")
            } catch CredentialStoreFailure.clearFailed where clearFails {
                // Clear failure is surfaced after the in-memory session is fenced.
            } catch let error as SessionServerError where !clearFails {
                XCTAssertEqual(error, SessionServerError(statusCode: 403, code: "access_forbidden"))
            }
            let stored = try await store.load()
            let clearCount = await store.clearCount
            let signOutCount = await signOuts.count
            XCTAssertEqual(clearCount, 1)
            XCTAssertEqual(signOutCount, 1)
            XCTAssertEqual(stored, clearFails ? RefreshCredential(value: "refresh-new") : nil)
            do {
                _ = try await coordinator.request(path: "profile")
                XCTFail("Expected signed-out state")
            } catch SessionCoordinatorError.missingAccessToken {}
        }
    }

    func testRevocationFencesRequestsWhileCredentialClearIsPending() async throws {
        let fixture = SessionFixture()
        let gate = StoreGate()
        let store = BlockingClearStore(gate: gate)
        let signOuts = RefreshRecorder()
        let coordinator = try makeCoordinator(
            fixture: fixture, store: store,
            refresh: { _ in throw SessionServerError(statusCode: 500, code: "unexpected") },
            onSignOut: { _ = await signOuts.record(RefreshCredential(value: "hook")) }
        )
        let forbidden = Task { try await coordinator.request(path: "forbidden") }
        await gate.waitUntilEntered()
        do {
            _ = try await coordinator.request(path: "profile")
            XCTFail("Expected fenced session")
        } catch SessionCoordinatorError.missingAccessToken {}
        let signOutsBeforeClear = await signOuts.count
        XCTAssertEqual(signOutsBeforeClear, 0)
        await gate.release()
        do {
            _ = try await forbidden.value
            XCTFail("Expected forbidden response")
        } catch let error as SessionServerError {
            XCTAssertEqual(error, SessionServerError(statusCode: 403, code: "access_forbidden"))
        }
        let stored = try await store.load()
        let signOutCount = await signOuts.count
        XCTAssertNil(stored)
        XCTAssertEqual(signOutCount, 1)
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
        store: any SessionCredentialStore,
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

private enum CredentialStoreFailure: Error {
    case clearFailed
}

private actor StoreGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor GatedCredentialStore: SessionCredentialStore {
    private var credential: RefreshCredential? = RefreshCredential(value: "refresh-old")
    private let gate: StoreGate
    private let clearFails: Bool
    private(set) var clearCount = 0

    init(gate: StoreGate, clearFails: Bool) {
        self.gate = gate
        self.clearFails = clearFails
    }

    func load() async throws -> RefreshCredential? { credential }

    func store(_ credential: RefreshCredential) async throws {
        await gate.pause()
        self.credential = credential
    }

    func clear() async throws {
        clearCount += 1
        if clearFails { throw CredentialStoreFailure.clearFailed }
        credential = nil
    }
}

private actor BlockingClearStore: SessionCredentialStore {
    private var credential: RefreshCredential? = RefreshCredential(value: "refresh-old")
    private let gate: StoreGate

    init(gate: StoreGate) { self.gate = gate }
    func load() async throws -> RefreshCredential? { credential }
    func store(_ credential: RefreshCredential) async throws { self.credential = credential }
    func clear() async throws {
        await gate.pause()
        credential = nil
    }
}

private final class SessionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var refreshCount = 0
    private var forbiddenCount = 0
    private var staleReplayCount = 0
    let initialStatus: Int
    let initialCode: String
    let replayStatus: Int
    let replayCode: String
    let forbiddenDelay: TimeInterval
    let staleReplayDelay: TimeInterval

    init(initialStatus: Int = 401, initialCode: String = "invalid_session",
         replayStatus: Int = 200, replayCode: String = "", forbiddenDelay: TimeInterval = 0,
         staleReplayDelay: TimeInterval = 0) {
        self.initialStatus = initialStatus
        self.initialCode = initialCode
        self.replayStatus = replayStatus
        self.replayCode = replayCode
        self.forbiddenDelay = forbiddenDelay
        self.staleReplayDelay = staleReplayDelay
    }

    var requestCount: Int { lock.withLock { count } }
    var refreshRequestCount: Int { lock.withLock { refreshCount } }
    var forbiddenRequestCount: Int { lock.withLock { forbiddenCount } }
    var staleReplayRequestCount: Int { lock.withLock { staleReplayCount } }
    func increment() { lock.withLock { count += 1 } }
    func incrementRefresh() { lock.withLock { refreshCount += 1 } }
    func incrementForbidden() { lock.withLock { forbiddenCount += 1 } }
    func incrementStaleReplay() { lock.withLock { staleReplayCount += 1 } }
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
        if request.url?.lastPathComponent == "forbidden" {
            fixture.incrementForbidden()
            let delivery = DelayedProtocolDelivery(source: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.forbiddenDelay) {
                delivery.send(statusCode: 403, code: "access_forbidden")
            }
            return
        }
        if request.url?.lastPathComponent == "stale-replay"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer access-new" {
            fixture.incrementStaleReplay()
            let delivery = DelayedProtocolDelivery(source: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.staleReplayDelay) {
                delivery.send(statusCode: 401, code: "invalid_session")
            }
            return
        }
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
        if request.url?.lastPathComponent == "rotate" {
            let latest = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-latest"
            send(statusCode: latest ? 200 : 401, code: latest ? nil : "invalid_session")
            return
        }
        if request.url?.lastPathComponent == "latest" {
            let latest = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-latest"
            send(statusCode: latest ? 200 : 401, code: latest ? nil : "invalid_session")
            return
        }
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

    private func send(statusCode: Int, code: String?) {
        let body = code.map { Data(#"{"code":"\#($0)"}"#.utf8) } ?? Data("ok".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct DelayedProtocolDelivery: @unchecked Sendable {
    let source: SessionFixtureProtocol

    func send(statusCode: Int, code: String) {
        let body = Data(#"{"code":"\#(code)"}"#.utf8)
        let response = HTTPURLResponse(url: source.request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
        source.client?.urlProtocol(source, didLoad: body)
        source.client?.urlProtocolDidFinishLoading(source)
    }
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionFixture?
    var fixture: SessionFixture? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
