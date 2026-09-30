import AgentPresentation
import AgentViews
import AuthenticatedHTTP
import SessionCredentials
import SwiftUI

@main
struct BenchySyntheticApp: App {
    init() { logFoundationRevision() }

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
    @State private var credentialStore = InMemorySessionCredentialStore()

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
                }
                .buttonStyle(.bordered)
                Text("Callbacks: send \(sendCallbacks), stop \(stopCallbacks), retry \(retryCallbacks)")
                    .font(.caption)
                    .accessibilityIdentifier("ben-chy-callback-counts")
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
    }

    @MainActor
    private func logInToFixture() async {
        do {
            let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProtectedProfileProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            var loginRequest = URLRequest(url: try endpoint.url(for: "login"))
            loginRequest.httpMethod = "POST"
            let (loginData, loginResponse) = try await session.data(for: loginRequest)
            guard (loginResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
            let login = try JSONDecoder().decode(FixtureLogin.self, from: loginData)
            try await credentialStore.store(RefreshCredential(value: login.refreshCredential))

            guard let refreshCredential = try await credentialStore.load() else { throw FixtureError.unauthorized }
            var tokenRequest = URLRequest(url: try endpoint.url(for: "token"))
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue(refreshCredential.value, forHTTPHeaderField: "X-Fixture-Refresh")
            let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
            guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FixtureError.unauthorized }
            let accessToken = try JSONDecoder().decode(FixtureAccessToken.self, from: tokenData).value

            let client = AuthenticatedHTTPClient(endpoint: endpoint, session: session)
            let (profileData, profileResponse) = try await client.request(path: "profile", accessToken: accessToken)
            guard profileResponse.statusCode == 200 else { throw FixtureError.unauthorized }
            fixtureUsername = try JSONDecoder().decode(ProtectedProfile.self, from: profileData).username
        } catch {
            fixtureUsername = "Fixture unavailable"
        }
    }
}

private struct ProtectedProfile: Decodable { let username: String }
private struct FixtureLogin: Decodable { let refreshCredential: String }
private struct FixtureAccessToken: Decodable { let value: String }
private enum FixtureError: Error { case unauthorized }

private final class ProtectedProfileProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path
        let method = request.httpMethod
        let body: Data
        switch (path, method) {
        case ("/login", "POST"):
            body = Data(#"{"refreshCredential":"fixture-refresh-credential"}"#.utf8)
        case ("/token", "POST") where request.value(forHTTPHeaderField: "X-Fixture-Refresh") == "fixture-refresh-credential":
            body = Data(#"{"value":"fixture-access-token"}"#.utf8)
        case ("/profile", "GET") where request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token":
            body = Data(#"{"username":"fixture-alice"}"#.utf8)
        default:
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 401 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
