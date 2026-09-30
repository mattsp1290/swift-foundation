import Foundation

/// Consumes an enabled draft once, before the host callback runs.
enum AgentComposerSubmission {
    static func takeText(from draft: inout String, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        draft = ""
        return text
    }

    static func canSend(_ draft: String, isEnabled: Bool) -> Bool {
        isEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
