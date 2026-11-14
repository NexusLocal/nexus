import Testing
@testable import NexusCore

struct CountTests {
    @Test(arguments: [(0, "0 dumps"), (1, "1 dump"), (2, "2 dumps"), (1248, "1248 dumps")])
    func aCountHasPlainDigitsAndAnSForMoreThanOne(number: Int, text: String) {
        #expect(Count.text(number, "dump") == text)
    }

    @Test(arguments: [(0, "0 queries"), (1, "1 query"), (24, "24 queries")])
    func aNounCanGiveItsOwnPlural(number: Int, text: String) {
        #expect(Count.text(number, "query", plural: "queries") == text)
    }
}
