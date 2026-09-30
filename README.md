# swift-foundation

A Swift package for a controlled, plain text agent conversation surface. The host supplies transcript values and owns the composer draft and send callback. This package does not start a run or make network requests.

## Requirements

- Swift 6.0 or newer, with Swift 6 language mode and strict concurrency checking
- macOS 13 or newer, or iOS 16 or newer
- The public [ag-ui-swift](https://github.com/mattsp1290/ag-ui-swift) package, pinned in `Package.swift` to revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`

## Public API

`AgentPresentation` has no SwiftUI dependency. It imports Foundation and the pinned SDK's `AGUICore` product for typed, already decoded messages:

- `AgentTranscriptMessage(id:role:text:)` is an immutable, `Sendable`, `Hashable` display value. `id` is a host supplied stable string; `role` is `.user` or `.assistant`; `text` is plain text.
- `AgentTranscriptProjection(messages:)` copies only `UserMessage.content` and `AssistantMessage.content` into display values. It accepts the decoded message array from a host observation, including `MessagesSnapshotEvent.messages` or an accumulated `AgentState.messages` value. Each replacement is deterministic, with at most 100 messages, 1 MiB of displayed UTF-8 text, and 256 UTF-8 bytes per identifier. `omissions` reports aggregate counts for unsupported content, invalid or duplicate identifiers, and limits; it carries no omitted content or identifiers.
- `AgentTranscriptDelivery` is a `@MainActor` holder for the last accepted projection and `.live`, `.stale`, or `.unavailable` status. Call `observationFailed()` when the host cannot observe a new state; it retains the last projection.

`AgentViews` imports SwiftUI and `AgentPresentation`:

- `AgentTranscriptView(messages:)` renders user and assistant text in host order. Text is selectable.
- `AgentComposerView(draft:isEnabled:onSend:)` binds to the host's draft. It enables Send only for nonblank text when `isEnabled` is true. Sending trims outer whitespace, clears the draft, then invokes `onSend` once with the consumed text.
- `AgentConversationView(messages:draft:isSendEnabled:onSend:)` combines the transcript and composer.

The SDK's public decoding and reduction stay upstream of this boundary. The projection never decodes SSE, fetches media, or retains raw events, tool arguments, encrypted values, metadata, reasoning, system or developer messages. Multimodal user content and unrecognized message types are omitted explicitly. A host must decide when an observation is valid and pass complete replacements to the projection; this package does not operate transport or app policy.

## Synthetic host

Open `AgentConversationView_Previews` in Xcode for a compiled synthetic host, or paste this view into a macOS or iOS SwiftUI app that depends on both library products. The two initial messages show selectable text. Enter a message and tap Send (or press Return); each enabled submission invokes the callback once and adds one user message.

```swift
import AgentPresentation
import AgentViews
import SwiftUI

struct SyntheticAgentHost: View {
    @State private var messages = [
        AgentTranscriptMessage(id: "user-0", role: .user, text: "Hello"),
        AgentTranscriptMessage(id: "assistant-0", role: .assistant, text: "Hi!"),
    ]
    @State private var draft = ""
    @State private var sendCount = 0

    var body: some View {
        AgentConversationView(messages: messages, draft: $draft) { text in
            sendCount += 1
            messages.append(
                AgentTranscriptMessage(id: "user-\(sendCount)", role: .user, text: text)
            )
        }
    }
}
```

Run `swift test` for model and submission checks. Build the package with `swift build` on macOS, and use `xcodebuild -scheme AgentViews -destination 'generic/platform=iOS Simulator' build` for the iOS Simulator.
