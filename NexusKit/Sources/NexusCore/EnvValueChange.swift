import Foundation

// One key of a .env that Nexus changes, for a sheet that shows the old and the new value.
// oldValue is nil when the .env has no line for the key. newValue nil removes the line, and the
// old line stays only as a comment line.
public struct EnvValueChange: Codable, Sendable, Hashable {
    public let key: String
    public let oldValue: String?
    public let newValue: String?

    public init(key: String, oldValue: String?, newValue: String?) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}
