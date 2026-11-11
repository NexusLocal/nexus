import Foundation

// A PHP string in single quotes. PHP reads it as it is, except for \\ and \'. So only a backslash
// and a quote get a backslash.
public enum PHPString {
    public static func quoted(_ text: String) -> String {
        "'\(text.replacing("\\", with: "\\\\").replacing("'", with: "\\'"))'"
    }
}
