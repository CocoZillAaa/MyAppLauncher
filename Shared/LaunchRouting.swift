import Foundation

/// Parses application launches, validated HTTP(S) links, and the companion configuration route.
enum LaunchRoute {
    static let scheme = "myapplauncher"

    enum Destination {
        case application(String)
        case website(URL)
        case configuration
    }

    static var configurationURL: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "configure"
        return components.url!
    }

    static func url(bundleIdentifier: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "launch"
        components.queryItems = [URLQueryItem(name: "bundle", value: bundleIdentifier)]
        return components.url!
    }

    static func websiteURL(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open-web"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url!
    }

    static func destination(from url: URL) -> Destination? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return nil }

        if url.host == "configure",
           components.path.isEmpty,
           components.queryItems?.isEmpty ?? true,
           components.fragment == nil {
            return .configuration
        }

        guard let items = components.queryItems, items.count == 1,
              components.fragment == nil,
              let value = items[0].value else { return nil }
        switch (url.host, items[0].name) {
        case ("launch", "bundle") where isValidBundleIdentifier(value):
            return .application(value)
        case ("open-web", "url"):
            guard let website = validWebsiteURL(value) else { return nil }
            return .website(website)
        default:
            return nil
        }
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count < 256 &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func validWebsiteURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
