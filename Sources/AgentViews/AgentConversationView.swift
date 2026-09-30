import AgentPresentation
import SwiftUI

/// The first transcript and composer path for hosts that own messages and draft.
public struct AgentConversationView: View {
    private let messages: [AgentTranscriptMessage]
    @Binding private var draft: String
    private let isSendEnabled: Bool
    private let status: AgentConversationStatus
    private let onSend: @MainActor (String) -> Void
    private let onStop: @MainActor () -> Void
    private let onRetry: @MainActor () -> Void

    public init(
        messages: [AgentTranscriptMessage],
        draft: Binding<String>,
        isSendEnabled: Bool = true,
        status: AgentConversationStatus = AgentConversationStatus(),
        onStop: @escaping @MainActor () -> Void = {},
        onRetry: @escaping @MainActor () -> Void = {},
        onSend: @escaping @MainActor (String) -> Void
    ) {
        self.messages = messages
        self._draft = draft
        self.isSendEnabled = isSendEnabled
        self.status = status
        self.onStop = onStop
        self.onRetry = onRetry
        self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 0) {
            AgentStatusView(status: status, onStop: onStop, onRetry: onRetry)
            AgentTranscriptView(messages: messages)
            Divider()
            AgentComposerView(
                draft: $draft,
                isEnabled: isSendEnabled && status.canSend,
                onSend: onSend
            )
        }
    }
}
