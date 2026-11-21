import Testing
@testable import NexusSupervisor

struct SystemPowerWatchTests {
    @Test func theMessagesOfIOKitGiveTheSleepAndTheWake() {
        #expect(SystemPowerWatch.event(for: 0xE000_0280) == .willSleep)
        #expect(SystemPowerWatch.event(for: 0xE000_0300) == .didWake)
        #expect(SystemPowerWatch.event(for: 0xE000_0270) == nil)
    }

    @Test func aWatchStartsAndStopsWithoutAnEvent() {
        let watch = SystemPowerWatch { _ in }

        let started = watch.start()
        watch.stop()

        #expect(started)
    }
}
