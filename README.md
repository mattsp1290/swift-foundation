# swift-foundation

A Swift package for a controlled, plain text agent conversation surface. The host supplies transcript values and owns the composer draft and send callback. This package does not start a run or make network requests.

## Requirements

- Swift 6.0 or newer, with Swift 6 language mode and strict concurrency checking
- macOS 13 or newer, or iOS 16 or newer
- The public [ag-ui-swift](https://github.com/mattsp1290/ag-ui-swift) package, pinned in `Package.swift` to revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`

## Public API

`AgentPresentation` imports Foundation only:

- `AgentTranscriptMessage(id:role:text:)` is an immutable, `Sendable`, `Hashable` display value. `id` is a host supplied stable string; `role` is `.user` or `.assistant`; `text` is plain text.

`AgentViews` imports SwiftUI and `AgentPresentation`:

- `AgentTranscriptView(messages:)` renders user and assistant text in host order. Text is selectable.
- `AgentComposerView(draft:isEnabled:onSend:)` binds to the host's draft. It enables Send only for nonblank text when `isEnabled` is true. Sending trims outer whitespace, clears the draft, then invokes `onSend` once with the consumed text.
- `AgentConversationView(messages:draft:isSendEnabled:onSend:)` combines the transcript and composer.

The AG-UI SDK is an exact package dependency for later integration. None of its events or transport types enter these display APIs.

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
