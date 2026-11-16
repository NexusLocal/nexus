import NexusCore
import Testing

struct FirstNonNilTests {
    @Test func theTransformRunsOneTimeForEachElementUpToTheFirstValue() {
        var calls: [Int] = []

        let found = [1, 2, 3, 4].firstNonNil { number -> String? in
            calls.append(number)
            return number == 3 ? "three" : nil
        }

        #expect(found == "three")
        #expect(calls == [1, 2, 3])
    }

    @Test func noValueGivesNil() {
        let found = [1, 2].firstNonNil { _ -> String? in nil }

        #expect(found == nil)
    }
}
