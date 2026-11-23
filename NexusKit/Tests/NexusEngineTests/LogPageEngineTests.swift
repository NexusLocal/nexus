import Foundation
import NexusCore
import NexusDumps
import NexusTestSupport
import Synchronization
import Testing
@testable import NexusEngine

// The web page of the logs on the server of the dumps page (group 7). The places come from the
// sites of nexusd. Only a file of the project opens. An open needs the token of the page.
extension NexusEngineTests {
    // A Laravel project with its log. The site points at its public folder.
    private func laravelSite(in root: URL) throws -> EngineState {
        let project = root.appending(path: "shop", directoryHint: .isDirectory)
        let manager = FileManager.default

        for folder in ["public", "bootstrap", "storage/logs", "app/Models"] {
            try manager.createDirectory(at: project.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }

        for file in ["artisan", "bootstrap/app.php", "composer.json", "app/Models/Order.php", "public/index.php"] {
            try Data("<?php\n".utf8).write(to: project.appending(path: file))
        }

        let path = RealPath.trimmed(project.path(percentEncoded: false))
        try Data("APP_TIMEZONE=UTC\n".utf8).write(to: project.appending(path: ".env"))
        let log = """
            [2026-11-23 13:00:00] local.INFO: Order 1042 paid. {"order_id":1042,"trace_id":"9f2c41d0"}
            [2026-11-23 13:02:00] local.ERROR: SQLSTATE[23000]: Duplicate {"exception":"[object] (Illuminate\\\\Database\\\\QueryException(code: 23000): SQLSTATE at \(path)/app/Models/Order.php:131)
            [stacktrace]
            #0 \(path)/app/Models/Order.php(131): App\\\\Models\\\\Order->markPaid()
            #1 /etc/hosts(1): Outside->call()
            #2 {main}
            "}

            """
        try Data(log.utf8).write(to: project.appending(path: "storage/logs/laravel.log"))
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: project.appending(path: "public", directoryHint: .isDirectory), php: "8.5")]
        return state
    }

    private func pageJSON(_ response: PageResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test func theLogPageListsThePlacesAndReadsTheEntriesAndOneEntryOfASite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, state: try laravelSite(in: root))

        try await whileRunning(engine) {
            let places = try pageJSON(await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/places")))
            let entries = try pageJSON(await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/entries", query: ["place": "shop.test", "levels": "error"])))
            let rows = entries["rows"] as? [[String: Any]] ?? []
            let file = try #require(rows.first?["file"] as? String)
            let offset = try #require(rows.first?["offset"] as? UInt64)
            let detail = try pageJSON(await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/entry", query: ["place": "shop.test", "file": file, "offset": String(offset)])))
            let unknownPlace = await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/entries", query: ["place": "other.test"]))
            let noOffset = await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/entry", query: ["place": "shop.test", "file": file]))
            let unknownRoute = await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/nothing"))

            #expect((places["places"] as? [[String: Any]])?.map { $0["id"] as? String } == ["shop.test"])
            #expect((places["places"] as? [[String: Any]])?.first?["kind"] as? String == "laravel")
            #expect(entries["place"] as? String == "shop.test")
            #expect((entries["files"] as? [[String: Any]])?.map { $0["name"] as? String } == ["laravel.log"])
            #expect(rows.map { $0["level"] as? String } == ["error"])
            #expect(rows.first?["exception"] as? String == "QueryException")
            #expect(rows.first?["source"] as? String == "app/Models/Order.php")
            #expect(entries["levelCounts"] as? [String: Int] == ["error": 1, "info": 1])
            #expect((detail["exceptions"] as? [[String: Any]])?.first?["shortName"] as? String == "QueryException")
            #expect(detail["line"] as? Int == 2)
            #expect(unknownPlace.status == 404)
            #expect(noOffset.status == 400)
            #expect(unknownRoute.status == 404)
        }
    }

    @Test func theLogPageOpensOnlyAFileOfTheProjectAndOnlyWithTheToken() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, state: try laravelSite(in: root), servesDumpPage: true)
        let opened = Mutex<[String]>([])
        await engine.logPageStore.setOpener { path, line in
            opened.withLock { $0.append("\(path):\(line.map(String.init) ?? "-")") }
            return true
        }

        try await whileRunning(engine) {
            await engine.startDumpReceiver()
            let server = try #require(await engine.dumpPageServer)
            let entries = try pageJSON(await engine.answerDumpPage(PageRequest(method: "GET", path: "/api/logs/entries", query: ["place": "shop.test", "levels": "error"])))
            let row = try #require((entries["rows"] as? [[String: Any]])?.first)
            let file = try #require(row["file"] as? String)
            let offset = try #require(row["offset"] as? UInt64)
            let body = { (target: String) in #"{"place":"shop.test","file":"\#(file)","offset":\#(offset)\#(target)}"# }

            let page = try PageClient.get("/logs", port: server.port)
            let withoutToken = try PageClient.post("/api/logs/open", json: body(#","exception":0,"frame":0"#), port: server.port, token: "guess")
            let outside = try PageClient.post("/api/logs/open", json: body(#","exception":0,"frame":1"#), port: server.port, token: server.token)
            let frame = try PageClient.post("/api/logs/open", json: body(#","exception":0,"frame":0"#), port: server.port, token: server.token)
            let log = try PageClient.post("/api/logs/open", json: body(""), port: server.port, token: server.token)
            let otherPlace = await engine.answerDumpPage(PageRequest(method: "POST", path: "/api/logs/open", body: Data(#"{"place":"blog.test","file":"\#(file)","offset":\#(offset)}"#.utf8)))

            #expect(page.status == 200)
            #expect(page.body.contains(#"<meta name="nexus-token" content="\#(server.token)">"#))
            #expect(withoutToken.status == 403)
            #expect(outside.status == 403)
            #expect(outside.body.contains("only the files in the project folder of shop.test"))
            #expect(frame.status == 200)
            #expect(log.status == 200)
            #expect(otherPlace.status == 404)
            let paths = opened.withLock { $0 }
            #expect(paths.count == 2)
            #expect(paths.first?.hasSuffix("/shop/app/Models/Order.php:131") == true)
            #expect(paths.last?.hasSuffix("/shop/storage/logs/laravel.log:2") == true)
        }
    }
}
