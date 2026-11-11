import Foundation
import NexusMail
import Testing
@testable import NexusMCP

struct MailContentTests {
    private static let laravelHTML = """
    <html><head><style>a { color: red; }</style></head><body>
    <p>Please click the button below to verify your email address.</p>
    <a href="https://shop.test/verify/1/abc?expires=123&amp;signature=xyz" class="button">Verify Email Address</a>
    <p>If you're having trouble clicking the "Verify Email Address" button, copy and paste the URL below:
    <a href="https://shop.test/verify/1/abc?expires=123&amp;signature=xyz">https://shop.test/verify/1/abc?expires=123&amp;signature=xyz</a></p>
    <a href="mailto:help@shop.test">Help</a>
    </body></html>
    """

    @Test func aLinkComesOnceWithItsText() {
        let links = MailContent.links(html: Self.laravelHTML, text: "")

        #expect(links == [MailLink(url: "https://shop.test/verify/1/abc?expires=123&signature=xyz", text: "Verify Email Address")])
    }

    @Test func theTextPartAddsItsOtherLinks() {
        let links = MailContent.links(html: "<a href='https://a.test/x'>A</a>", text: "Open https://a.test/x or https://b.test/reset?token=1.")

        #expect(links == [MailLink(url: "https://a.test/x", text: "A"), MailLink(url: "https://b.test/reset?token=1", text: nil)])
    }

    @Test(arguments: [
        ("Your verification code is 482913.", ["482913"]),
        ("Use code 123 456 to sign in", ["123456"]),
        ("Your login code: 123-456", ["123456"]),
        ("PIN: 0042", ["0042"]),
        ("Your order 2026-11-10 at 12:30 costs 1500 euro.", []),
        ("Call 06-12345678 for help with your code.", []),
        ("Version 8.4.13 needs a new code.", []),
    ])
    func aCodeIsANumberNearAWord(text: String, codes: [String]) {
        #expect(MailContent.codes(in: text) == codes)
    }

    @Test func plainTextDropsTheStyleAndTheTags() {
        let text = MailContent.plainText(html: Self.laravelHTML)

        #expect(!text.contains("color"))
        #expect(text.hasPrefix("Please click the button below to verify your email address."))
        #expect(text.contains("expires=123&signature=xyz"))
    }

    @Test func anAgentMailStopsALongText() {
        let message = MailpitAPI.Message(id: "a", from: "x", to: ["y"], cc: [], subject: "s", date: "d", tags: ["shop.test"], text: String(repeating: "a", count: AgentMail.textLimit + 5) + " code 123456", html: "", attachments: [], headers: [:])
        let mail = AgentMail(message)

        #expect(mail.text.count == AgentMail.textLimit)
        #expect(mail.note != nil)
        #expect(mail.codes == ["123456"])
        #expect(mail.site == "shop.test")
    }
}

private actor FakeInbox: MailInbox {
    var summaries: [MailpitAPI.Summary]
    var queries: [String] = []
    var removed: [String] = []
    var mostSearchesAtOnce = 0
    private var searchesNow = 0
    private let searchTime: Duration

    init(_ summaries: [MailpitAPI.Summary], searchTime: Duration = .zero) {
        self.summaries = summaries
        self.searchTime = searchTime
    }

    func add(_ summary: MailpitAPI.Summary) {
        summaries.insert(summary, at: 0)
    }

    func search(_ query: String, limit: Int) async throws -> [MailpitAPI.Summary] {
        queries.append(query)
        searchesNow += 1
        mostSearchesAtOnce = max(mostSearchesAtOnce, searchesNow)
        try await Task.sleep(for: searchTime)
        searchesNow -= 1

        return summaries.filter { summary in
            query.split(separator: " ").allSatisfy { term in
                let value = term.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? ""

                if term.hasPrefix("tag:") {
                    return summary.tags.contains(value)
                }

                if term.hasPrefix("to:") {
                    return summary.to.contains(value)
                }

                return true
            }
        }
    }

    func newest(limit: Int) async throws -> [MailpitAPI.Summary] {
        summaries
    }

    func message(id: String) async throws -> MailpitAPI.Message {
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw MailpitAPIError.noMail(id)
        }

        return MailpitAPI.Message(id: id, from: summary.from, to: summary.to, cc: [], subject: summary.subject, date: summary.created, tags: summary.tags, text: "Code 654321", html: "", attachments: [], headers: [:])
    }

    func remove(ids: [String]) async throws {
        removed += ids
    }

    func removeAll() async throws {
        removed = summaries.map(\.id)
    }
}

struct MailReaderTests {
    private static func mail(_ id: String, to: String, tag: String?, at date: Date) -> MailpitAPI.Summary {
        MailpitAPI.Summary(id: id, from: "shop@shop.test", to: [to], subject: "Welcome", tags: tag.map { [$0] } ?? [], created: date.formatted(.iso8601), snippet: "")
    }

    @Test func aMailOfTheMinuteBeforeTheCallCounts() async throws {
        let now = Date.now
        let inbox = FakeInbox([Self.mail("new", to: "ann@example.com", tag: nil, at: now.addingTimeInterval(-20)), Self.mail("old", to: "ann@example.com", tag: nil, at: now.addingTimeInterval(-600))])
        let found = try await MailReader(inbox: inbox).wait(to: "ann@example.com", subject: nil, tags: ["shop.test"], since: now.addingTimeInterval(-60), seconds: 1)

        #expect(found?.id == "new")
        #expect(found?.codes == ["654321"])
    }

    @Test func theNewestMailOfTheMinuteWins() async throws {
        let now = Date.now
        let inbox = FakeInbox([Self.mail("second", to: "ann@example.com", tag: nil, at: now.addingTimeInterval(-5)), Self.mail("first", to: "ann@example.com", tag: nil, at: now.addingTimeInterval(-40))])
        let found = try await MailReader(inbox: inbox).wait(to: "ann@example.com", subject: nil, tags: nil, since: now.addingTimeInterval(-60), seconds: 1)

        #expect(found?.id == "second")
    }

    @Test func aMailThatComesLaterEndsTheWait() async throws {
        let now = Date.now
        let inbox = FakeInbox([])

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await inbox.add(Self.mail("late", to: "bob@example.com", tag: "shop.test", at: .now))
        }

        let found = try await MailReader(inbox: inbox).wait(to: nil, subject: nil, tags: ["shop.test"], since: now.addingTimeInterval(-1), seconds: 2, poll: .milliseconds(20))

        #expect(found?.id == "late")
    }

    @Test func noMailGivesNilAfterTheWait() async throws {
        let found = try await MailReader(inbox: FakeInbox([])).wait(to: "x@example.com", subject: nil, tags: nil, since: .now, seconds: 1, poll: .milliseconds(50))

        #expect(found == nil)
    }

    @Test func aSiteSeesOnlyTheMailOfItsTags() async throws {
        let now = Date.now
        let inbox = FakeInbox([Self.mail("a", to: "x", tag: "shop.test", at: now), Self.mail("b", to: "x", tag: "blog.test", at: now), Self.mail("c", to: "x", tag: "fix.shop.test", at: now.addingTimeInterval(-5))])
        let mails = try await MailReader(inbox: inbox).list(tags: ["shop.test", "fix.shop.test"], limit: 10)

        #expect(mails.map(\.id) == ["a", "c"])
    }

    @Test func aSiteWithManyWorkspacesSendsALimitedNumberOfSearchesAtOnce() async throws {
        let now = Date.now
        let tags = (0..<10).map { "fix\($0).shop.test" }
        let inbox = FakeInbox(tags.enumerated().map { index, tag in Self.mail("\(index)", to: "x", tag: tag, at: now.addingTimeInterval(-Double(index))) }, searchTime: .milliseconds(20))
        let mails = try await MailReader(inbox: inbox).list(tags: tags, limit: 20)

        #expect(mails.map(\.id) == (0..<10).map(String.init))
        #expect(await inbox.queries.count == 10)
        #expect(await inbox.mostSearchesAtOnce <= MailReader.searchesAtOnce)
        #expect(await inbox.mostSearchesAtOnce > 1)
    }

    @Test func clearRemovesOnlyTheMailOfTheSite() async throws {
        let inbox = FakeInbox([Self.mail("a", to: "x", tag: "shop.test", at: .now), Self.mail("b", to: "x", tag: "blog.test", at: .now)])
        let count = try await MailReader(inbox: inbox).clear(id: nil, tags: ["shop.test"])

        #expect(count == 1)
        #expect(await inbox.removed == ["a"])
    }
}
