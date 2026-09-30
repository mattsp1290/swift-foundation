import AgentPresentation
import XCTest

final class AgentTranscriptMessageTests: XCTestCase {
    func testHostSuppliedValuesRemainPlainDisplayData() {
        let user = AgentTranscriptMessage(id: "u1", role: .user, text: "Hello")
        let assistant = AgentTranscriptMessage(id: "a1", role: .assistant, text: "Hi")

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.text, "Hello")
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.text, "Hi")
    }
}
