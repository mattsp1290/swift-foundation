import AgentPresentation
import SwiftUI

private struct SyntheticAgentHostPreview: View {
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

struct AgentConversationView_Previews: PreviewProvider {
    static var previews: some View {
        SyntheticAgentHostPreview()
    }
}
