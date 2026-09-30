import AgentPresentation
import AgentViews
import SwiftUI

@main
struct CatalogApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Conversation catalog").font(.title.bold())
                        Text("Two independent conversations with host controlled state.")
                        CatalogConversation(title: "Connected", initialRole: .assistant)
                        CatalogConversation(title: "Second instance", initialRole: .user)
                        FoundationRevision()
                    }
                    .padding()
                }
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
            Button("Mark failed") { run = .failed }
                .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
