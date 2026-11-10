import Foundation

// One PHP extension that a project requires. on tells if the PHP of the site has it.
public struct ExtensionState: Codable, Sendable, Equatable {
    public let name: String
    public let requiredBy: [String]
    public let on: Bool
    public let canTurnOn: Bool
}

// The ext-* requirements of composer.json and composer.lock (plan item 7, php_extensions).
public enum ComposerExtensions {
    // The name of each extension with the places that require it, for example composer.json or
    // composer.lock: laravel/framework.
    public static func required(in project: URL) -> [String: [String]] {
        var required: [String: [String]] = [:]

        if let composer = json(project.appending(path: "composer.json")) {
            for section in ["require", "require-dev"] {
                for name in extensions(in: composer[section]) {
                    required[name, default: []].append("composer.json")
                }
            }
        }

        if let lock = json(project.appending(path: "composer.lock")) {
            for section in ["packages", "packages-dev"] {
                for package in (lock[section] as? [[String: Any]]) ?? [] {
                    let packageName = (package["name"] as? String) ?? "a package"

                    for name in extensions(in: package["require"]) where !(required[name] ?? []).contains("composer.lock: \(packageName)") {
                        required[name, default: []].append("composer.lock: \(packageName)")
                    }
                }
            }
        }

        return required
    }

    // The form of a name that php -m and composer.json share: lowercase with _ for a space or a
    // dash. ext-zend-opcache and Zend OPcache both become zend_opcache.
    public static func normalized(_ name: String) -> String {
        name.lowercased().replacing(" ", with: "_").replacing("-", with: "_")
    }

    // The modules in the output of php -m, without the section titles.
    public static func modules(inPHPOutput output: String) -> Set<String> {
        Set(output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .map(normalized))
    }

    private static func extensions(in section: Any?) -> [String] {
        ((section as? [String: Any]) ?? [:]).keys
            .filter { $0.lowercased().hasPrefix("ext-") }
            .map { normalized(String($0.dropFirst(4))) }
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
