import AgentPresentation
import AgentViews
import AuthenticatedHTTP
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
    @State private var fixtureUsername = "Loading protected profile…"

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
                    Text("Protected fixture: \(fixtureUsername)")
                        .font(.caption)
                        .accessibilityIdentifier("ben-chy-protected-username")
                }
            }
            .task {
                do {
                    let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [ProtectedProfileProtocol.self]
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    let client = AuthenticatedHTTPClient(endpoint: endpoint, session: session)
                    let (data, response) = try await client.request(path: "profile", accessToken: "synthetic-host-token")
                    guard response.statusCode == 200 else { return }
                    fixtureUsername = try JSONDecoder().decode(ProtectedProfile.self, from: data).username
                } catch {
                    fixtureUsername = "Fixture unavailable"
                }
            }
        }
    }
}

private struct ProtectedProfile: Decodable { let username: String }

private final class ProtectedProfileProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let permitted = request.url?.absoluteString == "https://fixture.example.test/profile"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-host-token"
        let response = HTTPURLResponse(url: request.url!, statusCode: permitted ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: permitted ? Data(#"{"username":"fixture-alice"}"#.utf8) : Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
