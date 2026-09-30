import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport that takes a host-owned access token for each request.
public struct AuthenticatedHTTPClient: Sendable {
    public enum RequestError: Error, Equatable {
        case invalidAccessToken
        case invalidMethod
        case nonHTTPResponse
    }

    public let endpoint: APIEndpoint
    private let session: URLSession

    public init(endpoint: APIEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Returns the raw response so the host can decide how to handle status codes and payloads.
    public func request(
        path: String,
        method: String = "GET",
        accessToken: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard !accessToken.isEmpty,
              accessToken.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw RequestError.invalidAccessToken
        }
        guard !method.isEmpty,
              method.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) else {
            throw RequestError.invalidMethod
        }

        var request = URLRequest(url: try endpoint.url(for: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RequestError.nonHTTPResponse
        }
        return (data, response)
    }
}
