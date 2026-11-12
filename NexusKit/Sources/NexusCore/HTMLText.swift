// Text for the HTML pages of Nexus: the error pages of the web servers and the web page of the
// dumps. The text cannot then end an element or an attribute.
public enum HTMLText {
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
