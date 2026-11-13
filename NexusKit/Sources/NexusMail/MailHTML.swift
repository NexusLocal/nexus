import Foundation

// A mail without its own font shows in the font of macOS, as in Apple Mail, and not in the Times
// of a web view. The style comes first in the head, so each font of the mail itself wins. Text
// before the doctype would put the page in quirks mode, so the style goes after it.
public enum MailHTML {
    public static let defaultStyle = "<style>body{font-family:-apple-system,system-ui,sans-serif;font-size:14px;line-height:1.4}</style>"

    // A mail without dark colors of its own gets inverted colors. The lower contrast turns white into
    // #272727, the gray of the groups of the app in dark mode, and black into a light gray. The
    // images get inverted a second time, so they keep their own colors, only a little dimmer. An
    // image inside an element with a background image gets that second inversion from the element
    // already. The filter does not reach the scroll bar of the page, so the scroll bar gets dark
    // colors itself.
    public static let darkStyle = "<style>html{background:#FFFFFF;filter:invert(1) hue-rotate(180deg) contrast(0.694)}img,picture,video,svg,[background],[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg)}:is([background],[style*=\"background-image\"]) :is(img,picture,video,svg){filter:none}::-webkit-scrollbar{width:11px;background:#272727}::-webkit-scrollbar-thumb{background:#5A5A5E;border:2px solid #272727;border-radius:6px}</style>"

    public static func withDefaultFont(_ html: String) -> String {
        inserting(defaultStyle, into: html)
    }

    // A mail with its own dark colors keeps them. The web view then only needs a dark appearance.
    public static func forDisplay(_ html: String, dark: Bool) -> String {
        guard dark, !hasDarkColors(html) else {
            return withDefaultFont(html)
        }

        return inserting(defaultStyle + darkStyle, into: html)
    }

    // A media query for dark mode, a color-scheme meta tag with dark in any order of its
    // attributes, or the CSS property color-scheme with dark.
    static func hasDarkColors(_ html: String) -> Bool {
        html.contains(/prefers-color-scheme\s*:\s*dark/.ignoresCase())
            || html.contains(/<meta[^>]*color-scheme[^>]*dark[^>]*>|<meta[^>]*dark[^>]*color-scheme[^>]*>/.ignoresCase())
            || html.contains(/color-scheme\s*:\s*[^;}"'<]*dark/.ignoresCase())
    }

    private static func inserting(_ style: String, into html: String) -> String {
        let place = html.firstMatch(of: /<head(\s[^>]*)?>/.ignoresCase())?.range.upperBound
            ?? html.firstMatch(of: /<html(\s[^>]*)?>/.ignoresCase())?.range.upperBound
            ?? html.firstMatch(of: /<!doctype[^>]*>/.ignoresCase())?.range.upperBound

        guard let place else {
            return style + html
        }

        var result = html
        result.insert(contentsOf: style, at: place)
        return result
    }
}
