import AgentPresentation
import AgentViews
import SessionCredentials
import SwiftUI
#if os(macOS)
import Darwin
#endif

@main
struct CatalogApp: App {
    @StateObject private var sessionFixture = CatalogSessionFixture()
    init() {
        logFoundationRevision()
        #if os(macOS)
        if ProcessInfo.processInfo.environment["FOUNDATION_CATALOG_KEYCHAIN_SMOKE"] == "1" {
            Task { @MainActor in
                let fixture = CatalogSessionFixture()
                await fixture.roundTrip()
                print("Catalog Keychain smoke result: \(fixture.result)")
                exit(fixture.result == "Keychain store, load, clear passed" ? 0 : 1)
            }
        }
        if ProcessInfo.processInfo.environment["FOUNDATION_CATALOG_SESSION_SMOKE"] == "1" {
            Task {
                do {
                    print("Catalog session smoke result: \(try await CatalogRequestFixture.run())")
                    exit(0)
                } catch {
                    print("Catalog session smoke failed")
                    exit(1)
                }
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Conversation catalog").font(.title.bold())
                        Text("Two independent conversations with host controlled state.")
                        CatalogConversation(title: "Connected", initialRole: .assistant)
                        CatalogConversation(title: "Second instance", initialRole: .user)
                        Button("Check catalog Keychain") { Task { await sessionFixture.roundTrip() } }
                            .accessibilityIdentifier("catalog-keychain-check")
                        Text(sessionFixture.result).accessibilityIdentifier("catalog-keychain-result")
                        Button("Run catalog protected session") {
                            Task { await sessionFixture.runRequestJourney() }
                        }
                        .accessibilityIdentifier("catalog-session-run")
                        Text(sessionFixture.requestResult)
                            .accessibilityIdentifier("catalog-session-result")
                        FoundationRevision()
                    }
                    .padding()
                }
                .accessibilityIdentifier("catalog-scroll")
            }
        }
    }
}

private struct CatalogConversation: View {
    let title: String
    let initialRole: AgentTranscriptMessage.Role
    @State private var draft = ""
    @State private var messages: [AgentTranscriptMessage] = []
    @State private var run: AgentConversationStatus.Run = .idle
    @State private var connection: AgentConversationStatus.Connection = .connected
    @State private var transcript: AgentTranscriptDelivery.Status = .live
    @State private var count = 0
    @State private var sendCallbacks = 0
    @State private var stopCallbacks = 0
    @State private var retryCallbacks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))]) {
                Button("Stale") { transcript = .stale }
                Button("Unavailable") { transcript = .unavailable }
                Button("Live") { transcript = .live }
                Button("Disconnect") {
                    connection = connection == .connected ? .disconnected : .connected
                }
                Button("Mark failed") { run = .failed }
            }
            .buttonStyle(.bordered)
            AgentConversationView(
                messages: messages.isEmpty
                    ? [AgentTranscriptMessage(id: "seed", role: initialRole, text: "Selectable sample text")]
                    : messages,
                draft: $draft,
                status: AgentConversationStatus(
                    connection: connection,
                    run: run,
                    transcript: transcript,
                    error: run == .failed ? "Sample response failed" : nil,
                    omittedMessageCount: transcript == .stale ? 2 : 0
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
                    messages.append(AgentTranscriptMessage(id: "user-\(count)", role: .user, text: text))
                    run = .pending
                }
            )
            .frame(minHeight: 180, idealHeight: 260)
            Text("Callbacks: send \(sendCallbacks), stop \(stopCallbacks), retry \(retryCallbacks)")
                .font(.caption)
                .accessibilityIdentifier("catalog-callback-counts-\(title)")
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
