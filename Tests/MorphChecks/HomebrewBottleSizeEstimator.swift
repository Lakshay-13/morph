import Foundation
import MorphCore

/// Reads the compressed size of the Homebrew bottle that matches this Mac.
/// GHCR requires an anonymous, pull-only bearer token for blob HEAD requests;
/// this estimator never downloads the bottle itself.
enum HomebrewBottleSizeEstimator {
    private static let requestTimeout: TimeInterval = 12

    static func estimate(formula: String) async -> Int64? {
        guard isSafeFormula(formula),
              let apiURL = URL(string: "https://formulae.brew.sh/api/formula/\(formula).json") else { return nil }
        var apiRequest = URLRequest(url: apiURL, timeoutInterval: requestTimeout)
        apiRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: apiRequest),
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let formulaJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stable = formulaJSON["bottle"] as? [String: Any],
              let stableInfo = stable["stable"] as? [String: Any],
              let files = stableInfo["files"] as? [String: [String: Any]],
              let bottleInfo = files[platformKey()],
              let urlString = bottleInfo["url"] as? String,
              let bottleURL = URL(string: urlString),
              bottleURL.scheme == "https",
              ["ghcr.io", "github.com"].contains(bottleURL.host?.lowercased() ?? "") else {
            return nil
        }
        return await bottleSize(at: bottleURL, formula: formula)
    }

    static func tokenRequest(from challenge: String, formula: String) -> URLRequest? {
        guard isSafeFormula(formula),
              challenge.lowercased().hasPrefix("bearer ") else { return nil }
        let parameters = challengeParameters(String(challenge.dropFirst("Bearer ".count)))
        let expectedScope = "repository:homebrew/core/\(formula):pull"
        guard let realm = parameters["realm"],
              let service = parameters["service"], service == "ghcr.io",
              let scope = parameters["scope"], scope == expectedScope,
              let realmURL = URL(string: realm),
              let components = URLComponents(url: realmURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.lowercased() == "ghcr.io",
              components.port == nil, components.path == "/token",
              components.query == nil, components.fragment == nil else { return nil }

        var tokenComponents = components
        tokenComponents.queryItems = [
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "scope", value: scope),
        ]
        guard let tokenURL = tokenComponents.url else { return nil }
        var request = URLRequest(url: tokenURL, timeoutInterval: requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func bearerToken(from data: Data) -> String? {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["token"] as? String) ?? (object["access_token"] as? String),
              !token.isEmpty, token.utf8.count <= 16_384,
              !token.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return token
    }

    static func contentLength(from response: URLResponse?) -> Int64? {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
              length > 0 else { return nil }
        return length
    }

    private static func bottleSize(at url: URL, formula: String) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let length = contentLength(from: response) { return length }
        guard url.host?.lowercased() == "ghcr.io",
              let response = response as? HTTPURLResponse,
              response.statusCode == 401,
              let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let tokenRequest = tokenRequest(from: challenge, formula: formula),
              let (tokenData, tokenResponse) = try? await URLSession.shared.data(for: tokenRequest),
              let tokenResponse = tokenResponse as? HTTPURLResponse,
              (200..<300).contains(tokenResponse.statusCode),
              let token = bearerToken(from: tokenData) else { return nil }

        var authorizedRequest = URLRequest(url: url, timeoutInterval: requestTimeout)
        authorizedRequest.httpMethod = "HEAD"
        authorizedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, authorizedResponse) = try? await URLSession.shared.data(for: authorizedRequest) else { return nil }
        return contentLength(from: authorizedResponse)
    }

    private static func challengeParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for parameter in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return [:] }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil,
                  rawValue.count >= 2, rawValue.first == "\"", rawValue.last == "\"" else { return [:] }
            let value = String(rawValue.dropFirst().dropLast())
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return [:] }
            result[key] = value
        }
        return result
    }

    private static func isSafeFormula(_ formula: String) -> Bool {
        !formula.isEmpty && formula.utf8.count <= 128 && formula.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0.value == 45
        }
    }

    private static func platformKey() -> String {
        let isAppleSilicon = (try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/uname"),
            arguments: ["-m"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == "arm64"
        let macOSName: String
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case 26: macOSName = "tahoe"
        case 15: macOSName = "sequoia"
        case 14: macOSName = "sonoma"
        case 13: macOSName = "ventura"
        case 12: macOSName = "monterey"
        default: return ""
        }
        return "\(isAppleSilicon ? "arm64" : "x86_64")_\(macOSName)"
    }
}
