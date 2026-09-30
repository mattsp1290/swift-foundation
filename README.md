# swift-foundation

A Swift package for a controlled, plain text agent conversation surface plus small session and HTTP building blocks. The host supplies transcript values and owns the composer draft and send callback. The conversation surface does not start a run or make network requests.

## Requirements

- Swift 6.0 or newer, with Swift 6 language mode and strict concurrency checking
- macOS 13 or newer, or iOS 16 or newer
- The public [ag-ui-swift](https://github.com/mattsp1290/ag-ui-swift) package, pinned in `Package.swift` to revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`

## Public API

`SessionCredentials` provides `RefreshCredential`, a `Sendable` async load/store/clear boundary, and an ephemeral `InMemorySessionCredentialStore`. `KeychainSessionCredentialStore(service:account:)` persists one opaque refresh credential in a generic-password Keychain item scoped to the supplied service and account. It uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and replaces an existing item in place. Missing items load as `nil`, and clearing a missing item succeeds. Its errors contain only a Keychain status code or a fixed case. Neither store accepts access tokens or account metadata.

`AuthenticatedHTTP` is a Foundation-only product. `APIEndpoint(baseURL:)` requires an absolute trailing-slash HTTPS URL, with plain HTTP permitted for loopback hosts only; it rejects userinfo, query, and fragment. `AuthenticatedHTTPClient(endpoint:session:)` accepts a host-supplied bearer access token on each `request(path:method:accessToken:body:)` call and returns the raw data and HTTP response. This raw client remains available for hosts that own status handling and token renewal.

`SessionCoordinator` is an optional actor around that client. The host supplies an initial access token, a `SessionCredentialStore`, an async refresh closure that exchanges the opaque credential for `SessionRefreshResult`, and an optional sign-out hook. The host continues to choose refresh routes, request bodies, and response decoding. Protected responses with HTTP 401 and a top-level JSON `code` of `invalid_session` share one in-flight refresh; the new refresh credential is stored before the in-memory access token changes, then each request is replayed once. Non-success responses throw `SessionServerError(statusCode:code:)` so callers can inspect the server code. A refresh `409 refresh_conflict` throws `SessionCoordinatorError.refreshConflict` and preserves the credential. A refresh or replay `401 invalid_session`, or a protected or refresh `403 access_forbidden`, revokes the in-memory access token, waits for any credential replacement already in progress, clears the stored credential, then calls the host sign-out hook. If storage clearing fails, the token remains revoked, the hook still runs, and the storage error is thrown. Other refresh failures preserve the credential. The coordinator does not log tokens or credentials.

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

Open `AgentConversationView_Previews` in Xcode for a compiled synthetic host, or paste this view into a macOS or iOS SwiftUI app that depends on both library products. The two initial messages show selectable text. Enter a message and tap Send (or press Command-Return); each enabled submission invokes the callback once and adds one user message.

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

`Consumers/` contains two independent native SwiftUI applications: `FoundationCatalog` presents two isolated conversations and all status notices; `BenchySynthetic` behaves like a small synthetic request host. Tap **Log in to fixture** to receive an opaque refresh credential from its in-process URLProtocol fixture. The host stores it through `KeychainSessionCredentialStore`, reloads it after app relaunch, exchanges it for an access token, and passes the access token to `AuthenticatedHTTPClient` to display the protected `fixture-alice` username. **Replace fixture credential** changes the stored value and displays `fixture-bob`; **Clear fixture credential** signs out and stays signed out after relaunch. Clearing invalidates older login and restore responses and waits for earlier Keychain writes before deleting the item. It makes no external network request. Both display per-instance send/stop/retry callback counts, the exact `swift-foundation` Git SHA / SwiftPM revision pin, and log that pin when displayed. These are host examples, not Agentcraft or Benchy app migrations.

For a macOS native host Keychain check without UI automation, build `BenchySynthetic_macOS` and run `Scripts/verify-macos-keychain-host.sh /path/to/BenchySynthetic.app`. It launches the same app executable separately for login, restore, replacement, and clear, and checks only the resulting fixture username or signed-out state. The iOS host UI tests delay login and restore responses until after Clear, then verify that each response is discarded and relaunch remains signed out.

After a candidate commit is published to the public GitHub URL, run on a Mac with Xcode 26.2, XcodeGen 2.46 (`brew install xcodegen`), and a booted iPhone 16 Pro iOS 18.2 Simulator:

```sh
Scripts/verify-consumers.sh <published-40-character-swift-foundation-commit-SHA>
```

The script generates an isolated Xcode project under `/tmp`, with one SwiftPM dependency: `https://github.com/mattsp1290/swift-foundation.git` at the supplied immutable revision. There are no sibling checkout paths or package overrides. It builds both apps for macOS and iPhone Simulator, launches each Mac executable, installs and launches each simulator app, then runs each scheme's XCUITest suite. It leaves the generated project and per-target logs in the printed output directory. Set `FOUNDATION_CONSUMER_OUTPUT` to retain it at a chosen path. The package itself pins AG-UI SDK revision `9412aab2549e06e165ada85fe6346b9b6e5a0f2b`. The generated app schemes are `FoundationCatalog_macOS`, `FoundationCatalog_iOS`, `BenchySynthetic_macOS`, and `BenchySynthetic_iOS`.

The transcript uses `agent-transcript` and `agent-message-<id>` accessibility identifiers; the draft, send, Stop, Retry, and status use `agent-composer-draft`, `agent-composer-send`, `agent-stop`, `agent-retry`, and `agent-status`. The catalog and Benchy callback count labels have `catalog-callback-counts-<title>` and `ben-chy-callback-counts` identifiers. Use these with Xcode's Accessibility Inspector or UI automation. The catalog provides stale, unavailable, live, disconnect, and failed controls for manual acceptance; the Benchy host provides complete, fail, and connection controls. Verify a multiline draft, one Send callback, disabled Send while pending or offline, one Stop/Retry callback, copy/select, VoiceOver labels, keyboard navigation, light/dark, narrow iPhone layout, and 200% Dynamic Type in the running apps.

## Provenance and maintenance

Maintainer: Matt Spurlin. License: MIT, see `LICENSE`. This package's public source is `https://github.com/mattsp1290/swift-foundation`; the only external runtime dependency is the public pinned AG-UI Swift SDK. The consumer examples are synthetic and carry no credentials, session identifiers, or private routes.

## Verification record

On 2026-09-29, `swift test` and the `AgentViews` iOS Simulator package build passed with Xcode 26.2 / Swift 6.2.3 on the published candidate `f2855978e92d2ac3f61c6425d499b5a7db26e921`. An isolated XcodeGen project resolved that candidate from the public GitHub URL and the qualified AG-UI SDK revision. Both iPhone 16 Pro Simulator XCUITest suites passed. Both macOS apps built, launched, and logged the exact candidate SHA; a direct UI run exercised Send, Stop, Retry, pending-disabled state, stale/unavailable notices, keyboard submission, and separate catalog instances.

The macOS XCUITest runner intermittently failed to attach the app window during repeated launches on this verification machine, so the full script did not pass there. The macOS controls were exercised in the running apps instead. VoiceOver speech navigation and the complete keyboard tab order remain manual acceptance checks. Re-run the URL-only script with the revision being accepted; its pin must already be published.

## Session consumer contract

`FoundationCatalog` and `BenchySynthetic` are separate native SwiftUI targets in `Consumers/project.yml.template`. The generated project resolves this root package through `https://github.com/mattsp1290/swift-foundation.git` at the checked-out commit SHA. It uses no local package paths or overrides. Both targets import the public `SessionCredentials` product and call `KeychainSessionCredentialStore(service:account:)` to store, load, and clear a `RefreshCredential`. Catalog's **Check catalog Keychain** button reports its round trip. Benchy's existing login, restore, replacement, and clear flow displays the protected `fixture-alice` or `fixture-bob` username from an in-process URLProtocol fixture.

Benchy also imports the public `AuthenticatedHTTP` product. **Run session lifecycle** in the **Fixture credentials** menu creates `APIEndpoint`, `AuthenticatedHTTPClient`, and `SessionCoordinator` with host-supplied refresh and sign-out closures. Two concurrent protected requests receive `401 invalid_session`; the fixture checks exactly one refresh exchange, two successful replays, and the replacement credential in Keychain. A subsequent `403 access_forbidden` clears the credential and calls sign-out exactly once. The result label reports only fixture username and pass conditions, never credential or access-token values. The two applications use distinct Keychain service names.

From a clean, published checkout, run `Scripts/verify-session-consumers.sh` with no arguments. It requires the local HEAD SHA to be advertised by the public source, runs `swift test`, builds the `AuthenticatedHTTP` iOS Simulator package product, and invokes the URL-only generated consumer verification at that exact SHA. It attempts the Catalog macOS XCUITest suite and runs both iOS XCUITest suites, plus native macOS Keychain and coordinator smoke checks. If Catalog macOS XCUITest reports the exact app-only accessibility tree attachment signature observed on this machine, the gate explicitly reports that UI suite as unverified and continues to the native Catalog smoke check; other Catalog failures stop the gate. The Benchy macOS XCUITest runner is reported as unverified because its attach failure was observed on this machine; native Benchy smoke checks cover its session behavior. Generated projects and logs are retained under the printed `FOUNDATION_CONSUMER_OUTPUT` path. The public package products are `AgentPresentation`, `AgentViews`, `SessionCredentials`, and `AuthenticatedHTTP`; the source, maintainer, MIT license, platform requirements, and immutable AG-UI dependency are recorded above.
