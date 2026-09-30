import SwiftUI

/// A host-controlled plain text composer. A valid submission clears the binding
/// before calling `onSend`, so a second action cannot resend the same draft.
public struct AgentComposerView: View {
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .accessibilityIdentifier("agent-composer-draft")

            Button("Send", action: send)
                .disabled(!AgentComposerSubmission.canSend(draft, isEnabled: isEnabled))
                .accessibilityIdentifier("agent-composer-send")
        }
        .padding()
    }

    private func send() {
        guard let text = AgentComposerSubmission.takeText(from: &draft, isEnabled: isEnabled) else {
            return
        }
        onSend(text)
    }
}
