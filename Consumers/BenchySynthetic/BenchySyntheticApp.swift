import AgentPresentation
import AgentViews
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
        }
    }
}
