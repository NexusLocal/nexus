import Foundation

// Only one app can use ports 80 and 443 at a time (issue #7). While nginx of Nexus has them, the
// sites of these apps do not open, and their HTTPS names reach Nexus with a certificate that does
// not match. MAMP PRO uses the ports only after its "80/443" setting, but many users choose it.
// DDEV and Lando move to other ports by themselves, so they are not in the list.
public enum OtherWebServers {
    public struct App: Sendable, Equatable {
        public enum Location: Sendable, Equatable {
            case bundle(String)
            case anyFile([String])
        }

        public let name: String
        public let location: Location
        // A server of this app starts again after a stop. So only the app itself can stop it.
        public var restartsItsServers = false
    }

    public static let webPorts = (http: 80, https: 443)
    public static let movedWebPorts = (http: 8080, https: 8443)

    public static let apps = [
        App(name: "Local", location: .bundle("com.getflywheel.lightning.local")),
        App(name: "Herd", location: .bundle("de.beyondco.herd"), restartsItsServers: true),
        App(name: "Valet", location: .anyFile(["~/.composer/vendor/bin/valet", "~/.config/composer/vendor/bin/valet"])),
        App(name: "DevKinsta", location: .bundle("org.kinsta.DevKinsta")),
        App(name: "ServBay", location: .anyFile(["/Applications/ServBay"])),
        App(name: "XAMPP", location: .anyFile(["/Applications/XAMPP"])),
        App(name: "MAMP PRO", location: .bundle("de.appsolute.mamppro"), restartsItsServers: true),
    ]

    public static func managerBundleIdentifier(of name: String) -> String? {
        guard case .bundle(let identifier)? = apps.first(where: { $0.name == name && $0.restartsItsServers })?.location else {
            return nil
        }

        return identifier
    }

    public static func installed(home: String, hasApp: (String) -> Bool, fileExists: (String) -> Bool) -> [String] {
        apps.filter { app in
            switch app.location {
            case .bundle(let identifier): hasApp(identifier)
            case .anyFile(let paths): paths.contains { fileExists($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) }
            }
        }
        .map(\.name)
    }

    public static func noticeNames(installed: [String], hidden: Set<String>, nginxPorts: [Int]) -> [String] {
        guard nginxPorts.contains(where: { $0 == webPorts.http || $0 == webPorts.https }) else {
            return []
        }

        return installed.filter { !hidden.contains($0) }
    }

    public static func noticeTitle(_ names: [String]) -> String {
        "\(EnglishList.joined(names)) also \(names.count == 1 ? "needs" : "need") ports \(webPorts.http) and \(webPorts.https)"
    }

    public static func noticeMessage(_ names: [String]) -> String {
        let one = names.count == 1 ? names.first : nil
        return "Only one app can use these ports at a time. While Nexus has them, the sites of \(one ?? "these apps") do not open. Give Nexus other ports, or stop its services while you use \(one ?? "the other app")."
    }

    public static let moveButtonTitle = "Use \(movedWebPorts.http) and \(movedWebPorts.https)"

    public static let movedTitle = "Nexus uses ports \(movedWebPorts.http) and \(movedWebPorts.https) now"

    public static func movedMessage(_ names: [String], exampleHost: String?) -> String {
        let sites = exampleHost.map { "Your sites open at https://\($0):\(movedWebPorts.https)." } ?? "Your sites open with port \(movedWebPorts.https) in the URL."
        return "\(sites) \(EnglishList.joined(names)) can use ports \(webPorts.http) and \(webPorts.https) again. Change APP_URL in the .env file of each site yourself. The screen of a WordPress site has a button that changes its URL."
    }
}
