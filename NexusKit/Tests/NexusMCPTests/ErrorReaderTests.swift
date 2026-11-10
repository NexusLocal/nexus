import Foundation
import Testing
@testable import NexusMCP

struct ErrorReaderTests {
    private let file = URL(filePath: "/tmp/laravel.log")

    @Test func aLaravelErrorHasItsMessageAndItsFrames() {
        let text = """
        [2026-11-10 10:00:00] local.INFO: A user logged in
        [2026-11-10 10:01:00] local.ERROR: SQLSTATE[42S02]: Base table or view not found {"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 42S02) at /w/shop/vendor/laravel/framework/src/Connection.php:825)
        [stacktrace]
        #0 /w/shop/app/Http/Controllers/HomeController.php(12): query()
        #1 {main}
        "}
        [2026-11-10 10:02:00] production.CRITICAL: The disk is full
        """

        let errors = ErrorReader.laravelErrors(text: text, file: file, timeZone: .gmt)

        #expect(errors.count == 2)
        #expect(errors[0].level == "ERROR")
        #expect(errors[0].message.hasPrefix("SQLSTATE[42S02]: Base table or view not found"))
        #expect(errors[0].trace == ["#0 /w/shop/app/Http/Controllers/HomeController.php(12): query()", "#1 {main}"])
        #expect(errors[0].time == "2026-11-10 10:01:00")
        #expect(errors[1].level == "CRITICAL")
        #expect(errors[1].trace == nil)
    }

    @Test func pathsBecomeShortAndVendorFramesGoAway() {
        let error = SiteError(source: "laravel", time: nil, message: "Oops at /w/shop/routes/web.php:9", trace: ["#0 /w/shop/vendor/a.php(1): x()", "#1 /w/shop/vendor/b.php(2): y()", "#2 /w/shop/app/Foo.php(3): z()", "#3 {main}"], file: file, date: nil)
        let short = error.relative(to: "/w/shop")

        #expect(short.message == "Oops at routes/web.php:9")
        #expect(short.trace == ["#0 vendor/a.php(1): x()", "#2 app/Foo.php(3): z()", "#3 {main}", "1 more frames left out, most of them in vendor/"])
    }

    @Test func thePrivateFormOfAPathBecomesShortToo() {
        let error = SiteError(source: "laravel", time: nil, message: "at /private/tmp/shop/routes/web.php:9 and /tmp/shop/app/A.php:1", file: file, date: nil)

        #expect(error.relative(to: "/tmp/shop").message == "at routes/web.php:9 and app/A.php:1")
    }

    @Test func thePHPLogGivesOnlyTheErrorsOfTheSite() {
        let text = """
        [10-Nov-2026 10:00:00] NOTICE: fpm is running, pid 1
        [10-Nov-2026 10:01:00 UTC] PHP Fatal error:  Uncaught Error: Call to undefined function foo() in /w/shop/public/index.php:3
        [10-Nov-2026 10:02:00 UTC] PHP Fatal error:  Uncaught Error: x in /w/blog/index.php:3
        [10-Nov-2026 10:03:00 UTC] PHP Warning:  Undefined variable $a in /w/shop/public/index.php on line 4
        """

        let errors = ErrorReader.phpStyleErrors(text: text, source: "php", file: file, limit: 5) { $0.contains("/w/shop") }

        #expect(errors.count == 1)
        #expect(errors[0].message.hasPrefix("PHP Fatal error:  Uncaught Error: Call to undefined function foo()"))
        #expect(errors[0].time == "10-Nov-2026 10:01:00")
    }

    @Test func aFolderWithTheSameStartOrAWorktreeInsideIsAnotherSite() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let log = folder.appending(path: "php-8.4.log")
        try """
        [10-Nov-2026 10:01:00 UTC] PHP Fatal error:  Uncaught Error: a in /w/shop/app/A.php:3
        [10-Nov-2026 10:02:00 UTC] PHP Fatal error:  Uncaught Error: b in /w/shop-admin/app/B.php:3
        [10-Nov-2026 10:03:00 UTC] PHP Fatal error:  Uncaught Error: c in /w/shop/.claude/worktrees/fix/app/C.php:3
        """.write(to: log, atomically: true, encoding: .utf8)

        let errors = ErrorReader.phpErrors(in: log, siteFolder: "/w/shop", otherFolders: ["/w/shop/.claude/worktrees/fix"], limit: 5)

        #expect(errors.map(\.message) == ["PHP Fatal error:  Uncaught Error: a in /w/shop/app/A.php:3"])
    }

    @Test func aRequestWithStatus500OrHigherCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let log = folder.appending(path: "shop.test.log")
        try """
        127.0.0.1 - - [10/Nov/2026:11:00:00 +0100] "GET / HTTP/2.0" 200 86 "-" "curl/8.7.1"
        127.0.0.1 - - [10/Nov/2026:11:00:01 +0100] "POST /register HTTP/2.0" 500 12 "-" "curl/8.7.1"
        127.0.0.1 - - [10/Nov/2026:11:00:02 +0100] "GET /missing HTTP/2.0" 404 12 "-" "curl/8.7.1"
        """.write(to: log, atomically: true, encoding: .utf8)

        let errors = ErrorReader.failedRequests(in: log, limit: 5)

        #expect(errors.map(\.message) == ["POST /register gave status 500"])
    }

    @Test func aNodeErrorKeepsItsStackTrace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let log = folder.appending(path: "app.log")
        try "ready on port 3000\nTypeError: Cannot read properties of undefined\n    at render (/w/app/page.js:4:10)\n    at next (/w/app/node_modules/x.js:1:1)\nGET / 200\n".write(to: log, atomically: true, encoding: .utf8)

        let errors = ErrorReader.nodeErrors(in: log, limit: 5)

        #expect(errors.count == 1)
        #expect(errors[0].trace == ["at render (/w/app/page.js:4:10)", "at next (/w/app/node_modules/x.js:1:1)"])
    }

    @Test func theTailDropsTheCutFirstLine() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let log = folder.appending(path: "big.log")
        try "first line that is long\nsecond\nthird\n".write(to: log, atomically: true, encoding: .utf8)

        #expect(ErrorReader.tail(of: log, bytes: 16) == "second\nthird\n")
    }
}
