import Foundation

// Extensions and modules that load only after another one, for example redis after igbinary and
// dav_fs after dav. A program refuses its configuration when such a pair loads in the wrong order,
// or when one of the pair is missing.
public struct ToggleDependencies: Sendable {
    public let needs: [String: [String]]

    public init(_ needs: [String: [String]]) {
        self.needs = needs
    }

    // On also turns on what the name needs. Off also turns off what needs the name. The changed
    // names start with the name itself.
    public func set(_ name: String, on: Bool, in enabled: Set<String>) -> (enabled: Set<String>, changed: [String]) {
        var result = enabled
        var changed = [name]

        if on {
            let required = needs[name] ?? []
            changed += required.filter { !enabled.contains($0) }.sorted()
            result.formUnion([name] + required)
        } else {
            let dependents = needs.filter { $0.value.contains(name) }.map(\.key).filter(enabled.contains).sorted()
            changed += dependents
            result.subtract([name] + dependents)
        }

        return (result, changed)
    }

    // The names that the name needs and that are not installed. Without them the name does not
    // load. So it cannot turn on.
    public func missing(for name: String, available: Set<String>) -> [String] {
        (needs[name] ?? []).filter { !available.contains($0) }.sorted()
    }

    // The names that can load, in a valid order: the names that another name needs come first. A
    // name that needs a missing name is left out.
    public func loadOrder(_ enabled: Set<String>, available: Set<String>) -> [String] {
        var loaded = enabled.intersection(available)

        for (name, required) in needs where loaded.contains(name) {
            guard required.allSatisfy(available.contains) else {
                loaded.remove(name)
                continue
            }
            loaded.formUnion(required)
        }

        let first = Set(needs.values.flatMap { $0 })
        return loaded.sorted { left, right in
            (first.contains(left) ? 0 : 1, left) < (first.contains(right) ? 0 : 1, right)
        }
    }
}
