import Foundation

// The output of a tool that thinks it writes to a terminal, as plain lines for a log view. The
// Laravel installer and the Node.js tools draw spinners with escape sequences. Each frame of a
// spinner would be a line of its own, so a frame replaces the line of the frame before it.
public enum TerminalOutput {
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"
    private static let marks: Set<Character> = ["✔", "✓", "◇", "◆", "●", "■", "▶"]

    public static func lines(_ text: String) -> [String] {
        var result: [String] = []

        for line in plainText(text).components(separatedBy: "\n") {
            let trimmed = line.trimmingTrailingWhitespace()

            if trimmed.isEmpty, result.last?.isEmpty ?? true {
                continue
            }

            if let key = spinnerKey(trimmed), let previous = result.lastIndex(where: { !$0.isEmpty }), spinnerKey(result[previous]) == key {
                result.removeSubrange(previous...)
                result.append(trimmed)
                continue
            }

            result.append(trimmed)
        }

        while result.last?.isEmpty == true {
            result.removeLast()
        }

        return result
    }

    // The end of a log file. A large file is read from its end only.
    public static func tail(of file: URL, lines count: Int, maximumBytes: Int = 16_384) -> [String] {
        Array(lines(tailText(of: file, maximumBytes: maximumBytes)).suffix(count))
    }

    // The read can start in the middle of a line. So that part line goes away. The read starts one
    // byte early. So a line that starts exactly at the limit stays.
    public static func tailText(of file: URL, maximumBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ""
        }

        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start > 0 ? start - 1 : 0)
        let data = (try? handle.readToEnd()) ?? Data()

        guard start > 0 else {
            return String(decoding: data, as: UTF8.self)
        }

        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            return String(decoding: data.dropFirst(), as: UTF8.self)
        }

        return String(decoding: data[data.index(after: newline)...], as: UTF8.self)
    }

    // The label of the spinner that runs now, for example "Setting up frontend dependencies with
    // npm" of the Laravel installer.
    public static func activity(in lines: [String]) -> String? {
        guard let last = lines.last(where: { spinnerKey($0) != nil }),
              let first = last.trimmingCharacters(in: .whitespaces).first,
              isSpinnerFrame(first) else {
            return nil
        }

        let label = String(last.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)

        return label.hasSuffix("...") ? String(label.dropLast(3)) : label
    }

    static func plainText(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var line = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var carriageReturn = false

        // A carriage return before a newline ends the line, as in Windows text. Before other text,
        // it starts the line again, as a progress bar does.
        while let scalar = scalars.next() {
            if carriageReturn, scalar != "\n" {
                line.removeAll()
            }

            carriageReturn = false

            switch scalar {
            case escape:
                skipSequence(&scalars)
            case "\r":
                carriageReturn = true
            case "\n":
                output.append(contentsOf: line)
                output.append("\n")
                line.removeAll()
            case "\t":
                line.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F {
                    line.append(scalar)
                }
            }
        }

        output.append(contentsOf: line)
        return String(output)
    }

    // CSI ends with a byte from @ to ~. OSC, such as a link, ends with BEL or with ESC \.
    private static func skipSequence(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let kind = scalars.next() else {
            return
        }

        switch kind {
        case "[":
            while let scalar = scalars.next(), !(0x40...0x7E).contains(scalar.value) {}
        case "]":
            while let scalar = scalars.next() {
                if scalar == bell {
                    break
                }

                if scalar == escape {
                    _ = scalars.next()
                    break
                }
            }
        default:
            break
        }
    }

    private static func spinnerKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard let first = trimmed.first, isSpinnerFrame(first) || marks.contains(first) else {
            return nil
        }

        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isSpinnerFrame(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var text = self

        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }

        return text
    }
}
