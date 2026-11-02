import NexusCore

// A unique value for each env key (D43). A text marker starts with the number of the key, so
// arithmetic on the value does not stop PHP and a cast to int keeps the number. It has only
// lowercase letters and digits, so it survives Str::slug. The step between two numbers is a prime
// number. So a round number that an application adds to a value does not point at another key.
struct ProbeMarkers {
    private static let firstNumber = 7_000_000
    private static let step = 1009
    private static let suffix = "nxm"

    let textEnvironment: [String: String]
    let numericEnvironment: [String: String]
    private let keysByNumber: [Int: String]

    init(keys: [String]) {
        let numbers = keys.enumerated().map { (key: $1, number: Self.firstNumber + $0 * Self.step) }

        textEnvironment = Dictionary(uniqueKeysWithValues: numbers.map { ($0.key, "\($0.number)\(Self.suffix)") })
        numericEnvironment = Dictionary(uniqueKeysWithValues: numbers.map { ($0.key, String($0.number)) })
        keysByNumber = Dictionary(uniqueKeysWithValues: numbers.map { ($0.number, $0.key) })
    }

    // A Redis index can reach the configuration only as a number. A database name can be text
    // around the value of the key.
    func workspaceEnvironment(databaseKeys: [String], redisKeys: [String]) -> [String: String] {
        let numeric = numericEnvironment.filter { redisKeys.contains($0.key) }
        let text = textEnvironment.filter { databaseKeys.contains($0.key) }

        return numeric.merging(text) { _, text in text }
    }

    // A text marker that survived names its keys. A number that is the number of a key names
    // that key: the text pass gives this number after a cast, the numeric pass for a setting
    // that lost the text marker in another way, for example through FILTER_VALIDATE_INT.
    func setting(value: ConfigValue, textPass: ConfigValue?, numericPass: ConfigValue?) -> ConfigSetting {
        // A value that no marker changed is fixed, also when it is the number of a key.
        if textPass == value, numericPass == value {
            return ConfigSetting(value: value)
        }

        if case .text(let text) = textPass {
            let lowercased = text.lowercased()
            let markers = textEnvironment.filter { lowercased.contains($0.value) }

            if !markers.isEmpty {
                return ConfigSetting(value: value, keys: markers.keys.sorted(), exact: markers.values.contains(text))
            }
        }

        if let key = key(numbered: textPass) ?? key(numbered: numericPass) {
            return ConfigSetting(value: value, keys: [key], exact: true)
        }

        return ConfigSetting(value: value)
    }

    private func key(numbered value: ConfigValue?) -> String? {
        switch value {
        case .number(let number):
            Int(exactly: number).flatMap { keysByNumber[$0] }
        case .text(let text):
            Int(text).flatMap { keysByNumber[$0] }
        default:
            nil
        }
    }
}
