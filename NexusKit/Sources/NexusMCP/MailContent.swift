import Foundation

public struct MailLink: Codable, Sendable, Equatable {
    public let url: String
    public let text: String?

    public init(url: String, text: String?) {
        self.url = url
        self.text = text
    }
}

// Nexus never opens a link, because a link can confirm a sign-up. The agent opens it.
public enum MailContent {
    public static func links(html: String, text: String) -> [MailLink] {
        var links: [MailLink] = []
        var seen: Set<String> = []

        for match in html.matches(of: /<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)<\/a\s*>/.ignoresCase()) {
            let url = decodeEntities(String(match.output.1 ?? match.output.2 ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)

            guard isWebLink(url), seen.insert(url).inserted else {
                continue
            }

            let label = plainText(html: String(match.output.3))
            links.append(MailLink(url: url, text: label.isEmpty ? nil : label))
        }

        for match in text.matches(of: /https?:\/\/[^\s<>"'\)\]]+/) {
            let url = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))

            guard seen.insert(url).inserted else {
                continue
            }

            links.append(MailLink(url: url, text: nil))
        }

        return links
    }

    // Only a number near a word such as code or PIN counts. A year or an order number is then no
    // code.
    public static func codes(in text: String) -> [String] {
        let words = /(?i)\b(code|codes|verification|verify|verificatie|one[- ]time|otp|pin|passcode|token|security|login|sign[- ]in|confirm)/
        var codes: [String] = []

        for match in text.matches(of: /(\d{3}[ \-]\d{3}|\d{4,8})/) where standsAlone(match.range, in: text) {
            let start = text.index(match.range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(match.range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex

            guard text[start..<end].contains(words) else {
                continue
            }

            let code = String(match.output.1).filter(\.isNumber)

            if !codes.contains(code) {
                codes.append(code)
            }
        }

        return codes
    }

    // A number in a date, a time, a phone number, a version or a longer number is no code. So the
    // character before it is not a digit, dash, slash, dot or colon. After it comes no digit. Also
    // after it comes no such character with a digit behind it.
    static func standsAlone(_ range: Range<String.Index>, in text: String) -> Bool {
        let joiners: Set<Character> = ["-", "/", ".", ":"]

        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]

            if before.isNumber || joiners.contains(before) {
                return false
            }
        }

        guard range.upperBound < text.endIndex else {
            return true
        }

        let after = text[range.upperBound]

        if after.isNumber {
            return false
        }

        let next = text.index(after: range.upperBound)
        return !(joiners.contains(after) && next < text.endIndex && text[next].isNumber)
    }

    public static func plainText(html: String) -> String {
        let withoutBlocks = html
            .replacing(/<(style|script|head)\b[\s\S]*?<\/\1\s*>/.ignoresCase(), with: " ")
            .replacing(/<br\s*\/?>|<\/(p|div|tr|li|h[1-6])\s*>/.ignoresCase(), with: "\n")
            .replacing(/<[^>]+>/, with: " ")

        return decodeEntities(withoutBlocks)
            .split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isWebLink(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
            .replacing("&nbsp;", with: " ")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
            .replacing("&apos;", with: "'")

        result = result.replacing(/&#(x?)([0-9a-fA-F]+);/) { match in
            let value = match.output.1.isEmpty ? Int(match.output.2) : Int(match.output.2, radix: 16)
            return value.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? String(match.output.0)
        }

        return result.replacing("&amp;", with: "&")
    }
}
