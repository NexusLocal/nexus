// "a", "a and b" or "a, b and c". A list format of the system would use the language of the Mac
// in an English sentence.
public enum EnglishList {
    public static func joined(_ items: [String]) -> String {
        guard let last = items.last else {
            return ""
        }

        return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) and \(last)"
    }
}

extension String {
    // The text with an upper case first letter, for example a list at the start of a sentence.
    // capitalized of Foundation changes each word.
    public var firstLetterUppercased: String {
        prefix(1).uppercased() + dropFirst()
    }
}
