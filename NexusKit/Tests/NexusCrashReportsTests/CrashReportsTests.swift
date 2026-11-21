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

    @Test func theExceptionPortsGoBackToThePortsFromBeforeAnotherHandler() throws {
        let before = ExceptionPorts.current()
        var handler = mach_port_t(MACH_PORT_NULL)
        try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &handler) == KERN_SUCCESS)
        defer { mach_port_mod_refs(mach_task_self_, handler, MACH_PORT_RIGHT_RECEIVE, -1) }
        try #require(mach_port_insert_right(mach_task_self_, handler, handler, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)

        task_set_exception_ports(mach_task_self_, ExceptionPorts.crashMask, handler, EXCEPTION_DEFAULT, THREAD_STATE_NONE)
        let installed = ExceptionPorts.current()
        before.restore()

        #expect(installed.handlers.contains { $0.port == handler })
        #expect(portsByMask(ExceptionPorts.current()) == portsByMask(before))
    }

    // A kind of crash without a port can come back with another behavior. Only the port counts.
    private func portsByMask(_ ports: ExceptionPorts) -> [[UInt32]] {
        ports.handlers.map { [$0.mask, $0.port] }
    }
}
