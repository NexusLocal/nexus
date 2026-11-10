import Foundation

// A word of a shell command, for example a path with a space. A word with a special character
// goes in single quotes.
public enum ShellWord {
    public static func quoted(_ text: String) -> String {
        guard text.wholeMatch(of: #/[A-Za-z0-9_\/.:=@%+,-]*/#) == nil else {
            return text
        }

        return "'\(text.replacing("'", with: #"'\''"#))'"
    }
}
