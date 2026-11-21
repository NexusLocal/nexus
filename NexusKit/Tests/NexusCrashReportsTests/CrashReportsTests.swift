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

@Suite(.serialized)
struct ExceptionPortsTests {
    @Test func eachKindOfExceptionGetsBackItsPortFromBeforeAnotherHandler() throws {
        let before = ExceptionPorts.current()
        let kindsBefore = behaviorOfEachKindWithAPort(before.handlers)
        var handler = mach_port_t(MACH_PORT_NULL)
        try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &handler) == KERN_SUCCESS)
        try #require(mach_port_insert_right(mach_task_self_, handler, handler, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)

        defer {
            mach_port_deallocate(mach_task_self_, handler)
            mach_port_mod_refs(mach_task_self_, handler, MACH_PORT_RIGHT_RECEIVE, -1)
        }

        task_set_exception_ports(mach_task_self_, ExceptionPorts.allKinds, handler, EXCEPTION_DEFAULT, THREAD_STATE_NONE)
        let installed = readAndRelease()
        let restored = before.restore()
        let after = readAndRelease()

        #expect(installed.allSatisfy { $0.port == handler })
        #expect(restored)
        #expect(!after.contains { $0.port == handler })
        #expect(behaviorOfEachKindWithAPort(after) == kindsBefore)
    }

    private func readAndRelease() -> [ExceptionPorts.Handler] {
        let handlers = ExceptionPorts.current().handlers

        for handler in handlers where handler.port != mach_port_t(MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self_, handler.port)
        }

        return handlers
    }

    private func behaviorOfEachKindWithAPort(_ handlers: [ExceptionPorts.Handler]) -> [Int: exception_behavior_t] {
        var kinds: [Int: exception_behavior_t] = [:]

        for handler in handlers where handler.port != mach_port_t(MACH_PORT_NULL) {
            for kind in 0..<32 where handler.mask & (1 << kind) != 0 {
                kinds[kind] = handler.behavior
            }
        }

        return kinds
    }
}
