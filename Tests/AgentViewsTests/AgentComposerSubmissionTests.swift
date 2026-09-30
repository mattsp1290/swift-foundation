@testable import AgentViews
import XCTest

final class AgentComposerSubmissionTests: XCTestCase {
    func testEnabledDraftIsConsumedExactlyOnce() {
        var draft = "  Hello, assistant!  \n"
        var sends: [String] = []

        for _ in 0..<2 {
            if let text = AgentComposerSubmission.takeText(from: &draft, isEnabled: true) {
                sends.append(text)
            }
        }

        XCTAssertEqual(sends, ["Hello, assistant!"])
        XCTAssertEqual(draft, "")
    }

    func testDisabledOrBlankDraftCannotSend() {
        var disabled = "Hello"
        XCTAssertFalse(AgentComposerSubmission.canSend(disabled, isEnabled: false))
        XCTAssertNil(AgentComposerSubmission.takeText(from: &disabled, isEnabled: false))
        XCTAssertEqual(disabled, "Hello")

        var blank = " \n "
        XCTAssertFalse(AgentComposerSubmission.canSend(blank, isEnabled: true))
        XCTAssertNil(AgentComposerSubmission.takeText(from: &blank, isEnabled: true))
    }
}
