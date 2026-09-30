import AgentPresentation
import SwiftUI

/// Renders host-owned plain text messages in the order supplied.
public struct AgentTranscriptView: View {
    public let messages: [AgentTranscriptMessage]

    public init(messages: [AgentTranscriptMessage]) {
        self.messages = messages
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { message in
                    HStack {
                        if message.role == .user { Spacer(minLength: 32) }
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(
                                message.role == .user
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .accessibilityIdentifier("agent-message-\(message.id)")
                        if message.role == .assistant { Spacer(minLength: 32) }
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("agent-transcript")
    }
}
