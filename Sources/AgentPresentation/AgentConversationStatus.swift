/// Display state supplied by the host. This package never infers transport state.
public struct AgentConversationStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connected
        case connecting
        case disconnected
    }

    public enum Run: Sendable, Equatable {
        case idle
        case pending
        case failed
    }

    public let connection: Connection
    public let run: Run
    public let transcript: AgentTranscriptDelivery.Status
    /// A host approved, plain text explanation. Do not pass secrets or raw errors.
    public let error: String?
    public let omittedMessageCount: Int

    public init(
        connection: Connection = .connected,
        run: Run = .idle,
        transcript: AgentTranscriptDelivery.Status = .live,
        error: String? = nil,
        omittedMessageCount: Int = 0
    ) {
        self.connection = connection
        self.run = run
        self.transcript = transcript
        self.error = error
        self.omittedMessageCount = max(0, omittedMessageCount)
    }

    public var canSend: Bool { connection == .connected && run != .pending }
    public var canStop: Bool { run == .pending }
    public var canRetry: Bool { run == .failed && connection == .connected }
}
