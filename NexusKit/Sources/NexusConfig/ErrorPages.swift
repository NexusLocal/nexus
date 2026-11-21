import Foundation
import NexusCore

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

    // The pages of a link with the option "Hide error details and debug tools" (group 4, 4d). A
    // visitor does not know Nexus. So the pages name no host, no path and no command (F13).
    public static let shareError = plainPage(
        title: "The site has an error",
        text: "The site cannot show this page now. The person who shared this link can see the error in Nexus, the app that runs this site on their Mac."
    )

    public static let shareWaits = waitPage(
        title: "The site starts",
        text: "The site does not answer yet. This page tries again each second."
    )

    static func plainPage(title: String, text: String) -> String {
        "<!doctype html><meta charset='utf-8'><title>\(title)</title><p style='font-family: -apple-system, sans-serif'>\(text)</p>"
    }

    // The page of a Laravel site while its dev server starts (owner, 2026-11-15). nexusd writes it
    // as a file. So it can have quotes.
    public static func devServerWaits(host: String, command: String) -> String {
        waitPage(
            title: "The dev server starts",
            text: "The dev server of \(HTMLText.escaped(host)) does not run yet. Nexus starts \(HTMLText.escaped(command)). This page tries again each second. When this page stays, the Site screen of Nexus shows the log under Background processes."
        )
    }

    // The design "Error Page · Dev Server Does Not Start" in nexus.pen (owner, 2026-11-15). It does not
    // load again by itself. A page at least 10 seconds later tries a new start.
    public static func devServerFails(host: String, command: String, buildCommand: String) -> String {
        let host = HTMLText.escaped(host)
        let command = HTMLText.escaped(command)
        let build = HTMLText.escaped(buildCommand)

        return page(
            title: "The dev server of \(host) does not start",
            bodyStyle: "font-family: -apple-system, sans-serif; font-size: 15px; margin: 40px auto; max-width: 640px; padding: 0 16px; line-height: 1.5;",
            body: """
            <h1>The dev server of \(host) does not start</h1>
            <p>Nexus started \(command) for your request, but it stopped with an error.</p>
            <p>The Site screen of Nexus shows the log of the dev server under Background processes.</p>
            <p>After \(build) the site works without the dev server.</p>
            """
        )
    }

    // nginx shows this page for a name that has no site. Only HTTP gets it, because Nexus has no
    // certificate for an unknown name. A script puts the name of the request in the page as text.
    // So a name with HTML in it does nothing.
    public static func unknownSite(hosts: [String], httpsPort: Int) -> String {
        let port = NginxSettings.portSuffix(httpsPort, standard: 443)
        let names = Set(hosts.filter { !$0.hasPrefix("*.") }).sorted()
        let list = names.isEmpty
            ? "<p>Nexus has no sites yet. Add one in Nexus, or run <code>nexus site add &lt;folder&gt;</code> in a terminal.</p>"
            : "<p>These are the sites of Nexus:</p>\n<ul>\n" + names.map { "<li><a href='https://\(HTMLText.escaped($0))\(port)/'>\(HTMLText.escaped($0))</a></li>" }.joined(separator: "\n") + "\n</ul>"

        return page(
            title: "No site with this name",
            bodyStyle: "font-family: -apple-system, sans-serif; margin: 40px auto; max-width: 640px; padding: 0 16px; line-height: 1.5;",
            styles: ["li { margin: 4px 0; }"],
            body: """
            <h1>Nexus has no site with this name</h1>
            <p>No site of Nexus has the name <b id='host'>of this request</b>.</p>
            \(list)
            <script>document.getElementById('host').textContent = location.hostname</script>
            """
        )
    }

    // The frame of a page with a heading. styles come after the style of the heading.
    private static func page(title: String, bodyStyle: String, styles: [String] = [], body: String) -> String {
        let style = [":root { color-scheme: light dark; }", "body { \(bodyStyle) }", "h1 { font-size: 20px; }"] + styles

        return """
        <!doctype html>
        <html lang='en'>
        <meta charset='utf-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <title>\(title)</title>
        <style>
        \(style.joined(separator: "\n"))
        </style>
        \(body)
        </html>

        """
    }
}
