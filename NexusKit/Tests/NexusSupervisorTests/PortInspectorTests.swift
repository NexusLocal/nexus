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

    private func listen(onSocket path: String) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(Darwin.listen(descriptor, 5) == 0)
        return descriptor
    }

    // A listener that just closed can take connections for some milliseconds while other tests run.
    private func stopsAccepting(_ accepts: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)

        while accepts() {
            guard ContinuousClock.now < deadline else {
                return false
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return true
    }

    @Test func aListeningUnixSocketAcceptsConnections() async {
        let path = "/tmp/nx-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let descriptor = listen(onSocket: path)

        let accepts = PortInspector.acceptsConnections(socket: path)
        close(descriptor)

        #expect(accepts)
        #expect(await stopsAccepting { PortInspector.acceptsConnections(socket: path) })
    }

    @Test func theLinesOfLsofGiveThePortsOnBothSidesOfAConnection() {
        let output = "p123\nf10\nn[::1]:20005->[::1]:51234\np456\nf11\nn127.0.0.1:51300->127.0.0.1:20007\nn127.0.0.1:3306->127.0.0.1:51400\n"

        #expect(PortInspector.connectedPorts(inLsofOutput: output, among: [20005, 20007, 20009]) == [20005, 20007])
        #expect(PortInspector.connectedPorts(inLsofOutput: output, among: [20009]).isEmpty)
    }

    private func listenOnIPv6Loopback() -> (descriptor: Int32, port: Int)? {
        for _ in 0..<50 {
            let port = Int.random(in: 50_001...60_000)
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }

            if bound == 0, Darwin.listen(descriptor, 5) == 0 {
                return (descriptor, port)
            }

            close(descriptor)
        }

        return nil
    }

    @Test func aListenerOnlyOnTheLoopbackOfIPv6AcceptsLoopbackConnections() async throws {
        let listener = try #require(listenOnIPv6Loopback())
        let accepts = PortInspector.acceptsLoopbackConnections(listener.port)
        let acceptsOnIPv4 = PortInspector.acceptsConnections(listener.port)
        close(listener.descriptor)

        #expect(accepts)
        #expect(!acceptsOnIPv4)
        #expect(await stopsAccepting { PortInspector.acceptsLoopbackConnections(listener.port) })
    }

    @Test func aMissingSocketAcceptsNoConnection() {
        #expect(!PortInspector.acceptsConnections(socket: "/tmp/nx-\(UUID().uuidString.prefix(8)).sock"))
        #expect(!PortInspector.acceptsConnections(socket: "/tmp/" + String(repeating: "x", count: 120)))
    }
}
