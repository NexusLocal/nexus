import Foundation

// The result of the change of one value of a dump.
public enum ValueRewrite: Equatable, Sendable {
    case unchanged
    case changed([UInt8], links: Int)
    // Serialized PHP that Nexus cannot change safely. The value stays as it is, and WP-CLI changes
    // its table after the load.
    case unsafe
}

// WordPress keeps many settings as serialized PHP, with the length of each string in bytes. A plain
// replace keeps the old length, and PHP then cannot read the value. So the links change inside the
// structure, and each length is written again. A value whose lengths do not match its structure is
// no serialized PHP, or it was broken before. It changes as plain text, as WP-CLI does.
public enum SerializedPHP {
    public static func rewrite(_ value: [UInt8], with rewriter: LiveURLRewriter) -> ValueRewrite {
        guard rewriter.mayContain(value) else {
            return .unchanged
        }

        if looksSerialized(value) {
            var walker = Walker(input: value, rewriter: rewriter)

            switch walker.wholeValue() {
            case .valid:
                guard walker.links > 0 else {
                    return .unchanged
                }

                return isValid(walker.output) ? .changed(walker.output, links: walker.links) : .unsafe
            case .unsupported:
                return .unsafe
            case .mismatch:
                break
            }
        }

        return rewriter.rewrite(value).map { .changed($0.bytes, links: $0.links) } ?? .unchanged
    }

    public static func isValid(_ value: [UInt8]) -> Bool {
        var walker = Walker(input: value, rewriter: nil)
        return walker.wholeValue() == .valid
    }

    static func looksSerialized(_ value: [UInt8]) -> Bool {
        guard value.count >= 2 else {
            return false
        }

        if value[0] == UInt8(ascii: "N") {
            return value[1] == UInt8(ascii: ";")
        }

        return "aOCsidbErRS".utf8.contains(value[0]) && value[1] == Byte.colon
    }

    enum Outcome {
        case valid
        case mismatch
        case unsupported
    }

    struct Walker {
        let input: [UInt8]
        let rewriter: LiveURLRewriter?
        var index = 0
        var output: [UInt8] = []
        var links = 0
        var unsupported = false

        static let maximumDepth = 256

        init(input: [UInt8], rewriter: LiveURLRewriter?) {
            self.input = input
            self.rewriter = rewriter
            output.reserveCapacity(input.count + 64)
        }

        mutating func wholeValue() -> Outcome {
            let valid = value(depth: 0) && index == input.count

            if unsupported {
                return .unsupported
            }

            return valid ? .valid : .mismatch
        }

        private mutating func value(depth: Int) -> Bool {
            guard depth < Self.maximumDepth else {
                unsupported = true
                return false
            }

            guard index < input.count else {
                return false
            }

            switch input[index] {
            case UInt8(ascii: "N"):
                return copy("N;")
            case UInt8(ascii: "b"), UInt8(ascii: "i"), UInt8(ascii: "d"), UInt8(ascii: "r"), UInt8(ascii: "R"):
                return scalar()
            case UInt8(ascii: "s"):
                return string()
            case UInt8(ascii: "a"):
                guard copy("a:"), let count = number(), copy(":{") else {
                    return false
                }

                return members(count * 2, depth: depth) && copy("}")
            case UInt8(ascii: "O"):
                guard copy("O:"), let length = number(), copy(":\""), take(length), copy("\":"), let count = number(), copy(":{") else {
                    return false
                }

                return members(count * 2, depth: depth) && copy("}")
            case UInt8(ascii: "E"):
                guard copy("E:"), let length = number(), copy(":\""), take(length) else {
                    return false
                }

                return copy("\";")
            case UInt8(ascii: "C"):
                return custom()
            case UInt8(ascii: "S"):
                unsupported = true
                return false
            default:
                return false
            }
        }

        // The keys stay as they are, as with WP-CLI. A changed key could become the same as another
        // key.
        private mutating func members(_ count: Int, depth: Int) -> Bool {
            for member in 0..<count {
                guard member.isMultiple(of: 2) ? key() : value(depth: depth + 1) else {
                    return false
                }
            }

            return true
        }

        private mutating func key() -> Bool {
            guard index < input.count else {
                return false
            }

            if input[index] == UInt8(ascii: "i") {
                return scalar()
            }

            let start = index

            guard copy("s:"), let length = digits(), has(":\""), index + 2 + length + 2 <= input.count else {
                return false
            }

            let end = index + 2 + length

            guard input[end] == UInt8(ascii: "\""), input[end + 1] == UInt8(ascii: ";") else {
                return false
            }

            output.append(contentsOf: input[(start + 2)..<(end + 2)])
            index = end + 2
            return true
        }

        // i:5; b:1; d:0.5; d:INF; r:2; R:2;
        private mutating func scalar() -> Bool {
            let start = index
            index += 1

            guard index < input.count, input[index] == Byte.colon else {
                return false
            }

            index += 1

            let allowed = Set("0123456789+-.EINFAeinfa".utf8)

            while index < input.count, input[index] != UInt8(ascii: ";") {
                guard allowed.contains(input[index]) else {
                    return false
                }

                index += 1
            }

            guard index < input.count, index > start + 2 else {
                return false
            }

            index += 1
            output.append(contentsOf: input[start..<index])
            return true
        }

        private mutating func string() -> Bool {
            index += 1

            guard index < input.count, input[index] == Byte.colon else {
                return false
            }

            index += 1

            guard let length = digits(), length >= 0, has(":\""), index + 2 + length + 2 <= input.count else {
                return false
            }

            let start = index + 2
            let end = start + length

            guard input[end] == UInt8(ascii: "\""), input[end + 1] == UInt8(ascii: ";") else {
                return false
            }

            let inner = Array(input[start..<end])
            let changed = changedString(inner)

            output.append(contentsOf: "s:\(changed.count):\"".utf8)
            output.append(contentsOf: changed)
            output.append(contentsOf: "\";".utf8)
            index = end + 2
            return true
        }

        // C:11:"ArrayObject":21:{x:i:0;a:0:{};m:a:0:{}} keeps its own format inside the braces.
        private mutating func custom() -> Bool {
            guard copy("C:"), let length = number(), copy(":\""), take(length), copy("\":") else {
                return false
            }

            guard let contentLength = digits(), has(":{"), index + 2 + contentLength + 1 <= input.count else {
                return false
            }

            let start = index + 2
            let end = start + contentLength

            guard input[end] == UInt8(ascii: "}") else {
                return false
            }

            let content = Array(input[start..<end])
            var changed = content

            // The content of ArrayObject and similar classes holds serialized strings with their
            // own lengths. A plain change would break them, so WP-CLI changes such a value.
            if let rewriter, rewriter.mayContain(content), Self.holdsSerializedStrings(content), rewriter.rewrite(content) != nil {
                unsupported = true
                return false
            }

            if let rewriter, let result = rewriter.rewrite(content) {
                changed = result.bytes
                links += result.links
            }

            output.append(contentsOf: "\(changed.count):{".utf8)
            output.append(contentsOf: changed)
            output.append(UInt8(ascii: "}"))
            index = end + 1
            return true
        }

        static func holdsSerializedStrings(_ content: [UInt8]) -> Bool {
            guard content.count >= 3 else {
                return false
            }

            for index in 0..<(content.count - 2) where content[index] == UInt8(ascii: "s") && content[index + 1] == Byte.colon && Byte.isDigit(content[index + 2]) {
                return true
            }

            return false
        }

        // A string can hold serialized PHP again, or JSON. Serialized PHP inside changes first.
        private mutating func changedString(_ inner: [UInt8]) -> [UInt8] {
            guard let rewriter, rewriter.mayContain(inner) else {
                return inner
            }

            if SerializedPHP.looksSerialized(inner) {
                var nested = Walker(input: inner, rewriter: rewriter)

                switch nested.wholeValue() {
                case .valid:
                    links += nested.links
                    return nested.output
                case .unsupported:
                    unsupported = true
                    return inner
                case .mismatch:
                    break
                }
            }

            guard let result = rewriter.rewrite(inner) else {
                return inner
            }

            links += result.links
            return result.bytes
        }

        private mutating func copy(_ text: String) -> Bool {
            guard has(text) else {
                return false
            }

            output.append(contentsOf: text.utf8)
            index += text.utf8.count
            return true
        }

        private func has(_ text: String) -> Bool {
            let bytes = Array(text.utf8)

            guard index + bytes.count <= input.count else {
                return false
            }

            return input[index..<(index + bytes.count)].elementsEqual(bytes)
        }

        private mutating func take(_ length: Int) -> Bool {
            guard length >= 0, index + length <= input.count else {
                return false
            }

            output.append(contentsOf: input[index..<(index + length)])
            index += length
            return true
        }

        private mutating func number() -> Int? {
            guard let value = digits() else {
                return nil
            }

            output.append(contentsOf: String(value).utf8)
            return value
        }

        private mutating func digits() -> Int? {
            let start = index
            var value = 0

            while index < input.count, Byte.isDigit(input[index]) {
                value = value &* 10 &+ Int(input[index] - 48)
                index += 1

                if index - start > 12 {
                    return nil
                }
            }

            return index > start ? value : nil
        }
    }
}
