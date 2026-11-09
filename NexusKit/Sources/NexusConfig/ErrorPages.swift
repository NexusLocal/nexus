import Foundation

// The pages that nginx and Apache show when a site cannot answer. nginx reads a $ in a text as a
// variable, and Apache reads %{ as an expression. A text of a server ends at a double quote. So the
// pages use single quotes and have none of these characters.
public enum ErrorPages {
    public static let unknownSiteFile = "unknown-site.html"

    // PHP-FPM stops and starts again for a moment after a change of the PHP settings, and nexusd
    // starts it again after a crash. nginx then gives a 502 and Apache a 503. The page tries again
    // each second and shows the site when it answers.
    static let phpWaits = waitPage(
        title: "PHP starts",
        text: "PHP does not answer. This page tries again each second and shows the site when PHP answers. PHP stops for a moment after a change of its settings. When this page stays, the PHP screen of Nexus shows the state and the log."
    )

    static let apacheWaits = waitPage(
        title: "Apache starts",
        text: "Apache does not answer. This page tries again each second and shows the site when Apache answers. When this page stays, the Webservers screen of Nexus shows the state and the log."
    )

    // A Node.js app does not answer while it starts or after a crash, and Nexus starts it again.
    static let appWaits = waitPage(
        title: "The app starts",
        text: "The app does not answer yet. Nexus starts it, and this page tries again each second. The Site screen of Nexus shows the state and the log of the app."
    )

    static func waitPage(title: String, text: String) -> String {
        "<!doctype html><meta charset='utf-8'><meta http-equiv='refresh' content='1'><title>\(title)</title><p style='font-family: -apple-system, sans-serif'>\(text)</p>"
    }

    // nginx shows this page for a name that has no site. Only HTTP gets it, because Nexus has no
    // certificate for an unknown name. A script puts the name of the request in the page as text.
    // So a name with HTML in it does nothing.
    public static func unknownSite(hosts: [String], httpsPort: Int) -> String {
        let port = httpsPort == 443 ? "" : ":\(httpsPort)"
        let names = Set(hosts.filter { !$0.hasPrefix("*.") }).sorted()
        let list = names.isEmpty
            ? "<p>Nexus has no sites yet. Add one in Nexus, or run <code>nexus site add &lt;folder&gt;</code> in a terminal.</p>"
            : "<p>These are the sites of Nexus:</p>\n<ul>\n" + names.map { "<li><a href='https://\(escaped($0))\(port)/'>\(escaped($0))</a></li>" }.joined(separator: "\n") + "\n</ul>"

        return """
        <!doctype html>
        <html lang='en'>
        <meta charset='utf-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <title>No site with this name</title>
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, sans-serif; margin: 40px auto; max-width: 640px; padding: 0 16px; line-height: 1.5; }
        h1 { font-size: 20px; }
        li { margin: 4px 0; }
        </style>
        <h1>Nexus has no site with this name</h1>
        <p>No site of Nexus has the name <b id='host'>of this request</b>.</p>
        \(list)
        <script>document.getElementById('host').textContent = location.hostname</script>
        </html>

        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
