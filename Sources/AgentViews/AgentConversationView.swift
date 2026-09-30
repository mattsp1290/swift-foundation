import AgentPresentation
import SwiftUI

/// The first transcript and composer path for hosts that own messages and draft.
public struct AgentConversationView: View {
    private let messages: [AgentTranscriptMessage]
    @Binding private var draft: String
    private let isSendEnabled: Bool
    private let onSend: @MainActor (String) -> Void

    public init(
        messages: [AgentTranscriptMessage],
        draft: Binding<String>,
        isSendEnabled: Bool = true,
        onSend: @escaping @MainActor (String) -> Void
    ) {
        self.messages = messages
        self._draft = draft
        self.isSendEnabled = isSendEnabled
        self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 0) {
            AgentTranscriptView(messages: messages)
            Divider()
            AgentComposerView(draft: $draft, isEnabled: isSendEnabled, onSend: onSend)
        }
    }
}
