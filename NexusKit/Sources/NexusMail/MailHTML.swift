import Foundation

// A mail without its own font shows in the font of macOS, as in Apple Mail, and not in the Times
// of a web view. The style comes first in the head, so each font of the mail itself wins. Text
// before the doctype would put the page in quirks mode, so the style goes after it.
public enum MailHTML {
    public static let defaultStyle = "<style>body{font-family:-apple-system,system-ui,sans-serif;font-size:14px;line-height:1.4}</style>"

    public static func withDefaultFont(_ html: String) -> String {
        let place = html.firstMatch(of: /<head(\s[^>]*)?>/.ignoresCase())?.range.upperBound
            ?? html.firstMatch(of: /<html(\s[^>]*)?>/.ignoresCase())?.range.upperBound
            ?? html.firstMatch(of: /<!doctype[^>]*>/.ignoresCase())?.range.upperBound

        guard let place else {
            return defaultStyle + html
        }

        var result = html
        result.insert(contentsOf: defaultStyle, at: place)
        return result
    }
}
