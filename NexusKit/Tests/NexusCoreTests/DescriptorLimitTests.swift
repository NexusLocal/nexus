import Darwin
import Testing
@testable import NexusCore

struct DescriptorLimitTests {
    private let unlimited = rlim_t(Int64.max)

    @Test func theSoftLimitRisesToTheWantedLimitOrToTheHardLimit() {
        #expect(DescriptorLimit.raised(rlimit(rlim_cur: 256, rlim_max: unlimited)) == 10240)
        #expect(DescriptorLimit.raised(rlimit(rlim_cur: 256, rlim_max: 1000)) == 1000)
    }

    @Test func aHigherSoftLimitStays() {
        #expect(DescriptorLimit.raised(rlimit(rlim_cur: 20000, rlim_max: unlimited)) == nil)
        #expect(DescriptorLimit.raised(rlimit(rlim_cur: 1000, rlim_max: 1000)) == nil)
    }
}
