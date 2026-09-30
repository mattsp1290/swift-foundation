import AGUICore
import AgentPresentation
import Foundation
import Testing

@Test func exactMessageLimitAndOverflow() throws {
    let source: [any Message] = (0..<101).map {
        UserMessage(id: "u-\($0)", content: "visible-\($0)")
    }
    let projection = try AgentTranscriptProjection(messages: source)
    #expect(projection.messages.count == 100)
    #expect(projection.messages.first?.id == "u-0")
    #expect(projection.messages.last?.id == "u-99")
    #expect(projection.omissions == [.init(reason: .messageLimit, count: 1)])
}

@Test func exactTextByteLimitAndOverflow() throws {
    let exact = String(repeating: "é", count: AgentTranscriptProjection.maximumTextBytes / 2)
    let source: [any Message] = [
        AssistantMessage(id: "exact", content: exact),
        UserMessage(id: "overflow", content: "x"),
    ]
    let projection = try AgentTranscriptProjection(messages: source)
    #expect(projection.messages.map(\.id) == ["exact"])
    #expect(projection.messages[0].text.utf8.count == AgentTranscriptProjection.maximumTextBytes)
    #expect(projection.omissions == [.init(reason: .textLimit, count: 1)])
}

@Test func oversizedFirstMessageIsOmittedAndLaterTextCanDisplay() throws {
    let source: [any Message] = [
        UserMessage(id: "huge", content: String(repeating: "x", count: AgentTranscriptProjection.maximumTextBytes + 1)),
        AssistantMessage(id: "small", content: "hello"),
    ]
    let projection = try AgentTranscriptProjection(messages: source)
    #expect(projection.messages == [.init(id: "small", role: .assistant, text: "hello")])
    #expect(projection.omissions == [.init(reason: .textLimit, count: 1)])
}

@Test func onlyAllowlistedTextCrossesBoundary() throws {
    let source: [any Message] = [
        UserMessage(id: "u", content: "hello", name: "credential-in-name", encryptedValue: "secret-cipher"),
        AssistantMessage(
            id: "a", content: "answer", name: "credential-in-name",
            toolCalls: [ToolCall(id: "call", function: FunctionCall(name: "secret-function", arguments: "credential-in-arguments"))],
            encryptedValue: "secret-cipher", metadata: Data("credential-in-metadata".utf8)
        ),
        UserMessage.multimodal(id: "media", parts: [TextInputContent(text: "hidden-part")]),
        AssistantMessage(id: "tool-only", content: nil),
        ReasoningMessage(id: "thought", content: "private-reasoning"),
        SystemMessage(id: "system", content: "private-system"),
    ]
    let projection = try AgentTranscriptProjection(messages: source)
    #expect(projection.messages == [
        .init(id: "u", role: .user, text: "hello"),
        .init(id: "a", role: .assistant, text: "answer"),
    ])
    #expect(projection.omissions == [.init(reason: .unsupportedContent, count: 4)])
    let visible = projection.messages.map(\.text).joined()
    #expect(!visible.contains("credential"))
    #expect(!visible.contains("secret"))
    #expect(!visible.contains("hidden"))
    #expect(!visible.contains("reasoning"))
    #expect(!visible.contains("arguments"))
}

@Test func sdkDecodedSnapshotProjectsOnlyAllowedContent() throws {
    let json = #"{"type":"MESSAGES_SNAPSHOT","messages":[{"id":"u","role":"user","content":"hi"},{"id":"a","role":"assistant","content":"hello","metadata":{"credential":"secret"}},{"id":"r","role":"reasoning","content":"private"}]}"#
    let event = try AGUIEventDecoder().decode(Data(json.utf8))
    let snapshot = try #require(event as? MessagesSnapshotEvent)
    let projection = try AgentTranscriptProjection(messages: snapshot.messages)
    #expect(projection.messages == [
        .init(id: "u", role: .user, text: "hi"),
        .init(id: "a", role: .assistant, text: "hello"),
    ])
    #expect(projection.omissions == [.init(reason: .unsupportedContent, count: 1)])
}

@Test func replacementIsDeterministicAndIDsAreUnique() throws {
    let first: [any Message] = [
        UserMessage(id: "same", content: "first"),
        AssistantMessage(id: "same", content: "duplicate"),
        AssistantMessage(id: "", content: "blank"),
        AssistantMessage(id: String(repeating: "x", count: 257), content: "long-id"),
        AssistantMessage(id: "next", content: "second"),
    ]
    let a = try AgentTranscriptProjection(messages: first)
    let b = try AgentTranscriptProjection(messages: first)
    #expect(a == b)
    #expect(a.messages.map(\.id) == ["same", "next"])
    #expect(a.omissions == [
        .init(reason: .invalidIdentifier, count: 2),
        .init(reason: .duplicateIdentifier, count: 1),
    ])
    let replacement = try AgentTranscriptProjection(messages: [UserMessage(id: "new", content: "replacement")])
    #expect(replacement.messages.map(\.id) == ["new"])
}

@Test @MainActor func deliveryRetainsLastAcceptedProjectionOnFailure() throws {
    let delivery = AgentTranscriptDelivery()
    #expect(delivery.status == .unavailable)
    delivery.observationFailed()
    #expect(delivery.status == .unavailable)
    let first = try AgentTranscriptProjection(messages: [UserMessage(id: "u", content: "hello")])
    delivery.accept(first)
    #expect(delivery.status == .live)
    delivery.observationFailed()
    #expect(delivery.status == .stale)
    #expect(delivery.projection == first)
    let replacement = try AgentTranscriptProjection(messages: [])
    delivery.accept(replacement)
    #expect(delivery.status == .live)
    #expect(delivery.projection == replacement)
}

@Test func sourceMessageBudgetRejectsBeforeProjection() throws {
    let withinBudget: [any Message] = [UserMessage(id: "visible", content: "ok")]
        + (0..<AgentTranscriptProjection.maximumSourceMessages - 1).map {
            ReasoningMessage(id: "hidden-\($0)", content: "private") as any Message
        }
    let accepted = try AgentTranscriptProjection(messages: withinBudget)
    #expect(accepted.messages.map(\.id) == ["visible"])
    #expect(accepted.omissions == [.init(reason: .unsupportedContent, count: 999)])

    let overBudget = withinBudget + [UserMessage(id: "extra", content: "no")]
    #expect(throws: AgentTranscriptProjection.ProjectionError.sourceMessageLimit) {
        try AgentTranscriptProjection(messages: overBudget)
    }
}

@Test @MainActor func overBudgetObservationRetainsLastAcceptedTranscript() {
    let delivery = AgentTranscriptDelivery()
    #expect(delivery.acceptObservedMessages([UserMessage(id: "stable", content: "last good")]))
    let accepted = delivery.projection
    let overBudget: [any Message] = Array(
        repeating: UserMessage(id: "x", content: "overflow"),
        count: AgentTranscriptProjection.maximumSourceMessages + 1
    )
    #expect(!delivery.acceptObservedMessages(overBudget))
    #expect(delivery.status == .stale)
    #expect(delivery.projection == accepted)
}

@Test func cumulativeInspectionBudgetFailsClosed() {
    let tooLarge = String(repeating: "x", count: 8 * AgentTranscriptProjection.maximumTextBytes)
    let source: [any Message] = [
        UserMessage(id: "first", content: tooLarge),
        UserMessage(id: "second", content: tooLarge),
    ]
    #expect(throws: AgentTranscriptProjection.ProjectionError.inspectionLimit) {
        try AgentTranscriptProjection(messages: source)
    }
}
