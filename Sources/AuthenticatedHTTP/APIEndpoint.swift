import Foundation

public struct APIEndpoint: Sendable, Equatable {
    public enum ValidationError: Error, Equatable {
        case invalidBaseURL
        case insecureBaseURL
        case invalidPath
    }

    public let baseURL: URL

    /// A base URL must be absolute and end in a slash. Plain HTTP is accepted only for loopback hosts.
    public init(baseURL: URL) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              baseURL.absoluteString.hasSuffix("/"),
              !baseURL.path.contains("/../"), !baseURL.path.contains("/./") else {
            throw ValidationError.invalidBaseURL
        }
        guard scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw ValidationError.insecureBaseURL
        }
        self.baseURL = baseURL
    }

    /// Resolve a relative resource path under the validated base path.
    public func url(for path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              let components = URLComponents(string: path),
              components.scheme == nil, components.host == nil,
              components.query == nil, components.fragment == nil,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  $0 == "." || $0 == ".." || $0.lowercased() == "%2e" || $0.lowercased() == "%2e%2e"
              }),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ValidationError.invalidPath
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
            guard let number = UInt8($0), String(number) == $0 else { return false }
            return true
        }
    }
}
