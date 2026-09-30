import AgentPresentation
import Testing

@Test func statusActionsFollowHostState() {
    let idle = AgentConversationStatus()
    #expect(idle.canSend)
    #expect(!idle.canStop)
    #expect(!idle.canRetry)

    let pending = AgentConversationStatus(run: .pending)
    #expect(!pending.canSend)
    #expect(pending.canStop)
    #expect(!pending.canRetry)

    let failed = AgentConversationStatus(run: .failed)
    #expect(failed.canSend)
    #expect(!failed.canStop)
    #expect(failed.canRetry)

    let offline = AgentConversationStatus(connection: .disconnected, run: .failed)
    #expect(!offline.canSend)
    #expect(!offline.canRetry)
}

@Test func omittedCountCannotBeNegative() {
    #expect(AgentConversationStatus(omittedMessageCount: -2).omittedMessageCount == 0)
}
