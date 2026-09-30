import Foundation

/// A display-only transcript item. The host supplies a stable identifier and order.
public struct AgentTranscriptMessage: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case user
        case assistant
    }

    public let id: String
    public let role: Role
    public let text: String

    public init(id: String, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
