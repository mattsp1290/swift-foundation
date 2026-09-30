import AuthenticatedHTTP
import Foundation
import XCTest

final class AuthenticatedHTTPClientTests: XCTestCase {
    func testEndpointValidation() throws {
        let good = try APIEndpoint(baseURL: URL(string: "https://api.example.test/v1/")!)
        XCTAssertEqual(try good.url(for: "profile"), URL(string: "https://api.example.test/v1/profile"))
        XCTAssertNoThrow(try APIEndpoint(baseURL: URL(string: "http://127.0.0.1:8080/")!))
        XCTAssertNoThrow(try APIEndpoint(baseURL: URL(string: "http://[::1]:8080/")!))
        for value in [
            "https://api.example.test/v1", "https://user:secret@api.example.test/",
            "https://api.example.test/?a=1", "https://api.example.test/#part",
            "http://api.example.test/", "http://127.0.0.2.example.test/",
        ] {
            XCTAssertThrowsError(try APIEndpoint(baseURL: URL(string: value)!))
        }
        for path in ["/profile", "../profile", "x/../profile", "profile?token=x", "https://other.test/"] {
            XCTAssertThrowsError(try good.url(for: path))
        }
    }

    func testProtectedFixtureUsernameThroughSyntheticHost() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtectedFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/api/")!)
        let host = await SyntheticNativeHost(client: AuthenticatedHTTPClient(endpoint: endpoint, session: session))
        let displayedUsername = try await host.loadUsername(accessToken: "host-access-token")
        XCTAssertEqual(displayedUsername, "fixture-alice")
        let visibleUsername = await host.displayedUsername
        XCTAssertEqual(visibleUsername, "fixture-alice")
    }

    func testRejectsUnsafeBearerValue() async throws {
        let endpoint = try APIEndpoint(baseURL: URL(string: "https://fixture.example.test/")!)
        let client = AuthenticatedHTTPClient(endpoint: endpoint)
        do {
            _ = try await client.request(path: "profile", accessToken: "token\r\nInjected: yes")
            XCTFail("Expected invalid token")
        } catch AuthenticatedHTTPClient.RequestError.invalidAccessToken {
        }
    }
}

private final class ProtectedFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorized = request.url?.absoluteString == "https://fixture.example.test/api/profile"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer host-access-token"
        let code = authorized ? 200 : 401
        let body = authorized ? Data(#"{"username":"fixture-alice"}"#.utf8) : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class SyntheticNativeHost {
    private let client: AuthenticatedHTTPClient
    private(set) var displayedUsername = ""

    init(client: AuthenticatedHTTPClient) { self.client = client }

    func loadUsername(accessToken: String) async throws -> String {
        let (data, response) = try await client.request(path: "profile", accessToken: accessToken)
        guard response.statusCode == 200 else { throw HostError.unauthorized }
        displayedUsername = try JSONDecoder().decode(Profile.self, from: data).username
        return displayedUsername
    }

    private struct Profile: Decodable { let username: String }
    private enum HostError: Error { case unauthorized }
}
