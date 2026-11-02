import Foundation

// The Node version that a project asks for (D21). file names where the text comes from.
public struct NodeVersionHint: Sendable, Equatable {
    public let file: String
    public let text: String

    public init(file: String, text: String) {
        self.file = file
        self.text = text
    }
}

// The Node version line of a site or a folder, and why Nexus picked it. The app shows the reason
// next to the line, for example "22 (from .nvmrc)".
public struct NodeChoice: Codable, Sendable, Hashable {
    public let line: String
    public let reason: String

    public init(line: String, reason: String) {
        self.line = line
        self.reason = reason
    }
}

// Reads the Node version of a project. .nvmrc, .node-version and .tool-versions name a version.
// "engines" in package.json names a range. A .tool-versions file of asdf or mise counts too,
// because projects use it without a .nvmrc.
public enum NodeVersionFiles {
    // The files in the order that Nexus reads them.
    public static let names = [".nvmrc", ".node-version", ".tool-versions", "package.json"]

    // The first folder from folder up to root that names a version wins, as in nvm. A folder
    // outside root is read alone.
    public static func hint(from folder: URL, upTo root: URL) -> NodeVersionHint? {
        let rootPath = RealPath.of(root)
        var current = RealPath.of(folder)

        while true {
            if let hint = hint(in: URL(filePath: current, directoryHint: .isDirectory)) {
                return hint
            }

            guard current != rootPath, RealPath.contains(rootPath, current), current != "/" else {
                return nil
            }

            current = (current as NSString).deletingLastPathComponent
        }
    }

    static func hint(in folder: URL) -> NodeVersionHint? {
        for name in [".nvmrc", ".node-version"] {
            if let text = firstLine(of: folder.appending(path: name)) {
                return NodeVersionHint(file: name, text: text)
            }
        }

        if let text = toolVersionsLine(in: folder) {
            return NodeVersionHint(file: ".tool-versions", text: text)
        }

        if let text = enginesNode(in: folder) {
            return NodeVersionHint(file: "package.json", text: text)
        }

        return nil
    }

    private static func lines(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        return text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func firstLine(of file: URL) -> String? {
        lines(of: file).first
    }

    private static func toolVersionsLine(in folder: URL) -> String? {
        for line in lines(of: folder.appending(path: ".tool-versions")) {
            let words = line.split(whereSeparator: \.isWhitespace)

            if words.count > 1, words[0] == "nodejs" || words[0] == "node" {
                return String(words[1])
            }
        }

        return nil
    }

    private static func enginesNode(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engines = package["engines"] as? [String: Any],
              let node = engines["node"] as? String else {
            return nil
        }

        let range = node.trimmingCharacters(in: .whitespaces)
        return range.isEmpty ? nil : range
    }
}

// Picks a Node line for a project (D21). A version file names a major version. A project that
// asks for a major that Nexus does not have gets the oldest newer line. So .nvmrc 20 gives 22
// (owner, step 7). "engines" in package.json is a range: Nexus takes the newest LTS line in it.
// Without a hint, Nexus takes the newest LTS line. An installed line goes before a line that is
// not installed. So a project runs without a download when it can.
public enum NodeLines {
    // The Node lines of Nexus (D20). A newer manifest can add a line. An installed line counts
    // too.
    public static let nexus = ["22", "24", "26"]

    // The word for "take the version from the project" in nexus site edit --node.
    public static let fromProject = "project"

    // The LTS codenames of nvm, for .nvmrc texts such as lts/jod.
    private static let codenames = [
        "argon": 4, "boron": 6, "carbon": 8, "dubnium": 10, "erbium": 12, "fermium": 14,
        "gallium": 16, "hydrogen": 18, "iron": 20, "jod": 22, "krypton": 24,
    ]

    public static func lines(installed: [String]) -> [String] {
        Set(nexus + installed).sorted { VersionLine.isOlder($0, than: $1) }
    }

    public static func choose(hint: NodeVersionHint?, installed: [String]) -> NodeChoice {
        let lines = lines(installed: installed)

        func newestLTS(of candidates: [String]) -> String {
            let even = candidates.filter { (Int($0) ?? 1) % 2 == 0 }
            let pool = even.isEmpty ? candidates : even
            return VersionLine.newest(pool.filter(installed.contains)) ?? VersionLine.newest(pool) ?? ""
        }

        guard let hint else {
            return NodeChoice(line: newestLTS(of: lines), reason: "newest LTS")
        }

        let text = hint.text.lowercased()
        let found = "from \(hint.file)"
        let asks = "\(hint.file) asks for \(hint.text)"

        switch text {
        case "lts/*", "lts/latest", "lts":
            return NodeChoice(line: newestLTS(of: lines), reason: found)
        case "node", "latest", "current", "stable":
            return NodeChoice(line: VersionLine.newest(lines.filter(installed.contains)) ?? VersionLine.newest(lines) ?? "", reason: found)
        default:
            break
        }

        if text.hasPrefix("lts/") {
            guard let major = codenames[String(text.dropFirst(4))] else {
                return NodeChoice(line: newestLTS(of: lines), reason: asks)
            }

            return choice(major: major, lines: lines, found: found, asks: asks)
        }

        guard let range = NodeRange(text) else {
            return NodeChoice(line: newestLTS(of: lines), reason: asks)
        }

        // A version file names a version. Nexus has only the newest patch of each line. So only
        // the major counts there.
        if hint.file != "package.json", let major = range.firstMajor {
            return choice(major: major, lines: lines, found: found, asks: asks)
        }

        let inRange = lines.filter { Int($0).map(range.admits(major:)) ?? false }

        if !inRange.isEmpty {
            return NodeChoice(line: newestLTS(of: inRange), reason: found)
        }

        guard let major = range.firstMajor else {
            return NodeChoice(line: newestLTS(of: lines), reason: asks)
        }

        return choice(major: major, lines: lines, found: found, asks: asks)
    }

    // The line of that major, else the oldest newer line, else the newest line.
    private static func choice(major: Int, lines: [String], found: String, asks: String) -> NodeChoice {
        if lines.contains(String(major)) {
            return NodeChoice(line: String(major), reason: found)
        }

        let newer = lines.first { (Int($0) ?? 0) > major }
        return NodeChoice(line: newer ?? lines.last ?? String(major), reason: asks)
    }
}

// A range of node-semver, for "engines" in package.json: ">=18.0.0", "^20 || ^22" or
// "18 - 20". Nexus only needs to know if a range admits some version of a major. Prerelease tags
// do not count.
struct NodeRange {
    private struct Version: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (left: Version, right: Version) -> Bool {
            (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
        }
    }

    private struct Bound {
        let version: Version
        let inclusive: Bool
    }

    // A nil bound has no limit on that side.
    private struct Interval {
        var lower: Bound?
        var upper: Bound?
        var empty = false

        static let all = Interval()
        static let none = Interval(empty: true)

        func intersected(with other: Interval) -> Interval {
            guard !empty, !other.empty else {
                return .none
            }

            var result = self

            if let bound = other.lower, result.lower.map({ bound.version > $0.version || bound.version == $0.version && !bound.inclusive }) ?? true {
                result.lower = bound
            }

            if let bound = other.upper, result.upper.map({ bound.version < $0.version || bound.version == $0.version && !bound.inclusive }) ?? true {
                result.upper = bound
            }

            if let lower = result.lower, let upper = result.upper {
                result.empty = lower.version > upper.version || lower.version == upper.version && !(lower.inclusive && upper.inclusive)
            }

            return result
        }
    }

    // The numbers of a partial version such as 20, 20.10 or 20.x. An x ends it.
    private struct Partial {
        let numbers: [Int]

        init?(_ text: Substring) {
            var numbers: [Int] = []
            let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""

            for part in core.split(separator: ".", omittingEmptySubsequences: false).prefix(3) {
                if ["x", "X", "*"].contains(part) {
                    break
                }

                guard let number = Int(part), number >= 0 else {
                    return nil
                }

                numbers.append(number)
            }

            self.numbers = numbers
        }

        init(numbers: [Int]) {
            self.numbers = numbers
        }

        var filled: Version {
            Version(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0)
        }

        // The first version after every version that this partial names, for example 21.0.0
        // after 20 and 20.11.0 after 20.10.
        var next: Version {
            switch numbers.count {
            case 1: Version(major: numbers[0] + 1, minor: 0, patch: 0)
            case 2: Version(major: numbers[0], minor: numbers[1] + 1, patch: 0)
            default: Version(major: numbers[0], minor: numbers[1], patch: numbers[2] + 1)
            }
        }
    }

    private let intervals: [Interval]
    let firstMajor: Int?

    init?(_ text: String) {
        var intervals: [Interval] = []
        var firstMajor: Int?

        for alternative in text.components(separatedBy: "||") {
            var interval = Interval.all
            let hyphen = alternative.components(separatedBy: " - ")

            if hyphen.count == 2 {
                guard let from = Self.partial(hyphen[0]), let to = Self.partial(hyphen[1]) else {
                    return nil
                }

                interval = Self.interval(">=", from).intersected(with: Self.interval("<=", to))
                firstMajor = firstMajor ?? from.numbers.first
            } else {
                for token in Self.tokens(alternative) {
                    let operation = String(token.prefix { "<>=~^".contains($0) })

                    guard let partial = Self.partial(token.dropFirst(operation.count)), [">=", "<=", ">", "<", "=", "~", "~>", "^", ""].contains(operation) else {
                        return nil
                    }

                    interval = interval.intersected(with: Self.interval(operation, partial))
                    firstMajor = firstMajor ?? partial.numbers.first
                }
            }

            intervals.append(interval)
        }

        self.intervals = intervals
        self.firstMajor = firstMajor
    }

    func admits(major: Int) -> Bool {
        let line = Interval(
            lower: Bound(version: Version(major: major, minor: 0, patch: 0), inclusive: true),
            upper: Bound(version: Version(major: major + 1, minor: 0, patch: 0), inclusive: false)
        )

        return intervals.contains { !$0.intersected(with: line).empty }
    }

    // An operator can have a space after it, as in ">= 20.9.0".
    private static func tokens(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var pending = ""

        for word in text.split(whereSeparator: \.isWhitespace) {
            if word.allSatisfy({ "<>=~^".contains($0) }) {
                pending += word
                continue
            }

            tokens.append(Substring(pending + word))
            pending = ""
        }

        return pending.isEmpty ? tokens : tokens + [Substring(pending)]
    }

    private static func partial(_ text: some StringProtocol) -> Partial? {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))

        if trimmed.first == "v" || trimmed.first == "=" {
            trimmed = trimmed.dropFirst()
        }

        return Partial(trimmed)
    }

    private static func interval(_ operation: String, _ partial: Partial) -> Interval {
        guard !partial.numbers.isEmpty else {
            return operation == "<" || operation == ">" ? .none : .all
        }

        let full = partial.numbers.count == 3
        let lowerAt = { (version: Version, inclusive: Bool) in Interval(lower: Bound(version: version, inclusive: inclusive)) }
        let upperAt = { (version: Version, inclusive: Bool) in Interval(upper: Bound(version: version, inclusive: inclusive)) }

        switch operation {
        case ">=":
            return lowerAt(partial.filled, true)
        case ">":
            return full ? lowerAt(partial.filled, false) : lowerAt(partial.next, true)
        case "<":
            return upperAt(partial.filled, false)
        case "<=":
            return full ? upperAt(partial.filled, true) : upperAt(partial.next, false)
        case "~", "~>":
            let upper = partial.numbers.count == 1 ? partial.next : Version(major: partial.numbers[0], minor: partial.numbers[1] + 1, patch: 0)
            return lowerAt(partial.filled, true).intersected(with: upperAt(upper, false))
        case "^":
            let first = partial.numbers.firstIndex { $0 != 0 } ?? partial.numbers.count - 1
            let upper = Partial(numbers: Array(partial.numbers.prefix(first + 1))).next
            return lowerAt(partial.filled, true).intersected(with: upperAt(upper, false))
        default:
            return full
                ? lowerAt(partial.filled, true).intersected(with: upperAt(partial.filled, true))
                : lowerAt(partial.filled, true).intersected(with: upperAt(partial.next, false))
        }
    }
}
