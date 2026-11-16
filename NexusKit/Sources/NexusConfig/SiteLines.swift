import Foundation
import NexusCore

// The custom lines of a site (owner, 2026-11-14). nginx includes the file in the server block of
// the site, before the locations of Nexus. Apache includes it at the end of the VirtualHost. So an
// error of nginx -t or httpd -t names this file and a line of it, and a missing } stays in it.
public enum SiteLinesFile {
    public static let headerLines = 1

    public static func contents(_ lines: [String], server: WebServer) -> String {
        "# Nexus writes this file from the custom \(server.displayName) lines of a site. Change them on the Site screen or with nexus site lines.\n"
            + lines.joined(separator: "\n") + "\n"
    }
}

// The first error of a check. file and line are nil when the program does not name them.
public struct ConfigCheckError: Sendable, Equatable {
    public let message: String
    public let file: String?
    public let line: Int?

    public init(message: String, file: String?, line: Int?) {
        self.message = message
        self.file = file
        self.line = line
    }

    public func place(inLinesOf linesFile: URL, lineCount: Int) -> ConfigCheckPlace {
        place(inLinesOf: [linesFile], lineCount: lineCount)
    }

    // linesFiles hold the same custom lines: the file of one site and the files of its workspaces.
    // The other files in their folder hold the lines of the other sites. An error in another file
    // is in a line of Nexus, for example a second location /.
    public func place(inLinesOf linesFiles: Set<URL>, lineCount: Int) -> ConfigCheckPlace {
        guard let file, let folder = linesFiles.first?.deletingLastPathComponent().path(percentEncoded: false) else {
            return .nexus
        }

        if linesFiles.contains(where: { $0.path(percentEncoded: false) == file }) {
            return line.map { .siteLines(line: Self.userLine($0, lineCount: lineCount)) } ?? .nexus
        }

        return file.hasPrefix(folder) ? .otherSite : .nexus
    }

    // The line in the text of the user. The file starts with one comment line. An error at the end
    // of the file, for example a missing }, gets the last line.
    private static func userLine(_ line: Int, lineCount: Int) -> Int {
        min(max(line - SiteLinesFile.headerLines, 1), max(lineCount, 1))
    }
}

// The file of the first error of a check: the custom lines of the site with the line in the text
// of the user, the custom lines of another site, or a file of Nexus.
public enum ConfigCheckPlace: Sendable, Equatable {
    case siteLines(line: Int)
    case otherSite
    case nexus
}

// nginx -t or httpd -t refused the configuration. The text of the failure stays as it was.
public struct ConfigCheckFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let server: WebServer
    public let output: String

    public init(server: WebServer, output: String) {
        self.server = server
        self.output = output
    }

    public var description: String {
        "\(server.programName) refused the new configuration: \(output)"
    }

    public var firstError: ConfigCheckError {
        let lines = output.components(separatedBy: .newlines)
        let error = server == .apache ? Self.httpdError(in: lines) : Self.nginxError(in: lines)
        let texts = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let firstLine = texts.first { !$0.contains("[warn] ") && !$0.contains("[notice] ") } ?? texts.first ?? output

        return error ?? ConfigCheckError(message: firstLine, file: nil, line: nil)
    }

    // The error log of the Nexus file writes a time and a process first, for example:
    // 2026/11/14 22:10:19 [emerg] 80862#16766699: unknown directive "x" in /path/shop.test.conf:2
    // A [warn] line can come first. It does not stop nginx.
    private static func nginxError(in lines: [String]) -> ConfigCheckError? {
        let levels = ["[emerg] ", "[alert] ", "[crit] "]

        guard let line = lines.first(where: { line in levels.contains { line.contains($0) } }), let start = levels.firstNonNil({ line.range(of: $0) }) else {
            return nil
        }

        var text = String(line[start.upperBound...]).trimmingCharacters(in: .whitespaces)

        if let process = text.prefixMatch(of: #/\d+#\d+: /#) {
            text = String(text[process.range.upperBound...])
        }

        guard let place = text.range(of: " in /", options: .backwards), let colon = text.range(of: ":", options: .backwards), colon.lowerBound > place.upperBound, let number = Int(text[colon.upperBound...]) else {
            return ConfigCheckError(message: text, file: nil, line: nil)
        }

        let file = String(text[text.index(before: place.upperBound)..<colon.lowerBound])
        return ConfigCheckError(message: String(text[..<place.lowerBound]), file: file, line: number)
    }

    // httpd writes a wrong directive on two lines and an open section on one line. The file that
    // includes another file comes first. So the last place wins. For example:
    // AH00526: Syntax error on line 2 of /path/shop.test.conf:
    // Invalid command 'LimitRequestBodyy', perhaps misspelled or defined by a module not included ...
    // httpd: Syntax error on line 15 of /path/httpd.conf: Syntax error on line 3 of
    // /path/shop.test.conf: /path/shop.test.conf:3: <Location> was not closed.
    private static func httpdError(in lines: [String]) -> ConfigCheckError? {
        let prefix = "Syntax error on line "

        guard let index = lines.firstIndex(where: { $0.contains(prefix) }), let start = lines[index].range(of: prefix) else {
            return nil
        }

        var text = String(lines[index][start.lowerBound...]).trimmingCharacters(in: .whitespaces)
        var file: String?
        var number: Int?

        while text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)

            guard let separator = rest.range(of: " of "), let line = Int(rest[..<separator.lowerBound]) else {
                break
            }

            let place = rest[separator.upperBound...]

            if let end = place.range(of: ": ") {
                file = String(place[..<end.lowerBound])
                number = line
                text = String(place[end.upperBound...])
            } else if place.hasSuffix(":") {
                file = String(place.dropLast())
                number = line
                text = lines.dropFirst(index + 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            } else {
                break
            }
        }

        if let place = text.prefixMatch(of: #/\/[^:]*:\d+: /#) {
            text = String(text[place.range.upperBound...])
        }

        if text.hasSuffix(".") {
            text.removeLast()
        }

        return ConfigCheckError(message: text, file: file, line: number)
    }
}
