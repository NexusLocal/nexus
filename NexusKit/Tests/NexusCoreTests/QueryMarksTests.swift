import Foundation
import NexusCore
import Testing

struct QueryMarksTests {
    private static let controller = "/Users/tim/Sites/shop/app/Http/Controllers/OrderController.php"

    private func query(_ seq: Int, _ text: String, pattern: String? = nil, milliseconds: Double? = 1, file: String? = controller, line: Int? = 42) -> CaughtDump {
        CaughtDump(requestID: "a1", seq: seq, time: Date(timeIntervalSince1970: 0), kind: .query, file: file, line: line, label: "mysql", text: text, milliseconds: milliseconds, pattern: pattern)
    }

    @Test func aQueryOf100MillisecondsOrMoreIsSlow() {
        let fast = query(1, "select 1", milliseconds: 99.9)
        let slow = query(2, "select 2", milliseconds: 100)
        let unknown = query(3, "select 3", milliseconds: nil)

        let marks = QueryMarks([fast, slow, unknown])

        #expect(marks.marks(of: fast).isEmpty)
        #expect(marks.marks(of: slow) == [.slow])
        #expect(marks.marks(of: unknown).isEmpty)
        #expect(marks.request == [.slow])
    }

    @Test func theSameTextTwoTimesIsADuplicate() {
        let first = query(1, "select * from `carts` where `user_id` = 7 limit 1")
        let again = query(2, "select * from `carts` where `user_id` = 7 limit 1", line: 90)
        let other = query(3, "select * from `carts` where `user_id` = 8 limit 1")

        let marks = QueryMarks([first, again, other])

        #expect(marks.marks(of: first) == [.duplicate])
        #expect(marks.marks(of: again) == [.duplicate])
        #expect(marks.marks(of: other).isEmpty)
        #expect(marks.request == [.duplicate])
    }

    @Test func onlyASelectCanBeNPlusOne() {
        let inserts = (1...5).map { number in query(number, "insert into `options` (`name`) values ('widget_\(number)')") }
        let selects = (6...10).map { number in query(number, " (SELECT * FROM wp_options WHERE option_name = 'widget_\(number)')") }

        let marks = QueryMarks(inserts + selects)

        #expect(inserts.allSatisfy { insert in marks.marks(of: insert).isEmpty })
        #expect(selects.allSatisfy { select in marks.marks(of: select) == [.nPlusOne] })
        #expect(QueryMarks.reads("SELECT 1"))
        #expect(!QueryMarks.reads("update `jobs` set `attempts` = 1"))
    }

    @Test func fiveQueriesOfOnePatternFromOneLineWithOtherTextsAreNPlusOne() {
        let queries = (1...5).map { number in query(number, "select * from `users` where `id` = \(number)", pattern: "select * from `users` where `id` = ?") }

        let marks = QueryMarks(queries)

        #expect(queries.allSatisfy { query in marks.marks(of: query) == [.nPlusOne] })
        #expect(marks.request == [.nPlusOne])
    }

    @Test func fourQueriesOfOnePatternAreNoNPlusOne() {
        let queries = (1...4).map { number in query(number, "select * from `users` where `id` = \(number)", pattern: "select * from `users` where `id` = ?") }

        #expect(QueryMarks(queries).request.isEmpty)
    }

    @Test func fiveQueriesOfOnePatternFromOtherLinesAreNoNPlusOne() {
        let queries = (1...5).map { number in query(number, "select * from `users` where `id` = \(number)", pattern: "select * from `users` where `id` = ?", line: number) }

        #expect(QueryMarks(queries).request.isEmpty)
    }

    @Test func fiveTimesTheSameTextIsADuplicateAndNoNPlusOne() {
        let queries = (1...5).map { number in query(number, "select * from `settings`", pattern: "select * from `settings`") }

        #expect(QueryMarks(queries).request == [.duplicate])
    }

    @Test func aRepeatedValueInAnNPlusOneGetsBothMarks() {
        let texts = ["= 1", "= 2", "= 1", "= 3", "= 4"].map { "select * from `users` where `id` \($0)" }
        let queries = texts.enumerated().map { index, text in query(index + 1, text, pattern: "select * from `users` where `id` = ?") }

        let marks = QueryMarks(queries)

        #expect(marks.marks(of: queries[0]) == [.nPlusOne, .duplicate])
        #expect(marks.marks(of: queries[1]) == [.nPlusOne])
    }

    @Test func aQueryOfWordPressGetsItsPatternFromItsText() {
        let queries = (1...5).map { number in query(number, "SELECT * FROM wp_postmeta WHERE post_id = \(number) AND meta_key = 'color_\(number)'", pattern: nil) }

        #expect(QueryMarks(queries).request == [.nPlusOne])
    }

    @Test func entriesOfOtherKindsHaveNoMarks() {
        let log = CaughtDump(requestID: "a1", seq: 1, time: Date(timeIntervalSince1970: 0), kind: .log, label: "error", text: "select 1", milliseconds: 500)
        let dump = CaughtDump(requestID: "a1", seq: 2, time: Date(timeIntervalSince1970: 0), text: "select 1")

        let marks = QueryMarks([log, dump, query(3, "select 1")])

        #expect(marks.marks(of: log).isEmpty)
        #expect(marks.request.isEmpty)
    }

    @Test(arguments: [
        ("SELECT * FROM wp_posts WHERE ID = 42", "SELECT * FROM wp_posts WHERE ID = ?"),
        ("SELECT * FROM wp_2_posts WHERE post_status = 'publish' LIMIT 10", "SELECT * FROM wp_2_posts WHERE post_status = ? LIMIT ?"),
        (#"SELECT * FROM wp_options WHERE option_name = 'it\'s' AND autoload = 'yes'"#, "SELECT * FROM wp_options WHERE option_name = ? AND autoload = ?"),
        ("SELECT 'it''s', 'x' FROM t", "SELECT ?, ? FROM t"),
        (#"SELECT * FROM t WHERE a = "b" AND c = 1.5"#, "SELECT * FROM t WHERE a = ? AND c = ?"),
        ("SELECT * FROM `table1` WHERE `2fa` = 0", "SELECT * FROM `table1` WHERE `2fa` = ?"),
        ("SELECT * FROM t WHERE id IN (1, 2, 3)", "SELECT * FROM t WHERE id IN (?, ?, ?)"),
        ("SELECT * FROM t WHERE x=5", "SELECT * FROM t WHERE x=?"),
        ("SELECT * FROM t WHERE name = 'Zoë 7'", "SELECT * FROM t WHERE name = ?"),
        ("SELECT * FROM t WHERE a = 'no end", "SELECT * FROM t WHERE a = ?"),
        ("SELECT 2fa_code FROM t", "SELECT 2fa_code FROM t"),
    ])
    func aPatternReplacesTheStringsAndTheNumbers(sql: String, pattern: String) {
        #expect(QueryMarks.pattern(of: sql) == pattern)
    }

    @Test func thePatternOfLaravelWins() {
        let laravel = query(1, "select * from `users` where `id` = 7", pattern: "select * from `users` where `id` = ?")
        let other = query(2, "select * from users where id = 7", pattern: nil)

        #expect(QueryMarks.pattern(of: laravel) == "select * from `users` where `id` = ?")
        #expect(QueryMarks.pattern(of: other) == "select * from users where id = ?")
    }

    @Test func theTallyGivesTheMarksAndTheTimeOfQueryMarksAfterEachAddAndRemove() {
        let texts = [
            "select * from `users` where `id` = 1",
            "select * from `users` where `id` = 2",
            "select * from `users` where `id` = 1",
            "select * from `users` where `id` = 3",
            "select * from `users` where `id` = 4",
            "update `users` set `seen` = 1 where `id` = 5",
            "select * from `carts` limit 1",
        ]
        var queries: [CaughtDump] = []

        for index in 0..<40 {
            let text = texts[(index * 5 + index / 7) % texts.count]
            let line = index.isMultiple(of: 9) ? 50 : 42
            queries.append(query(index + 1, text, pattern: index.isMultiple(of: 4) ? nil : QueryMarks.pattern(of: text), milliseconds: Double(index % 11) * 12.25, line: line))
        }

        var tally = QueryTally()
        var kept: [CaughtDump] = []
        var mismatches: [Int] = []

        for (step, added) in queries.enumerated() {
            tally.add(added, pattern: QueryMarks.pattern(of: added))
            kept.append(added)

            if step.isMultiple(of: 3) {
                let removed = kept.remove(at: (step * 7) % kept.count)
                tally.remove(removed, pattern: QueryMarks.pattern(of: removed))
            }

            let expected = kept.reduce(0) { total, query in total + (query.milliseconds ?? 0) }

            if tally.marks != QueryMarks(kept).request || abs(tally.milliseconds - expected) > 0.000_001 {
                mismatches.append(step)
            }
        }

        #expect(mismatches.isEmpty)
        #expect(!tally.marks.isEmpty)
    }

    @Test func theTallyOfNoQueriesHasNoMarksAndNoTime() {
        var tally = QueryTally()
        let slow = query(1, "select 1", milliseconds: 250.5)

        tally.add(slow, pattern: QueryMarks.pattern(of: slow))
        let withTheQuery = tally.marks
        tally.remove(slow, pattern: QueryMarks.pattern(of: slow))

        #expect(withTheQuery == [.slow])
        #expect(tally.marks.isEmpty)
        #expect(tally.milliseconds == 0)
        #expect(tally == QueryTally())
    }

    @Test func theMarksSortInTheirFixedOrder() {
        #expect(Set<QueryMark>([.slow, .duplicate, .nPlusOne]).sorted() == [.nPlusOne, .duplicate, .slow])
    }
}
