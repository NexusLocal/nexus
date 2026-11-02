import Darwin
import Foundation
import Testing
@testable import NexusSupervisor

struct PortInspectorTests {
    @Test func theMainProcessOfAServerIsItsHighestParentOfTheSameProgram() {
        let table: [Int32: ProcessEntry] = [
            30: ProcessEntry(parent: 20, user: 501, command: "nginx"),
            20: ProcessEntry(parent: 1, user: 0, command: "nginx"),
        ]

        let main = ProcessTable.mainProcess(of: 30) { table[$0] }

        #expect(main?.pid == 20)
        #expect(main?.user == 0)
    }

    @Test func aParentOfAnotherProgramIsNotTheMainProcess() {
        let table: [Int32: ProcessEntry] = [
            30: ProcessEntry(parent: 20, user: 501, command: "mysqld"),
            20: ProcessEntry(parent: 1, user: 501, command: "sh"),
        ]

        #expect(ProcessTable.mainProcess(of: 30) { table[$0] }?.pid == 30)
    }

    @Test(arguments: ["node", "php", "python3.13", "Python"])
    func anInterpreterIsItsOwnMainProcess(_ command: String) {
        let table: [Int32: ProcessEntry] = [
            30: ProcessEntry(parent: 20, user: 501, command: command),
            20: ProcessEntry(parent: 1, user: 501, command: command),
        ]

        #expect(ProcessTable.mainProcess(of: 30) { table[$0] }?.pid == 30)
    }

    @Test func phpFpmIsNoInterpreter() {
        let table: [Int32: ProcessEntry] = [
            30: ProcessEntry(parent: 20, user: 501, command: "php-fpm"),
            20: ProcessEntry(parent: 1, user: 501, command: "php-fpm"),
        ]

        #expect(ProcessTable.mainProcess(of: 30) { table[$0] }?.pid == 20)
    }

    @Test func aProgramOfThisUserCanStop() {
        let owner = PortOwner(pid: 30, command: "nginx", executable: "/opt/homebrew/bin/nginx", mainPID: 20, mainProcessIsOwn: true)

        #expect(owner.canStop)
        #expect(owner.description == "Homebrew (nginx, process 20)")
    }

    @Test func aMainProcessOfRootCannotStop() {
        let owner = PortOwner(pid: 30, command: "nginx", executable: "/opt/homebrew/bin/nginx", mainPID: 20, mainProcessIsOwn: false)

        #expect(!owner.canStop)
    }

    @Test func aServerOfMampProOrHerdCannotStopAlsoWhenItBelongsToThisUser() {
        let mamp = PortOwner(pid: 30, command: "mysqld", executable: "/Applications/MAMP/Library/bin/mysql80/bin/mysqld", mainPID: 30, mainProcessIsOwn: true)
        let herd = PortOwner(pid: 31, command: "nginx", executable: "/Users/me/Library/Application Support/Herd/bin/nginx", mainPID: 31, mainProcessIsOwn: true)

        #expect(!mamp.canStop)
        #expect(mamp.managerBundleIdentifier == "de.appsolute.mamppro")
        #expect(!herd.canStop)
        #expect(herd.managerBundleIdentifier == "de.beyondco.herd")
    }

    @Test func theOwnerOfAnOlderNexusdCannotStop() throws {
        let data = Data(#"{"pid":30,"command":"nginx","executable":null}"#.utf8)

        let owner = try JSONDecoder().decode(PortOwner.self, from: data)

        #expect(owner.mainPID == nil)
        #expect(!owner.canStop)
    }

    @Test func theRealProcessTableKnowsThisProcess() {
        let entry = ProcessTable.entry(of: getpid())

        #expect(entry?.user == getuid())
        #expect(entry?.parent == getppid())
    }

    private func listen(on address: String) throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr = in_addr(s_addr: inet_addr(address))
        _ = withUnsafePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(Darwin.listen(descriptor, 5) == 0)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return (descriptor, Int(UInt16(bigEndian: bound.sin_port)))
    }

    @Test func aListenerOnLoopbackOrOnAllAddressesHoldsThePort() async throws {
        for address in ["127.0.0.1", "0.0.0.0"] {
            let listener = try listen(on: address)

            #expect(!PortInspector.isFree(listener.port))
            #expect(PortInspector.acceptsConnections(listener.port))

            close(listener.descriptor)
            #expect(await PortInspector.becomesFree(listener.port))
        }
    }

    @Test func aClosedConnectionDoesNotHoldThePort() async throws {
        let listener = try listen(on: "127.0.0.1")
        #expect(PortInspector.acceptsConnections(listener.port))
        close(listener.descriptor)

        #expect(await PortInspector.becomesFree(listener.port))
    }

    @Test func aLowPortWithoutAListenerIsFree() {
        #expect(PortInspector.isFree(81))
    }
}
