import Foundation

// The texts of a request through a public link (group 4, 4f). The app, the web page, nexus dumps
// and read_link_requests show the same texts. The script of the web page has the same rules. The
// app has no test target. So the texts of its views are here too.
public enum LinkRequestText {
    // The store keeps the newest 500 requests of each link.
    public static let requestLimit = 500
    // nginx writes the first 64 KB of a body into the request log.
    public static let keptBodyLimit = 65_536
    // nginx keeps a body in memory up to this size. A larger body goes to a file.
    public static let bufferedBodyLimit = 1_048_576

    // The sections and the value of a hidden header of the frame "Dumps · Public link" (owner,
    // 2026-11-20). njs writes hiddenValue in place of the value of a hidden header.
    public static let requestHeadersTitle = "Request headers"
    public static let dataTitle = "Data"
    public static let answerTitle = "Answer"
    public static let hiddenValue = "Hidden by Nexus"
    public static let visitorKey = "Visitor"
    public static let statusKey = "Status"
    public static let sizeKey = "Size"
    public static let typeKey = "Type"
    public static let copyHelp = "Copy the body of this request"
    public static let cutBody = "Nexus keeps only the first 64 KB of this body."
    public static let noBody = "This request has no body."
    public static let detailGone = "Nexus has no headers and no body of this request anymore. The link ended, or newer requests took their place."
    public static let footer = "Nexus keeps the newest \(requestLimit) requests of each public link. It deletes them when the link ends."

    // "Public link" with one link, "Public link of shop.test" with more links.
    public static func filterLabel(host: String, linkCount: Int) -> String {
        linkCount > 1 ? "Public link of \(host)" : "Public link"
    }

    // The help of the globe mark of a row.
    public static func markHelp(host: String) -> String {
        "This request came through the public link of \(host)."
    }

    // The list with the filter of a link before its first request.
    public static func noRequests(host: String) -> String {
        "No request came through the public link of \(host) yet."
    }

    // The title of the confirmation of "Clear…" with the filter of a link.
    public static func clearTitle(host: String) -> String {
        "Remove the requests of the public link of \(host)?"
    }

    // The texts of nexus dumps --public-link and read_link_requests.
    public static let followRefused = "Use --public-link without --follow."
    public static let noLinkWithList = "No public link keeps a list of the requests."
    public static let noLinkRequests = "No request came through a public link yet."

    public static func noList(host: String) -> String {
        "The link to \(host) keeps no list of the requests."
    }

    // An agent cannot turn on the option. So the text says who can.
    public static func noListForAgent(host: String) -> String {
        "\(noList(host: host)) Only the user can turn on Keep a list of the requests, when they share the site."
    }

    public static func unknownRequest(_ id: String, host: String) -> String {
        "Nexus has no request \(id) of the link to \(host). The link ended, or newer requests took its place."
    }

    // "412 bytes", "1.2 KB" or "3.4 MB". 1000 bytes are 1 KB, as the Finder counts. A half rounds up,
    // as the script of the web page does.
    public static func size(_ bytes: Int, locale: Locale = .current) -> String {
        guard bytes >= 1000 else {
            return Count.text(bytes, "byte")
        }

        let kilobytes = (bytes + 50) / 100

        if kilobytes < 10_000 {
            return "\(tenths(kilobytes, locale: locale)) KB"
        }

        return "\(tenths((bytes + 50_000) / 100_000, locale: locale)) MB"
    }

    private static func tenths(_ value: Int, locale: Locale) -> String {
        (Double(value) / 10).formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }

    // The note under the body, or nil when the body shows in full. body is the text of the body. A
    // body that is not text has no text but a size. A body above bufferedBodyLimit went to a file of
    // nginx. So the request log has no part of it.
    public static func bodyNote(body: String?, bytes: Int?, cut: Bool, locale: Locale = .current) -> String? {
        if let body, !body.isEmpty {
            return cut ? cutBody : nil
        }

        guard let bytes, bytes > 0 else {
            return noBody
        }

        guard bytes <= bufferedBodyLimit else {
            return "Nexus did not keep this body of \(size(bytes, locale: locale)), because it is larger than 1 MB."
        }

        return "This body of \(size(bytes, locale: locale)) is not text. So Nexus does not show it."
    }

    // The JSON of a body with an indent of 2 spaces for each level. The keys keep their order and
    // each value keeps its text. nil when the text is not one JSON value. JSONSerialization only
    // checks the text, because it would lose the order of the keys.
    public static func indentedJSON(_ text: String) -> String? {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil else {
            return nil
        }

        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        output.reserveCapacity(bytes.count * 2)

        func breakLine() {
            output.append(UInt8(ascii: "\n"))
            output.append(contentsOf: repeatElement(UInt8(ascii: " "), count: depth * 2))
        }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            if inString {
                output.append(byte)

                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }

                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let close = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                let next = bytes[index...].firstIndex { other in !isJSONSpace(other) }

                if let next, bytes[next] == close {
                    output += [byte, close]
                    index = next + 1
                    continue
                }

                output.append(byte)
                depth += 1
                breakLine()
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                breakLine()
                output.append(byte)
            case UInt8(ascii: ","):
                output.append(byte)
                breakLine()
            case UInt8(ascii: ":"):
                output += [byte, UInt8(ascii: " ")]
            case _ where isJSONSpace(byte):
                continue
            default:
                output.append(byte)
            }
        }

        return String(decoding: output, as: UTF8.self)
    }

    private static func isJSONSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    // The text of a body as the views show it: the indented JSON when the text starts with { or [
    // and is JSON, else the text itself.
    public static func shownBody(_ text: String) -> String {
        let first = text.utf8.first { byte in !isJSONSpace(byte) }

        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else {
            return text
        }

        return indentedJSON(text) ?? text
    }
}
