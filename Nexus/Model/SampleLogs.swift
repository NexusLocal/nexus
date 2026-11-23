#if DEBUG
import Foundation
import NexusCore

// The log files of the sample sites, for a check of the Logs screen against the design and for
// the screenshots. A debug build with --sample writes them once into a temporary folder. The
// argument --sample-large-log adds a file of 120 MB, for the state while Nexus counts.
enum SampleLogs {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "nexus-sample-logs", directoryHint: .isDirectory)

    static func places(_ places: [LogPlace]) -> [LogPlace] {
        places.map { place in
            let project = folder.appending(path: place.id, directoryHint: .isDirectory)
            write(place, into: project)
            let path = project.path(percentEncoded: false)
            return LogPlace(id: place.id, siteHost: place.siteHost, workspace: place.workspace, kind: place.kind, folder: path, projectFolder: path, php: place.php, hosts: place.hosts, otherFolders: [], appLog: place.appLog)
        }
    }

    private static func write(_ place: LogPlace, into project: URL) {
        let logs = project.appending(path: "storage/logs", directoryHint: .isDirectory)

        guard place.kind == .laravel, !FileManager.default.fileExists(atPath: logs.path(percentEncoded: false)) else {
            return
        }

        try? FileManager.default.createDirectory(at: logs.appending(path: "cronjobs"), withIntermediateDirectories: true)
        try? Data("APP_TIMEZONE=UTC\n".utf8).write(to: project.appending(path: ".env"))
        let root = project.path(percentEncoded: false).hasSuffix("/") ? String(project.path(percentEncoded: false).dropLast()) : project.path(percentEncoded: false)
        var generator = SampleRandom(seed: 7)
        let now = Date.now.timeIntervalSince1970

        try? Data(day(root: root, start: now - 30 * 3600, count: 300, random: &generator).utf8).write(to: logs.appending(path: "laravel-2026-11-22.log"))
        // The newest entry is an exception, so the screen opens with a stack trace.
        let newest = exception(root: root, time: now - 90)
        try? Data((day(root: root, start: now - 3 * 3600, count: 120, random: &generator) + newest).utf8).write(to: logs.appending(path: "laravel.log"))

        let browser = (0..<3).map { index in
            line(now - Double(2400 - index * 60), "local", "ERROR", "[browser] Uncaught TypeError: Cannot read properties of undefined (reading 'total')", #"{"url":"https://shop.test/checkout"}"#)
        }.joined()
        try? Data(browser.utf8).write(to: logs.appending(path: "browser.log"))
        let importLog = logs.appending(path: "cronjobs/import.log")
        try? Data("Starting import of feed suppliers/acme.xml (12400 items)\nImported 12400 items\nDone\n".utf8).write(to: importLog)
        // Lines without a time sort at the last change of their file. An older change keeps the exception on top.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 1800)], ofItemAtPath: importLog.path(percentEncoded: false))

        if CommandLine.arguments.contains("--sample-large-log") {
            // About 1.5 million lines of 3 seconds each end near now.
            writeLargeLog(to: logs.appending(path: "stock.log"), from: now - 4_450_000, random: &generator)
        }
    }

    // 120 MB of short lines. The time of a minute is made once, so the file is ready in seconds.
    private static func writeLargeLog(to file: URL, from start: Double, random: inout SampleRandom) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:"
        var data = Data()
        data.reserveCapacity(121 * 1024 * 1024)
        var minute = -1.0
        var prefix = ""
        var time = start

        while data.count < 120 * 1024 * 1024 {
            time += 3
            let thisMinute = (time / 60).rounded(.down)

            if thisMinute != minute {
                minute = thisMinute
                prefix = formatter.string(from: Date(timeIntervalSince1970: time))
            }

            let second = Int(time) % 60
            let level = ["INFO", "DEBUG", "WARNING"][random.next(3)]
            let text = "[\(prefix)\(second < 10 ? "0" : "")\(second)] local.\(level): Synced the stock of product \(random.next(9999)). {\"batch_id\":\(random.next(50))}\n"
            data.append(contentsOf: text.utf8)
        }

        try? data.write(to: file)
    }

    private static func day(root: String, start: Double, count: Int, random: inout SampleRandom) -> String {
        var time = start
        var text = ""

        for _ in 0..<count {
            time += Double(5 + random.next(85))
            let pick = random.next(100)
            let order = 1000 + random.next(100)

            switch pick {
            case 0..<3: text += exception(root: root, time: time)
            case 3..<25: text += line(time, "testing", "INFO", "A test ran the checkout.", #"{"test":"CheckoutTest"}"#)
            case 25..<35: text += line(time, "local", "WARNING", "Stripe webhook took 2.4 seconds.", #"{"trace_id":"51ab0e7c-2d1f"}"#)
            case 35..<60: text += line(time, "local", "INFO", "Order \(order) paid with iDEAL.", #"{"order_id":\#(order),"trace_id":"9f2c\#(order)-7b1e"}"#)
            case 60..<80: text += line(time, "local", "DEBUG", "Cache hit for the product list.", #"{"key":"products:all"}"#)
            case 80..<84: text += line(time, "local", "CRITICAL", "Connection refused [tcp://127.0.0.1:6379]", nil)
            default: text += line(time, "local", "NOTICE", "User \(1 + random.next(40)) changed the e-mail address.", nil)
            }
        }

        return text
    }

    private static func exception(root: String, time: Double) -> String {
        var frames = [
            "#0 \(root)/vendor/laravel/framework/src/Illuminate/Database/Connection.php(780): Illuminate\\\\Database\\\\Connection->runQueryCallback()",
            "#1 \(root)/app/Models/Order.php(131): Illuminate\\\\Database\\\\Connection->insert()",
            "#2 \(root)/app/Http/Controllers/CheckoutController.php(58): App\\\\Models\\\\Order->markPaid()",
        ]
        frames += (3..<34).map { "#\($0) \(root)/vendor/laravel/framework/src/Illuminate/Pipeline/Pipeline.php(\(100 + $0)): Illuminate\\\\Pipeline\\\\Pipeline->{closure}()" }
        frames += ["#34 \(root)/public/index.php(17): Illuminate\\\\Foundation\\\\Application->handleRequest()", "#35 {main}"]
        let message = "SQLSTATE[23000]: Integrity constraint violation: 1062 Duplicate entry '1042' for key 'invoices.order_id'"
        let context = #"{"userId":18,"exception":"[object] (Illuminate\\Database\\QueryException(code: 23000): "# + message + " at \(root)/vendor/laravel/framework/src/Illuminate/Database/Connection.php:825)\n[stacktrace]\n" + frames.joined(separator: "\n") + "\n\"}"
        return line(time, "local", "ERROR", message, context)
    }

    private static func line(_ time: Double, _ channel: String, _ level: String, _ message: String, _ context: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: time))
        return "[\(stamp)] \(channel).\(level): \(message)\(context.map { " \($0)" } ?? "")\n"
    }
}

// The same sample logs at each launch.
struct SampleRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}
#endif
