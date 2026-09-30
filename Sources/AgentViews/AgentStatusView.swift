import AgentPresentation
import SwiftUI

/// Visible, accessible state and actions for a host controlled conversation.
public struct AgentStatusView: View {
    @State private var stopConsumed = false
    @State private var retryConsumed = false
    public let status: AgentConversationStatus
    private let onStop: @MainActor () -> Void
    private let onRetry: @MainActor () -> Void

    public init(
        status: AgentConversationStatus,
        onStop: @escaping @MainActor () -> Void = {},
        onRetry: @escaping @MainActor () -> Void = {}
    ) {
        self.status = status
        self.onStop = onStop
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connectionText)
                Spacer(minLength: 8)
                if status.canStop {
                    Button("Stop") {
                        guard !stopConsumed else { return }
                        stopConsumed = true
                        onStop()
                    }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(stopConsumed)
                        .accessibilityIdentifier("agent-stop")
                }
                if status.canRetry {
                    Button("Retry") {
                        guard !retryConsumed else { return }
                        retryConsumed = true
                        onRetry()
                    }
                        .disabled(retryConsumed)
                        .accessibilityIdentifier("agent-retry")
                }
            }
            if status.run == .pending { Text("Response pending") }
            if status.transcript == .stale { Text("Transcript may be out of date") }
            if status.transcript == .unavailable { Text("Live transcript unavailable") }
            if status.omittedMessageCount > 0 {
                Text("\(status.omittedMessageCount) messages omitted")
            }
            if let error = status.error, !error.isEmpty { Text(error) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-status")
        .onChange(of: status.run) { _ in
            stopConsumed = false
            retryConsumed = false
        }
    }

    private var connectionText: String {
        switch status.connection {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        }
    }
}
