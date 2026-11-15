import Foundation
import NexusCore
import Testing
@testable import NexusConfig

struct ConfigCheckFailureTests {
    private let nginxLines = "/Nexus/check test/nginx/sites/shop.test.conf"
    private let apacheLines = "/Nexus/check test/apache/sites/shop.test.conf"

    @Test func anErrorOfNginxNamesItsFileAndLine() {
        let failure = ConfigCheckFailure(server: .nginx, output: """
            2026/11/14 22:10:19 [emerg] 80862#16766699: unknown directive "client_max_body_siz" in \(nginxLines):2
            nginx: configuration file /Nexus/check test/nginx/nginx.conf test failed
            """)

        #expect(failure.firstError == ConfigCheckError(message: "unknown directive \"client_max_body_siz\"", file: nginxLines, line: 2))
        #expect(failure.firstError.place(inLinesOf: URL(filePath: nginxLines), lineCount: 3) == .siteLines(line: 1))
    }

    @Test func anErrorOfNginxWithInInItsTextKeepsTheWholeText() {
        let failure = ConfigCheckFailure(server: .nginx, output: "2026/11/14 22:11:02 [emerg] 80924#16766785: invalid number of arguments in \"client_max_body_size\" directive in \(nginxLines):2")

        #expect(failure.firstError == ConfigCheckError(message: "invalid number of arguments in \"client_max_body_size\" directive", file: nginxLines, line: 2))
    }

    @Test func anErrorInTheFileOfNexusGetsNoLineOfTheUser() {
        let failure = ConfigCheckFailure(server: .nginx, output: "2026/11/14 22:10:50 [emerg] 80916#16766766: duplicate location \"/\" in /Nexus/check test/nginx/nginx.conf:19")

        #expect(failure.firstError.message == "duplicate location \"/\"")
        #expect(failure.firstError.line == 19)
        #expect(failure.firstError.place(inLinesOf: URL(filePath: nginxLines), lineCount: 2) == .nexus)
    }

    @Test func anErrorInTheLinesOfAnotherSiteIsNoErrorOfTheseLines() {
        let failure = ConfigCheckFailure(server: .nginx, output: "2026/11/14 22:10:19 [emerg] 80862#16766699: unknown directive \"x\" in /Nexus/check test/nginx/sites/blog.test.conf:2")

        #expect(failure.firstError.place(inLinesOf: URL(filePath: nginxLines), lineCount: 2) == .otherSite)
    }

    @Test func anErrorInTheLinesOfAWorkspaceIsAnErrorOfTheseLines() {
        let workspaceLines = "/Nexus/check test/nginx/sites/shop-fix.test.conf"
        let failure = ConfigCheckFailure(server: .nginx, output: "2026/11/14 22:10:19 [emerg] 80862#16766699: unknown directive \"x\" in \(workspaceLines):2")

        #expect(failure.firstError.place(inLinesOf: [URL(filePath: nginxLines), URL(filePath: workspaceLines)], lineCount: 2) == .siteLines(line: 1))
    }

    @Test func aWarningOfNginxBeforeTheErrorIsNoReason() {
        let failure = ConfigCheckFailure(server: .nginx, output: """
            2026/11/14 22:10:19 [warn] 80862#16766699: conflicting server name "a.test" on 0.0.0.0:8080, ignored
            2026/11/14 22:10:19 [crit] 80862#16766699: pread() "/Nexus/check test/nginx/nginx.conf" failed
            """)

        #expect(failure.firstError.message == "pread() \"/Nexus/check test/nginx/nginx.conf\" failed")
    }

    @Test func aMissingBraceGetsTheLastLine() {
        let failure = ConfigCheckFailure(server: .nginx, output: "2026/11/14 22:10:31 [emerg] 80870#16766714: unexpected end of file, expecting \"}\" in \(nginxLines):4")

        #expect(failure.firstError.message == "unexpected end of file, expecting \"}\"")
        #expect(failure.firstError.place(inLinesOf: URL(filePath: nginxLines), lineCount: 2) == .siteLines(line: 2))
    }

    @Test func anErrorOfApacheNamesItsFileAndLine() {
        let failure = ConfigCheckFailure(server: .apache, output: """
            AH00526: Syntax error on line 2 of \(apacheLines):
            Invalid command 'LimitRequestBodyy', perhaps misspelled or defined by a module not included in the server configuration
            """)
        let number = ConfigCheckFailure(server: .apache, output: "AH00526: Syntax error on line 1 of \(apacheLines):\nLimitRequestBody argument is not parsable.")

        #expect(failure.firstError == ConfigCheckError(message: "Invalid command 'LimitRequestBodyy', perhaps misspelled or defined by a module not included in the server configuration", file: apacheLines, line: 2))
        #expect(failure.firstError.place(inLinesOf: URL(filePath: apacheLines), lineCount: 2) == .siteLines(line: 1))
        #expect(number.firstError.message == "LimitRequestBody argument is not parsable")
    }

    @Test func anOpenSectionOfApacheNamesTheInnerFileAndLine() {
        let open = ConfigCheckFailure(server: .apache, output: "httpd: Syntax error on line 15 of /Nexus/check test/apache/httpd.conf: Syntax error on line 3 of \(apacheLines): \(apacheLines):3: <Location> was not closed.")
        let closed = ConfigCheckFailure(server: .apache, output: "httpd: Syntax error on line 15 of /Nexus/check test/apache/httpd.conf: Syntax error on line 3 of \(apacheLines): </VirtualHost> without matching <VirtualHost> section")

        #expect(open.firstError == ConfigCheckError(message: "<Location> was not closed", file: apacheLines, line: 3))
        #expect(closed.firstError == ConfigCheckError(message: "</VirtualHost> without matching <VirtualHost> section", file: apacheLines, line: 3))
    }

    @Test func anUnknownTextIsTheMessage() {
        let failure = ConfigCheckFailure(server: .apache, output: "\nhttpd: Could not open configuration file /Nexus/apache/httpd.conf: No such file or directory\n")

        #expect(failure.firstError == ConfigCheckError(message: "httpd: Could not open configuration file /Nexus/apache/httpd.conf: No such file or directory", file: nil, line: nil))
    }

    @Test func theTextOfAFailureStaysAsBefore() {
        #expect(ConfigCheckFailure(server: .nginx, output: "x").description == "nginx refused the new configuration: x")
        #expect(ConfigCheckFailure(server: .apache, output: "y").description == "httpd refused the new configuration: y")
    }
}
