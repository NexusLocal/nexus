import Foundation

// A Dictionary has no order. An entry in the file of another app gets its keys in the order that a
// person writes them.
public indirect enum JSONText: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([JSONText])
    case object([(String, JSONText)])

    public static func == (lhs: JSONText, rhs: JSONText) -> Bool {
        lhs.compact == rhs.compact
    }

    var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    var compact: String {
        switch self {
        case .string(let text): JSONTextEdit.quoted(text)
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .array(let items): "[" + items.map(\.compact).joined(separator: ", ") + "]"
        case .object(let members): "{" + members.map { "\(JSONTextEdit.quoted($0.0)): \($0.1.compact)" }.joined(separator: ", ") + "}"
        }
    }

    func rendered(indent: String, unit: String) -> String {
        switch self {
        case .object(let members) where !members.isEmpty:
            let inner = indent + unit
            return "{\n" + members.map { "\(inner)\(JSONTextEdit.quoted($0.0)): \($0.1.rendered(indent: inner, unit: unit))" }.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let items) where !items.allSatisfy(\.isScalar):
            let inner = indent + unit
            return "[\n" + items.map { inner + $0.rendered(indent: inner, unit: unit) }.joined(separator: ",\n") + "\n\(indent)]"
        default:
            return compact
        }
    }
}

// Changes one entry in the JSON file of another app and keeps all other bytes: the order of the
// keys, the layout and the comments. VS Code and Zed allow comments and a comma after the last
// item. A rewrite with JSONSerialization would lose them. Each change is checked: the result must
// be valid JSON and must hold the change. Else the change throws, and the file stays as it was.
public enum JSONTextEdit {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public static func value(at path: [String], in text: String) throws -> Any? {
        var current: Any = try parsed(text)

        for key in path {
            guard let object = current as? [String: Any], let next = object[key] else {
                return nil
            }

            current = next
        }

        return current
    }

    public static func setting(_ path: [String], to value: JSONText, in text: String) throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : text
        let document = Document(source)
        var span = try document.topObject()
        var depth = 0

        while depth < path.count - 1 {
            guard let member = span.members.first(where: { $0.key == path[depth] }) else {
                return try checked(document.inserting(path[depth], nested(Array(path[(depth + 1)...]), value), into: span), path: path)
            }

            guard document.bytes[member.valueStart] == UInt8(ascii: "{") else {
                throw Failure(description: "\(path[depth]) is not an object")
            }

            span = try document.object(at: member.valueStart)
            depth += 1
        }

        let key = path[depth]

        if let member = span.members.first(where: { $0.key == key }) {
            let replacement = value.rendered(indent: document.indent(of: member.keyStart), unit: document.unit)
            return try checked(document.replacing(member.valueStart..<member.valueEnd, with: replacement), path: path)
        }

        return try checked(document.inserting(key, value, into: span), path: path)
    }

    public static func removing(_ path: [String], in text: String) throws -> String {
        let document = Document(text)
        var span = try document.topObject()

        for key in path.dropLast() {
            guard let member = span.members.first(where: { $0.key == key }), document.bytes[member.valueStart] == UInt8(ascii: "{") else {
                return text
            }

            span = try document.object(at: member.valueStart)
        }

        guard let index = span.members.firstIndex(where: { $0.key == path.last }) else {
            return text
        }

        let result = document.removing(index, of: span.members.map(\.item), in: span.open..<span.close)
        _ = try parsed(result)
        return result
    }

    public static func addingStrings(_ items: [String], toArrayAt path: [String], in text: String) throws -> String {
        let existing = (try value(at: path, in: text) as? [Any])?.compactMap { $0 as? String }

        guard let existing else {
            if try value(at: path, in: text) != nil {
                throw Failure(description: "\(path.joined(separator: ".")) is not a list")
            }

            return try setting(path, to: .array(items.map(JSONText.string)), in: text)
        }

        var result = text

        for item in items where !existing.contains(item) {
            let document = Document(result)
            let array = try document.array(at: try document.valueStart(at: path))
            result = try document.appending(.string(item), to: array)
        }

        _ = try parsed(result)
        return result
    }

    public static func removingStrings(_ items: Set<String>, fromArrayAt path: [String], in text: String) throws -> String {
        var result = text

        while true {
            let document = Document(result)

            guard (try value(at: path, in: result)) is [Any] else {
                return result
            }

            let array = try document.array(at: try document.valueStart(at: path))

            guard let index = array.elements.firstIndex(where: { element in
                (try? document.decodedString(element.start..<element.end)).map(items.contains) ?? false
            }) else {
                _ = try parsed(result)
                return result
            }

            result = document.removing(index, of: array.elements, in: array.open..<array.close)
        }
    }

    static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    static func nested(_ path: [String], _ value: JSONText) -> JSONText {
        path.reversed().reduce(value) { inner, key in .object([(key, inner)]) }
    }

    // The text without comments and without a comma before } or ], so JSONSerialization reads it.
    static func parsed(_ text: String) throws -> Any {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text

        do {
            return try JSONSerialization.jsonObject(with: Data(Document(source).withoutComments().utf8))
        } catch {
            throw Failure(description: "the file is not valid JSON")
        }
    }

    private static func checked(_ result: String, path: [String]) throws -> String {
        guard try value(at: path, in: result) != nil else {
            throw Failure(description: "the change did not reach \(path.joined(separator: "."))")
        }

        return result
    }
}

// The bytes of a JSON file and the places of its objects and arrays. JSON puts only ASCII
// characters around its values. So the bytes of a UTF-8 text are enough.
private struct Document {
    struct Item {
        let start: Int
        let end: Int
        let comma: Int?
    }

    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
        let comma: Int?

        var item: Item {
            Item(start: keyStart, end: valueEnd, comma: comma)
        }
    }

    struct ObjectSpan {
        let open: Int
        let close: Int
        let members: [Member]
    }

    struct ArraySpan {
        let open: Int
        let close: Int
        let elements: [Item]
    }

    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    private var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    var unit: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let space = line.prefix { $0 == " " || $0 == "\t" }

            if !space.isEmpty, line.dropFirst(space.count).first == "\"" {
                return String(space)
            }
        }

        return "  "
    }

    func topObject() throws -> ObjectSpan {
        let start = trivia(0)

        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else {
            throw JSONTextEdit.Failure(description: "the file does not hold a JSON object")
        }

        let span = try object(at: start)

        guard trivia(span.close + 1) == bytes.count else {
            throw JSONTextEdit.Failure(description: "the file has text after its JSON object")
        }

        return span
    }

    func valueStart(at path: [String]) throws -> Int {
        var span = try topObject()

        for (index, key) in path.enumerated() {
            guard let member = span.members.first(where: { $0.key == key }) else {
                throw JSONTextEdit.Failure(description: "\(key) is missing")
            }

            if index == path.count - 1 {
                return member.valueStart
            }

            span = try object(at: member.valueStart)
        }

        throw JSONTextEdit.Failure(description: "the path is empty")
    }

    func object(at open: Int) throws -> ObjectSpan {
        var index = trivia(open + 1)
        var members: [Member] = []

        while true {
            guard index < bytes.count else {
                throw JSONTextEdit.Failure(description: "an object has no end")
            }

            if bytes[index] == UInt8(ascii: "}") {
                return ObjectSpan(open: open, close: index, members: members)
            }

            guard bytes[index] == UInt8(ascii: "\"") else {
                throw JSONTextEdit.Failure(description: "a key has no quotes")
            }

            let keyStart = index
            let keyEnd = try stringEnd(index)
            let key = try decodedString(index..<keyEnd)
            index = trivia(keyEnd)

            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw JSONTextEdit.Failure(description: "a key has no colon")
            }

            let valueStart = trivia(index + 1)
            let valueEnd = try self.valueEnd(valueStart)
            index = trivia(valueEnd)
            var comma: Int?

            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                comma = index
                index = trivia(index + 1)
            } else if index >= bytes.count || bytes[index] != UInt8(ascii: "}") {
                throw JSONTextEdit.Failure(description: "a comma is missing")
            }

            members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd, comma: comma))
        }
    }

    func array(at open: Int) throws -> ArraySpan {
        guard bytes[open] == UInt8(ascii: "[") else {
            throw JSONTextEdit.Failure(description: "the value is not a list")
        }

        var index = trivia(open + 1)
        var elements: [Item] = []

        while true {
            guard index < bytes.count else {
                throw JSONTextEdit.Failure(description: "a list has no end")
            }

            if bytes[index] == UInt8(ascii: "]") {
                return ArraySpan(open: open, close: index, elements: elements)
            }

            let end = try valueEnd(index)
            var next = trivia(end)
            var comma: Int?

            if next < bytes.count, bytes[next] == UInt8(ascii: ",") {
                comma = next
                next = trivia(next + 1)
            } else if next >= bytes.count || bytes[next] != UInt8(ascii: "]") {
                throw JSONTextEdit.Failure(description: "a comma is missing")
            }

            elements.append(Item(start: index, end: end, comma: comma))
            index = next
        }
    }

    func decodedString(_ range: Range<Int>) throws -> String {
        guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[range])) else {
            throw JSONTextEdit.Failure(description: "a text is not valid")
        }

        return value
    }

    // MARK: Changes

    func inserting(_ key: String, _ value: JSONText, into span: ObjectSpan) -> String {
        let indent = span.members.first.map { self.indent(of: $0.keyStart) } ?? self.indent(of: span.open) + unit
        let member = "\(JSONTextEdit.quoted(key)): \(value.rendered(indent: indent, unit: unit))"
        return adding(member, indent: indent, after: span.members.last?.item, open: span.open, close: span.close)
    }

    func appending(_ value: JSONText, to span: ArraySpan) throws -> String {
        let indent = span.elements.first.map { self.indent(of: $0.start) } ?? self.indent(of: span.open) + unit
        return adding(value.rendered(indent: indent, unit: unit), indent: indent, after: span.elements.last, open: span.open, close: span.close)
    }

    // A new last item. After an item with a comma, the new item gets a comma too, as the file
    // does. A comment at the end of the line of the last item stays on that line.
    private func adding(_ item: String, indent: String, after last: Item?, open: Int, close: Int) -> String {
        guard let last else {
            let inside = bytes[(open + 1)..<close]
            let closingIndent = self.indent(of: open)

            if inside.allSatisfy({ [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains($0) }) {
                return replacing((open + 1)..<close, with: "\n\(indent)\(item)\n\(closingIndent)")
            }

            return replacing((open + 1)..<(open + 1), with: "\n\(indent)\(item)")
        }

        let lineEnd = endOfLine(after: last.comma.map { $0 + 1 } ?? last.end)

        if last.comma != nil {
            return replacing(lineEnd..<lineEnd, with: "\n\(indent)\(item),")
        }

        let withNew = replacing(lineEnd..<lineEnd, with: "\n\(indent)\(item)")
        return Document(withNew).replacing(last.end..<last.end, with: ",")
    }

    // Removes one item with its comma and its line. The last item takes the comma of the item
    // before it, unless the file puts a comma after each item.
    func removing(_ index: Int, of items: [Item], in container: Range<Int>) -> String {
        let item = items[index]

        if let comma = item.comma {
            let start = startOfLine(item.start)
            let end = endOfLine(after: comma + 1)
            let through = end < bytes.count && bytes[end] == UInt8(ascii: "\n") && start != item.start ? end + 1 : end
            let result = replacing(start..<through, with: "")
            return items.count == 1 ? Document(result).collapsedIfEmpty(container.lowerBound) : result
        }

        guard index > 0, let previousComma = items[index - 1].comma else {
            let result = replacing(startOfLine(item.start)..<item.end, with: "")
            return Document(result).collapsedIfEmpty(container.lowerBound)
        }

        return replacing(previousComma..<item.end, with: "")
    }

    private func collapsedIfEmpty(_ open: Int) -> String {
        var index = open + 1

        while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(bytes[index]) {
            index += 1
        }

        guard index < bytes.count, bytes[index] == UInt8(ascii: "}") || bytes[index] == UInt8(ascii: "]") else {
            return text
        }

        return replacing((open + 1)..<index, with: "")
    }

    func replacing(_ range: Range<Int>, with replacement: String) -> String {
        String(decoding: bytes[..<range.lowerBound] + Array(replacement.utf8) + bytes[range.upperBound...], as: UTF8.self)
    }

    func indent(of position: Int) -> String {
        let start = startOfLine(position, keepText: true)
        return String(decoding: bytes[start...].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }, as: UTF8.self)
    }

    // The start of the line of a position. Only white space may come before it, else the line
    // holds more and the position itself counts. keepText gives the line start in any case.
    private func startOfLine(_ position: Int, keepText: Bool = false) -> Int {
        var index = position

        while index > 0, bytes[index - 1] != UInt8(ascii: "\n") {
            if !keepText, bytes[index - 1] != UInt8(ascii: " "), bytes[index - 1] != UInt8(ascii: "\t") {
                return position
            }

            index -= 1
        }

        return index
    }

    // The end of the line after a position, past spaces and a // comment. Other text on the line
    // keeps the position.
    private func endOfLine(after position: Int) -> Int {
        var index = position

        while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "\t") {
            index += 1
        }

        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "/"), bytes[index + 1] == UInt8(ascii: "/") {
            while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
                index += 1
            }

            return index
        }

        return index < bytes.count && bytes[index] != UInt8(ascii: "\n") && bytes[index] != UInt8(ascii: "\r") ? position : index
    }

    // MARK: Reading

    func trivia(_ start: Int) -> Int {
        var index = start

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                index += 1
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
                    index += 1
                }
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index += 2

                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }

                index = min(index + 2, bytes.count)
            } else {
                break
            }
        }

        return index
    }

    private func stringEnd(_ start: Int) throws -> Int {
        var index = start + 1

        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                index += 2
            } else if bytes[index] == UInt8(ascii: "\"") {
                return index + 1
            } else {
                index += 1
            }
        }

        throw JSONTextEdit.Failure(description: "a text has no end")
    }

    private func valueEnd(_ start: Int) throws -> Int {
        guard start < bytes.count else {
            throw JSONTextEdit.Failure(description: "a value is missing")
        }

        switch bytes[start] {
        case UInt8(ascii: "\""):
            return try stringEnd(start)
        case UInt8(ascii: "{"):
            return try object(at: start).close + 1
        case UInt8(ascii: "["):
            return try array(at: start).close + 1
        default:
            let stops: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "/")]
            var index = start

            while index < bytes.count, !stops.contains(bytes[index]) {
                index += 1
            }

            guard index > start else {
                throw JSONTextEdit.Failure(description: "a value is missing")
            }

            return index
        }
    }

    func withoutComments() -> String {
        var result: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: "\"") {
                let end = (try? stringEnd(index)) ?? bytes.count
                result += bytes[index..<end]
                index = end
            } else if byte == UInt8(ascii: "/") {
                let end = trivia(index)

                if end == index {
                    result.append(byte)
                    index += 1
                } else {
                    result.append(UInt8(ascii: " "))
                    index = end
                }
            } else if byte == UInt8(ascii: ","), let next = Optional(trivia(index + 1)), next < bytes.count, bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]") {
                index += 1
            } else {
                result.append(byte)
                index += 1
            }
        }

        return String(decoding: result, as: UTF8.self)
    }
}
