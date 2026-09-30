# swift-foundation

A Swift package for a controlled, plain text agent conversation surface. The host supplies transcript values and owns the composer draft and send callback. This package does not start a run or make network requests.

## Requirements

- Swift 6.0 or newer, with Swift 6 language mode and strict concurrency checking
- macOS 13 or newer, or iOS 16 or newer
- The public [ag-ui-swift](https://github.com/mattsp1290/ag-ui-swift) package, pinned in `Package.swift` to revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`

## Public API

`AgentPresentation` has no SwiftUI dependency. It imports Foundation and the pinned SDK's `AGUICore` product for typed, already decoded messages:

- `AgentTranscriptMessage(id:role:text:)` is an immutable, `Sendable`, `Hashable` display value. `id` is a host supplied stable string; `role` is `.user` or `.assistant`; `text` is plain text.
- `AgentTranscriptProjection(messages:)` throws if an observation exceeds 1,000 source messages or a 2 MiB text-inspection budget. Within that budget it copies only `UserMessage.content` and `AssistantMessage.content` into display values. It accepts the decoded message array from a host observation, including `MessagesSnapshotEvent.messages` or an accumulated `AgentState.messages` value. Each replacement is deterministic, with at most 100 displayed messages, 1 MiB of displayed UTF-8 text, and 256 UTF-8 bytes per identifier. `omissions` reports aggregate counts for unsupported content, invalid or duplicate identifiers, and display limits; it carries no omitted content or identifiers.
- `AgentTranscriptDelivery` is a `@MainActor` holder for the last accepted projection and `.live`, `.stale`, or `.unavailable` status. `acceptObservedMessages(_:)` projects a decoded observation and marks an over-budget failure stale while retaining the last accepted projection. Call `observationFailed()` for other observation failures.

`AgentViews` imports SwiftUI and `AgentPresentation`:

- `AgentTranscriptView(messages:)` renders user and assistant text in host order. Text is selectable and exposes role plus text to VoiceOver.
- `AgentComposerView(draft:isEnabled:onSend:)` binds to the host's multiline draft. It enables Send only for nonblank text when `isEnabled` is true. Sending trims outer whitespace, clears the draft, then invokes `onSend` once with the consumed text. Command-Return also sends. Return alone remains available for multiline entry.
- `AgentConversationStatus(connection:run:transcript:error:omittedMessageCount:)` is a host supplied display value. Connection is connected, connecting, or disconnected; run is idle, pending, or failed; transcript is live, stale, or unavailable. The host must sanitize `error` before passing it. The value gates send, stop, and retry.
- `AgentStatusView(status:onStop:onRetry:)` displays connection, pending, stale, unavailable, omission, and error notices. It exposes guarded Stop and Retry actions with VoiceOver and keyboard support (Command-period stops).
- `AgentConversationView(messages:draft:isSendEnabled:status:onStop:onRetry:onSend:)` combines status, transcript, and composer. Existing send-only call sites keep working through defaults.

The SDK's public decoding and reduction stay upstream of this boundary. The projection never decodes SSE, fetches media, or retains raw events, tool arguments, encrypted values, metadata, reasoning, system or developer messages. Multimodal user content and unrecognized message types are omitted explicitly. A host must byte-cap raw snapshots before SDK decoding, decide when an observation is valid, and pass complete replacements to the projection; this package does not own transport or app policy.

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

## URL-only native consumer verification

`Consumers/` contains two independent native SwiftUI applications: `FoundationCatalog` presents two isolated conversations and all status notices; `BenchySynthetic` behaves like a small synthetic request host. Neither app starts network traffic. Both display per-instance send/stop/retry callback counts, the exact `swift-foundation` Git SHA / SwiftPM revision pin, and log that pin when displayed. These are host examples, not Agentcraft or Benchy app migrations.

After a candidate commit is published to the public GitHub URL, run on a Mac with Xcode 26.2, XcodeGen 2.46 (`brew install xcodegen`), and a booted iPhone 16 Pro iOS 18.2 Simulator:

```sh
Scripts/verify-consumers.sh <published-40-character-swift-foundation-commit-SHA>
```

The script generates an isolated Xcode project under `/tmp`, with one SwiftPM dependency: `https://github.com/mattsp1290/swift-foundation.git` at the supplied immutable revision. There are no sibling checkout paths or package overrides. It builds both apps for macOS and iPhone Simulator, launches each Mac executable, installs and launches each simulator app, and leaves the generated project and per-target logs in the printed output directory. Set `FOUNDATION_CONSUMER_OUTPUT` to retain it at a chosen path. The package itself pins AG-UI SDK revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`. The generated app schemes are `FoundationCatalog_macOS`, `FoundationCatalog_iOS`, `BenchySynthetic_macOS`, and `BenchySynthetic_iOS`.

The transcript uses `agent-transcript` and `agent-message-<id>` accessibility identifiers; the draft, send, Stop, Retry, and status use `agent-composer-draft`, `agent-composer-send`, `agent-stop`, `agent-retry`, and `agent-status`. The catalog and Benchy callback count labels have `catalog-callback-counts-<title>` and `ben-chy-callback-counts` identifiers. Use these with Xcode's Accessibility Inspector or UI automation. The catalog provides stale, unavailable, live, disconnect, and failed controls for manual acceptance; the Benchy host provides complete, fail, and connection controls. Verify a multiline draft, one Send callback, disabled Send while pending or offline, one Stop/Retry callback, copy/select, VoiceOver labels, keyboard navigation, light/dark, narrow iPhone layout, and 200% Dynamic Type in the running apps.

## Provenance and maintenance

Maintainer: Matt Spurlin. License: MIT, see `LICENSE`. This package's public source is `https://github.com/mattsp1290/swift-foundation`; the only external runtime dependency is the public pinned AG-UI Swift SDK. The consumer examples are synthetic and carry no credentials, session identifiers, or private routes.

## Verification record

On 2026-09-29, `swift test` passed on macOS with Xcode 26.2 / Swift 6.2.3. A temporary XcodeGen project using a local package path for pre-publication compile verification built the catalog and synthetic Benchy host on macOS and iOS Simulator. Run the URL-only script above with the published candidate SHA for definitive independent-consumer verification; the script cannot pin an unpublished source revision.
