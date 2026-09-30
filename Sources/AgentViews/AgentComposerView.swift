import SwiftUI

/// A host-controlled plain text composer. A valid submission clears the binding
/// before calling `onSend`, so a second action cannot resend the same draft.
public struct AgentComposerView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var draft: String
    private let isEnabled: Bool
    private let onSend: @MainActor (String) -> Void

    public init(
        draft: Binding<String>,
        isEnabled: Bool = true,
        onSend: @escaping @MainActor (String) -> Void
    ) {
        self._draft = draft
        self.isEnabled = isEnabled
        self.onSend = onSend
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { editor; sendButton }
            } else {
                HStack(alignment: .bottom, spacing: 8) { editor; sendButton }
            }
        }
        .padding()
    }

    private var editor: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEnabled)
            .accessibilityLabel("Message draft")
            .accessibilityHint("Enter multiple lines, then choose Send")
            .accessibilityIdentifier("agent-composer-draft")
    }

    private var sendButton: some View {
        Button("Send", action: send)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!AgentComposerSubmission.canSend(draft, isEnabled: isEnabled))
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("agent-composer-send")
    }

    private func send() {
        guard let text = AgentComposerSubmission.takeText(from: &draft, isEnabled: isEnabled) else {
            return
        }
        onSend(text)
    }
}
