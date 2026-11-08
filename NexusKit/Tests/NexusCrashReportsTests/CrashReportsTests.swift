import Foundation
import Sentry
import Testing
@testable import NexusCrashReports

struct CrashReportsTests {
    @Test func aTextLosesTheHomeFolderAndKeepsABundleID() {
        #expect(CrashReports.anonymized("Crash in /Users/jdoe/Development/shop", home: "/Users/jdoe") == "Crash in ~/Development/shop")
        #expect(CrashReports.anonymized("nl.jdoe.nexus", home: "/Users/jdoe") == "nl.jdoe.nexus")
    }

    @Test func aReportHoldsNoNamesOfTheUserOrTheMac() {
        let event = Event(level: .fatal)
        let exception = Exception(value: "Fatal error at \(NSHomeDirectory())/Sites/shop", type: "EXC_BREAKPOINT")
        let frame = Frame()
        frame.package = "\(NSHomeDirectory())/Applications/Nexus.app/Contents/MacOS/Nexus"
        let stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        exception.stacktrace = stacktrace
        let image = DebugMeta()
        image.codeFile = "\(NSHomeDirectory())/Applications/Nexus.app/Contents/MacOS/Nexus"
        event.exceptions = [exception]
        event.debugMeta = [image]
        event.serverName = "My Mac"
        event.user = User(userId: "installation")
        event.context = ["device": ["name": "My MacBook", "model": "Mac16,1", "locale": "nl_NL"], "app": ["app_name": "Nexus", "device_app_hash": "b0af", "path": "\(NSHomeDirectory())/Applications"]]

        let anonymous = CrashReports.anonymized(event)

        #expect(anonymous.serverName == nil)
        #expect(anonymous.user == nil)
        #expect(anonymous.exceptions?.first?.value == "Fatal error at ~/Sites/shop")
        #expect(anonymous.exceptions?.first?.stacktrace?.frames.first?.package == "~/Applications/Nexus.app/Contents/MacOS/Nexus")
        #expect(anonymous.debugMeta?.first?.codeFile == "~/Applications/Nexus.app/Contents/MacOS/Nexus")
        #expect(anonymous.context?["device"]?["name"] == nil)
        #expect(anonymous.context?["device"]?["locale"] == nil)
        #expect(anonymous.context?["app"]?["device_app_hash"] == nil)
        #expect(anonymous.context?["device"]?["model"] as? String == "Mac16,1")
        #expect(anonymous.context?["app"]?["path"] as? String == "~/Applications")
    }
}
