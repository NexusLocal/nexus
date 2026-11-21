import Foundation

func regexMatches(_ pattern: String, _ text: String, ignoresCase: Bool = false) throws -> Bool {
    let regex = try NSRegularExpression(pattern: pattern, options: ignoresCase ? [.caseInsensitive] : [])
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}
