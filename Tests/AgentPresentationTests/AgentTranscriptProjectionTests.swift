import AGUICore
import AgentPresentation
import Foundation
import Testing

@Test func exactMessageLimitAndOverflow() {
    let source: [any Message] = (0..<101).map {
        UserMessage(id: "u-\($0)", content: "visible-\($0)")
    }
    let projection = AgentTranscriptProjection(messages: source)
    #expect(projection.messages.count == 100)
    #expect(projection.messages.first?.id == "u-0")
    #expect(projection.messages.last?.id == "u-99")
    #expect(projection.omissions == [.init(reason: .messageLimit, count: 1)])
}

@Test func exactTextByteLimitAndOverflow() {
    let exact = String(repeating: "é", count: AgentTranscriptProjection.maximumTextBytes / 2)
    let source: [any Message] = [
        AssistantMessage(id: "exact", content: exact),
        UserMessage(id: "overflow", content: "x"),
    ]
    let projection = AgentTranscriptProjection(messages: source)
    #expect(projection.messages.map(\.id) == ["exact"])
    #expect(projection.messages[0].text.utf8.count == AgentTranscriptProjection.maximumTextBytes)
    #expect(projection.omissions == [.init(reason: .textLimit, count: 1)])
}

@Test func oversizedFirstMessageIsOmittedAndLaterTextCanDisplay() {
    let source: [any Message] = [
        UserMessage(id: "huge", content: String(repeating: "x", count: AgentTranscriptProjection.maximumTextBytes + 1)),
        AssistantMessage(id: "small", content: "hello"),
    ]
    let projection = AgentTranscriptProjection(messages: source)
    #expect(projection.messages == [.init(id: "small", role: .assistant, text: "hello")])
    #expect(projection.omissions == [.init(reason: .textLimit, count: 1)])
}

@Test func onlyAllowlistedTextCrossesBoundary() {
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
    let projection = AgentTranscriptProjection(messages: source)
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
    let projection = AgentTranscriptProjection(messages: snapshot.messages)
    #expect(projection.messages == [
        .init(id: "u", role: .user, text: "hi"),
        .init(id: "a", role: .assistant, text: "hello"),
    ])
    #expect(projection.omissions == [.init(reason: .unsupportedContent, count: 1)])
}

@Test func replacementIsDeterministicAndIDsAreUnique() {
    let first: [any Message] = [
        UserMessage(id: "same", content: "first"),
        AssistantMessage(id: "same", content: "duplicate"),
        AssistantMessage(id: "", content: "blank"),
        AssistantMessage(id: String(repeating: "x", count: 257), content: "long-id"),
        AssistantMessage(id: "next", content: "second"),
    ]
    let a = AgentTranscriptProjection(messages: first)
    let b = AgentTranscriptProjection(messages: first)
    #expect(a == b)
    #expect(a.messages.map(\.id) == ["same", "next"])
    #expect(a.omissions == [
        .init(reason: .invalidIdentifier, count: 2),
        .init(reason: .duplicateIdentifier, count: 1),
    ])
    let replacement = AgentTranscriptProjection(messages: [UserMessage(id: "new", content: "replacement")])
    #expect(replacement.messages.map(\.id) == ["new"])
}

@Test @MainActor func deliveryRetainsLastAcceptedProjectionOnFailure() {
    let delivery = AgentTranscriptDelivery()
    #expect(delivery.status == .unavailable)
    delivery.observationFailed()
    #expect(delivery.status == .unavailable)
    let first = AgentTranscriptProjection(messages: [UserMessage(id: "u", content: "hello")])
    delivery.accept(first)
    #expect(delivery.status == .live)
    delivery.observationFailed()
    #expect(delivery.status == .stale)
    #expect(delivery.projection == first)
    let replacement = AgentTranscriptProjection(messages: [])
    delivery.accept(replacement)
    #expect(delivery.status == .live)
    #expect(delivery.projection == replacement)
}
