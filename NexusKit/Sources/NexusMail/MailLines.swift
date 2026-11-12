import Foundation

// SMTP lines end in CRLF. A mail from sendmail can use LF only, as PHP mail() writes it.
enum MailLines {
    static func lines(of data: Data) -> [Data] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
            line.last == UInt8(ascii: "\r") ? Data(line.dropLast()) : Data(line)
        }

        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }

    static func crlf(_ data: Data) -> Data {
        lines(of: data).reduce(into: Data()) { result, line in
            result.append(line)
            result.append(contentsOf: [13, 10])
        }
    }
}
