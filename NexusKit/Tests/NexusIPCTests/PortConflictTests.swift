import Testing
@testable import NexusIPC

struct PortConflictTests {
    @Test func anotherProgramOnThePortStopsNothing() {
        #expect(PortConflict.otherProgramText(port: 3306, service: "MySQL 8.4") == "Another program uses port 3306 now. Nexus stopped nothing. Start MySQL 8.4 again. Nexus then shows the program that uses the port.")
    }
}
