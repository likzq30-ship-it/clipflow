import Foundation

enum AIEndpointValidator {
    static func validateLocal(_ url: URL) throws -> URL {
        try validateCommon(url)
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw AIError.invalidEndpoint
        }
        guard let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" else {
            throw AIError.invalidEndpoint
        }
        return originURL(from: url)
    }

    static func validateRemote(
        _ url: URL,
        consent: AIConsentOrigin?
    ) throws -> AIConsentOrigin {
        try validateCommon(url)
        guard url.scheme?.lowercased() == "https" else {
            throw AIError.invalidEndpoint
        }
        guard let origin = AIConsentOrigin(url: url),
              consent == origin else {
            throw AIError.missingConsent
        }
        return origin
    }

    static func originURL(from url: URL) -> URL {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? ""
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(renderedHost)\(port)")!
    }
}

private extension AIEndpointValidator {
    static func validateCommon(_ url: URL) throws {
        guard url.user == nil, url.password == nil else {
            throw AIError.invalidEndpoint
        }
        guard url.path.isEmpty || url.path == "/" else {
            throw AIError.invalidEndpoint
        }
        guard url.query == nil, url.fragment == nil else {
            throw AIError.invalidEndpoint
        }
        guard url.host != nil else {
            throw AIError.invalidEndpoint
        }
    }
}
