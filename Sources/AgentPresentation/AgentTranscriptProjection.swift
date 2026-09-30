import AGUICore
import Foundation

/// An immutable, display-only copy of one host-observed message state.
/// It never retains SDK messages, raw events, tool arguments, metadata, or media.
public struct AgentTranscriptProjection: Sendable, Equatable {
    public static let maximumMessages = 100
    public static let maximumTextBytes = 1_048_576
    public static let maximumIdentifierBytes = 256
    public static let maximumSourceMessages = 1_000
    public static let maximumInspectedTextBytes = 2_097_152

    public enum ProjectionError: Error, Sendable, Equatable {
        case sourceMessageLimit
        case inspectionLimit
    }

    public enum OmissionReason: Sendable, Hashable {
        case unsupportedContent
        case invalidIdentifier
        case duplicateIdentifier
        case messageLimit
        case textLimit
    }

    /// Counts are aggregate so omitted message identifiers and content cannot reach UI state.
    public struct Omission: Sendable, Equatable {
        public let reason: OmissionReason
        public let count: Int

        public init(reason: OmissionReason, count: Int) {
            self.reason = reason
            self.count = count
        }
    }

    public let messages: [AgentTranscriptMessage]
    public let omissions: [Omission]

    /// The host passes decoded messages from its AG-UI observation, such as
    /// `AgentState.messages` or `MessagesSnapshotEvent.messages`. SDK decoding and
    /// reduction remain upstream of this presentation boundary.
    public init(messages source: [any Message]) throws {
        // The count is available without visiting any source message. Reject giant
        // decoded snapshots before reading IDs, roles, or content.
        guard source.count <= Self.maximumSourceMessages else {
            throw ProjectionError.sourceMessageLimit
        }
        var displayed: [AgentTranscriptMessage] = []
        var seenIDs: Set<String> = []
        var usedBytes = 0
        var inspectedBytes = 0
        var counts: [OmissionReason: Int] = [:]

        for message in source {
            let id = message.id
            guard !id.isEmpty,
                  id.utf8.prefix(Self.maximumIdentifierBytes + 1).count <= Self.maximumIdentifierBytes else {
                counts[.invalidIdentifier, default: 0] += 1
                continue
            }
            guard !seenIDs.contains(id) else {
                counts[.duplicateIdentifier, default: 0] += 1
                continue
            }

            let role: AgentTranscriptMessage.Role
            let content: String
            if let user = message as? UserMessage, user.contentParts == nil,
               let text = user.content {
                role = .user
                content = text
            } else if let assistant = message as? AssistantMessage,
                      let text = assistant.content {
                role = .assistant
                content = text
            } else {
                counts[.unsupportedContent, default: 0] += 1
                continue
            }

            guard displayed.count < Self.maximumMessages else {
                counts[.messageLimit, default: 0] += 1
                continue
            }
            let displayRemaining = Self.maximumTextBytes - usedBytes
            let inspectionRemaining = Self.maximumInspectedTextBytes - inspectedBytes
            // Inspect only enough UTF-8 bytes to decide both limits. In
            // particular, a giant String is never counted end to end.
            let inspected = content.utf8.prefix(min(displayRemaining, inspectionRemaining) + 1).count
            guard inspected <= inspectionRemaining else {
                throw ProjectionError.inspectionLimit
            }
            inspectedBytes += inspected
            guard inspected <= displayRemaining else {
                counts[.textLimit, default: 0] += 1
                continue
            }
            seenIDs.insert(id)
            displayed.append(AgentTranscriptMessage(id: id, role: role, text: content))
            usedBytes += inspected
        }

        self.messages = displayed
        let reasons: [OmissionReason] = [
            .unsupportedContent, .invalidIdentifier, .duplicateIdentifier,
            .messageLimit, .textLimit,
        ]
        self.omissions = reasons.compactMap { reason in
            guard let count = counts[reason] else { return nil }
            return Omission(reason: reason, count: count)
        }
    }
}

/// The UI-facing delivery point. Failed observations leave the last accepted
/// projection available and mark it stale until a new observation is accepted.
@MainActor
public final class AgentTranscriptDelivery {
    public enum Status: Sendable, Equatable {
        case live
        case stale
        case unavailable
    }

    public private(set) var projection: AgentTranscriptProjection?
    public private(set) var status: Status = .unavailable

    public init() {}

    public func accept(_ projection: AgentTranscriptProjection) {
        self.projection = projection
        status = .live
    }

    /// Projects a complete decoded observation. An input-budget failure marks
    /// delivery stale (or unavailable) while retaining the last accepted value.
    @discardableResult
    public func acceptObservedMessages(_ messages: [any Message]) -> Bool {
        do {
            accept(try AgentTranscriptProjection(messages: messages))
            return true
        } catch {
            observationFailed()
            return false
        }
    }

    public func observationFailed() {
        status = projection == nil ? .unavailable : .stale
    }
}
