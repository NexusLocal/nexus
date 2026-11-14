import Foundation

// "1 dump" or "1248 dumps". The number has no grouping of digits, as in all texts of Nexus. The
// noun gets an s for more than one. A noun such as query gives its own plural: "24 queries".
public enum Count {
    public static func text(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(plural ?? "\(noun)s")"
    }
}
