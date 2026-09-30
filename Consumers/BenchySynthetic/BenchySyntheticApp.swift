import AgentPresentation
import AgentViews
import AuthenticatedHTTP
import SessionCredentials
import SwiftUI
#if os(macOS)
import Darwin
#endif

@main
struct BenchySyntheticApp: App {
    init() {
        logFoundationRevision()
        #if os(macOS)
        if let action = ProcessInfo.processInfo.environment["FOUNDATION_FIXTURE_SMOKE_ACTION"] {
            Task { @MainActor in
                do {
                    let result = try await (action == "session"
                        ? SessionLifecycleFixture.run() : FixtureSmoke.run(action: action))
                    print("Fixture smoke result: \(result)")
                    exit(0)
                } catch {
                    print("Fixture smoke failed")
                    exit(1)
                }
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            BenchySyntheticHost()
        }
    }
}

private struct BenchySyntheticHost: View {
    @State private var draft = ""
    @State private var messages = [
        AgentTranscriptMessage(id: "welcome", role: .assistant, text: "Synthetic Benchy host ready. Ask a plain text question.")
    ]
    @State private var run: AgentConversationStatus.Run = .idle
    @State private var connected = true
    @State private var count = 0
    @State private var sendCallbacks = 0
    @State private var stopCallbacks = 0
    @State private var retryCallbacks = 0
    @State private var fixtureUsername = "Signed out"
    @State private var sessionLifecycleOutcome = "Session lifecycle unchecked"
    @State private var delayedLoginOutcome = "Waiting"
    @State private var credentialCoordinator = FixtureCredentialCoordinator()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                AgentConversationView(
                    messages: messages,
                    draft: $draft,
                    status: AgentConversationStatus(
                        connection: connected ? .connected : .disconnected,
                        run: run,
                        error: run == .failed ? "Synthetic request failed. Retry is available." : nil
                    ),
                    onStop: {
                        stopCallbacks += 1
                        run = .idle
                    },
                    onRetry: {
                        retryCallbacks += 1
                        run = .pending
                    },
                    onSend: { text in
                        sendCallbacks += 1
                        count += 1
                        messages.append(AgentTranscriptMessage(id: "question-\(count)", role: .user, text: text))
                        run = .pending
                    }
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))]) {
                    Button("Complete response") {
                        count += 1
                        messages.append(AgentTranscriptMessage(id: "answer-\(count)", role: .assistant, text: "Synthetic answer complete."))
                        run = .idle
                    }
                    Button("Fail response") { run = .failed }
                    Button(connected ? "Go offline" : "Reconnect") { connected.toggle() }
                    Menu("Fixture credentials") {
                        Button("Run session lifecycle") {
                            Task {
                                do { sessionLifecycleOutcome = try await SessionLifecycleFixture.run() }
                                catch { sessionLifecycleOutcome = "Session lifecycle failed" }
                            }
                        }
                        .accessibilityIdentifier("ben-chy-session-run")
                        Button("Replace fixture credential") {
                            Task { await replaceFixtureCredential() }
                        }
                        .accessibilityIdentifier("ben-chy-fixture-replace")
                        Button("Clear fixture credential") {
                            let operation = credentialCoordinator.begin()
                            fixtureUsername = "Signing out"
                            Task { await clearFixtureCredential(operation: operation) }
                        }
                        .accessibilityIdentifier("ben-chy-fixture-clear")
                        if ProcessInfo.processInfo.arguments.contains("-fixture-delay-login") {
                            Button("Release delayed login") {
                                ProtectedProfileProtocol.releaseDelayedLogin()
                            }
                            .accessibilityIdentifier("ben-chy-fixture-release-login")
                        }
                        if ProcessInfo.processInfo.arguments.contains("-fixture-delay-profile") {
                            Button("Release delayed profile") {
                                ProtectedProfileProtocol.releaseDelayedProfile()
                            }
                            .accessibilityIdentifier("ben-chy-fixture-release-profile")
                        }
                    }
                }
                .buttonStyle(.bordered)
                if sessionLifecycleOutcome != "Session lifecycle unchecked" {
                    Text(sessionLifecycleOutcome)
                        .font(.caption)
                        .accessibilityIdentifier("ben-chy-session-outcome")
                }
                Text("Callbacks: send \(sendCallbacks), stop \(stopCallbacks), retry \(retryCallbacks)")
                    .font(.caption)
                    .accessibilityIdentifier("ben-chy-callback-counts")
                if ProcessInfo.processInfo.arguments.contains("-fixture-delay-login") ||
                    ProcessInfo.processInfo.arguments.contains("-fixture-delay-profile") {
                    Text(delayedLoginOutcome)
                        .font(.caption)
                        .accessibilityIdentifier("ben-chy-delayed-login-outcome")
                }
                FoundationRevision().padding(.bottom, 6)
            }
            .navigationTitle("Benchy synthetic")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Log in to fixture") {
                        Task { await logInToFixture() }
                    }
                    .accessibilityIdentifier("ben-chy-fixture-login")
                }
                ToolbarItem(placement: .automatic) {
                    Text("Protected fixture: \(fixtureUsername)")
                        .font(.caption)
                        .accessibilityIdentifier("ben-chy-protected-username")
                }
            }
        }
        .task { await restoreFixtureSession() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FixtureLoginParked"))) { _ in
            delayedLoginOutcome = "Delayed login parked"
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FixtureProfileParked"))) { _ in
            delayedLoginOutcome = "Delayed profile parked"
        }
    }

    @MainActor
    private func logInToFixture() async {
        let operation = credentialCoordinator.begin()
        fixtureUsername = "Fixture login pending"
        do {
            let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProtectedProfileProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            var loginRequest = URLRequest(url: try endpoint.url(for: "login"))
            loginRequest.httpMethod = "POST"
            let (loginData, loginResponse) = try await session.data(for: loginRequest)
            guard credentialCoordinator.isCurrent(operation) else {
                delayedLoginOutcome = "Delayed login discarded"
                return
            }
            guard (loginResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
            let login = try JSONDecoder().decode(FixtureLogin.self, from: loginData)
            try await credentialCoordinator.store(RefreshCredential(value: login.refreshCredential), for: operation)
            guard credentialCoordinator.isCurrent(operation) else { return }
            try await showProtectedFixture(endpoint: endpoint, session: session, operation: operation)
        } catch {
            if credentialCoordinator.isCurrent(operation) { fixtureUsername = "Fixture unavailable" }
        }
    }

    @MainActor
    private func restoreFixtureSession() async {
        let operation = credentialCoordinator.begin()
        do {
            guard try await credentialCoordinator.load() != nil else { return }
            guard credentialCoordinator.isCurrent(operation) else { return }
            if ProcessInfo.processInfo.arguments.contains("-fixture-delay-profile") {
                fixtureUsername = "Fixture restore pending"
            }
            let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProtectedProfileProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            try await showProtectedFixture(endpoint: endpoint, session: session, operation: operation)
        } catch {
            if credentialCoordinator.isCurrent(operation) { fixtureUsername = "Fixture unavailable" }
        }
    }

    @MainActor
    private func replaceFixtureCredential() async {
        let operation = credentialCoordinator.begin()
        do {
            try await credentialCoordinator.store(RefreshCredential(value: "fixture-refresh-replacement"), for: operation)
            guard credentialCoordinator.isCurrent(operation) else { return }
            let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProtectedProfileProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            try await showProtectedFixture(endpoint: endpoint, session: session, operation: operation)
        } catch {
            if credentialCoordinator.isCurrent(operation) { fixtureUsername = "Fixture unavailable" }
        }
    }

    @MainActor
    private func clearFixtureCredential(operation: Int) async {
        do {
            try await credentialCoordinator.clear(for: operation)
            if credentialCoordinator.isCurrent(operation) { fixtureUsername = "Signed out" }
        } catch {
            if credentialCoordinator.isCurrent(operation) { fixtureUsername = "Fixture unavailable" }
        }
    }

    @MainActor
    private func showProtectedFixture(endpoint: APIEndpoint, session: URLSession, operation: Int) async throws {
        guard let refreshCredential = try await credentialCoordinator.load() else { throw FixtureError.unauthorized }
        guard credentialCoordinator.isCurrent(operation) else { return }
        var tokenRequest = URLRequest(url: try endpoint.url(for: "token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue(refreshCredential.value, forHTTPHeaderField: "X-Fixture-Refresh")
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        guard credentialCoordinator.isCurrent(operation) else { return }
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
        let accessToken = try JSONDecoder().decode(FixtureAccessToken.self, from: tokenData).value

        let client = AuthenticatedHTTPClient(endpoint: endpoint, session: session)
        let (profileData, profileResponse) = try await client.request(path: "profile", accessToken: accessToken)
        guard credentialCoordinator.isCurrent(operation) else {
            delayedLoginOutcome = "Delayed restore discarded"
            return
        }
        guard profileResponse.statusCode == 200 else { throw FixtureError.unauthorized }
        fixtureUsername = try JSONDecoder().decode(ProtectedProfile.self, from: profileData).username
    }
}

private struct ProtectedProfile: Decodable { let username: String }
private struct FixtureLogin: Decodable { let refreshCredential: String }
private struct FixtureAccessToken: Decodable { let value: String }
private enum FixtureError: Error { case unauthorized }

private final class ProtectedProfileProtocol: URLProtocol {
    private static let delayLock = NSLock()
    nonisolated(unsafe) private static var delayedLogin: ProtectedProfileProtocol?
    nonisolated(unsafe) private static var releaseRequested = false
    nonisolated(unsafe) private static var delayedProfile: (ProtectedProfileProtocol, Data)?
    nonisolated(unsafe) private static var profileReleaseRequested = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func releaseDelayedLogin() {
        delayLock.lock()
        releaseRequested = true
        let pending = delayedLogin
        delayedLogin = nil
        delayLock.unlock()
        pending?.send(Data(#"{"refreshCredential":"fixture-refresh-credential"}"#.utf8))
    }

    static func releaseDelayedProfile() {
        delayLock.lock()
        profileReleaseRequested = true
        let pending = delayedProfile
        delayedProfile = nil
        delayLock.unlock()
        if let pending { pending.0.send(pending.1) }
    }

    override func startLoading() {
        let path = request.url?.path
        let method = request.httpMethod
        if path == "/login" && method == "POST" && ProcessInfo.processInfo.arguments.contains("-fixture-delay-login") {
            Self.delayLock.lock()
            if !Self.releaseRequested {
                Self.delayedLogin = self
                Self.delayLock.unlock()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("FixtureLoginParked"), object: nil)
                }
                return
            }
            Self.delayLock.unlock()
        }
        let body: Data
        switch (path, method) {
        case ("/login", "POST"):
            body = Data(#"{"refreshCredential":"fixture-refresh-credential"}"#.utf8)
        case ("/token", "POST") where request.value(forHTTPHeaderField: "X-Fixture-Refresh") == "fixture-refresh-credential":
            body = Data(#"{"value":"fixture-access-token"}"#.utf8)
        case ("/token", "POST") where request.value(forHTTPHeaderField: "X-Fixture-Refresh") == "fixture-refresh-replacement":
            body = Data(#"{"value":"fixture-replacement-access-token"}"#.utf8)
        case ("/profile", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token":
            body = Data(#"{"username":"fixture-alice"}"#.utf8)
        case ("/profile", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-replacement-access-token":
            body = Data(#"{"username":"fixture-bob"}"#.utf8)
        default:
            body = Data()
        }
        if path == "/profile" && method == "GET" && ProcessInfo.processInfo.arguments.contains("-fixture-delay-profile") {
            Self.delayLock.lock()
            if !Self.profileReleaseRequested {
                Self.delayedProfile = (self, body)
                Self.delayLock.unlock()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("FixtureProfileParked"), object: nil)
                }
                return
            }
            Self.delayLock.unlock()
        }
        send(body)
    }

    private func send(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 401 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.delayLock.lock()
        if Self.delayedLogin === self { Self.delayedLogin = nil }
        if Self.delayedProfile?.0 === self { Self.delayedProfile = nil }
        Self.delayLock.unlock()
    }
}

#if os(macOS)
@MainActor
private enum FixtureSmoke {
    static func run(action: String) async throws -> String {
        let credentials = FixtureCredentialCoordinator()
        let operation = credentials.begin()
        if action == "clear" {
            try await credentials.clear(for: operation)
            return try await credentials.load() == nil ? "Signed out" : "unexpected credential"
        }
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtectedProfileProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        switch action {
        case "login":
            var request = URLRequest(url: try endpoint.url(for: "login"))
            request.httpMethod = "POST"
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
            let login = try JSONDecoder().decode(FixtureLogin.self, from: data)
            try await credentials.store(RefreshCredential(value: login.refreshCredential), for: operation)
        case "replace":
            try await credentials.store(RefreshCredential(value: "fixture-refresh-replacement"), for: operation)
        case "restore":
            break
        default:
            throw FixtureError.unauthorized
        }
        guard let refresh = try await credentials.load() else { return "Signed out" }
        var request = URLRequest(url: try endpoint.url(for: "token"))
        request.httpMethod = "POST"
        request.setValue(refresh.value, forHTTPHeaderField: "X-Fixture-Refresh")
        let (tokenData, tokenResponse) = try await session.data(for: request)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
        let accessToken = try JSONDecoder().decode(FixtureAccessToken.self, from: tokenData).value
        let client = AuthenticatedHTTPClient(endpoint: endpoint, session: session)
        let (profileData, profileResponse) = try await client.request(path: "profile", accessToken: accessToken)
        guard profileResponse.statusCode == 200 else { throw FixtureError.unauthorized }
        return try JSONDecoder().decode(ProtectedProfile.self, from: profileData).username
    }
}
#endif
