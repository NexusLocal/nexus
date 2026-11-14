import Foundation
import NexusCore
import Testing

struct CaughtDumpsTests {
    private static let cartTree = #"""
    {"kind":"object","class":"App\\Models\\Cart","ref":1287,"count":3,"children":[
      {"key":"id","access":"public","kind":"int","value":"42"},
      {"key":"total","access":"public","kind":"string","value":"129.95"},
      {"key":"items","access":"public","kind":"object","class":"Illuminate\\Support\\Collection","ref":1290,"count":3,"children":[]}
    ]}
    """#

    private static let started = Date(timeIntervalSince1970: 1_762_850_000.123)

    private static let accessKeys: [(access: DumpNode.Access, key: String)] = [
        (.public, "+total"),
        (.protected, "#total"),
        (.private, "-total"),
        (.virtual, "total"),
        (.dynamic, "+\"total\""),
    ]

    private func node(_ json: String) throws -> DumpNode {
        try JSONDecoder().decode(DumpNode.self, from: Data(json.utf8))
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func dump(seq: Int, kind: CaughtDump.Kind = .dump, treeJSON: String? = nil) -> CaughtDump {
        CaughtDump(requestID: "65f1c2a9e3b1", seq: seq, time: Self.started.addingTimeInterval(0.078), kind: kind, file: "/Users/x/Sites/shop/app/Http/Controllers/CheckoutController.php", line: 42, text: "array:2 [\n  \"id\" => 7\n]", treeJSON: treeJSON)
    }

    @Test func theTreeOfThePlanDecodes() throws {
        let expected = DumpNode(kind: .object, className: "App\\Models\\Cart", ref: 1287, count: 3, children: [
            DumpNode(kind: .int, key: "id", access: .public, value: "42"),
            DumpNode(kind: .string, key: "total", access: .public, value: "129.95"),
            DumpNode(kind: .object, key: "items", access: .public, className: "Illuminate\\Support\\Collection", ref: 1290, count: 3, children: []),
        ])

        let tree = try node(Self.cartTree)

        #expect(tree == expected)
        #expect(tree.displayKey == nil)
        #expect(tree.children?.map(\.displayKey) == ["+id", "+total", "+items"])
    }

    @Test func theTreeOfThePlanEncodesWithTheSameKeysAndNoOthers() throws {
        let tree = try node(Self.cartTree)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(Self.cartTree.utf8)) as? NSDictionary

        #expect(encoded != nil)
        #expect(encoded == original)
    }

    @Test func aNodeThatRefersToAnObjectOfTheTreeHasNoChildren() throws {
        let tree = try node(#"{"key":"cart","access":"protected","kind":"object","class":"App\\Models\\Cart","refersTo":1287}"#)

        #expect(tree.refersTo == 1287)
        #expect(tree.ref == nil)
        #expect(tree.children == nil)
        #expect(tree.className == "App\\Models\\Cart")
        #expect(tree.displayKey == "#cart")
        #expect(try roundTrip(tree) == tree)
    }

    @Test func aCutStringKeepsItsFullLength() throws {
        let value = String(repeating: "a", count: 10_000)

        let tree = try node(#"{"key":"body","access":"private","kind":"string","value":"\#(value)","cut":2000,"length":12000}"#)

        #expect(tree.value?.count == 10_000)
        #expect(tree.cut == 2000)
        #expect(tree.length == 12_000)
        #expect(tree.displayKey == "-body")
    }

    @Test func anIntegerKeyHasNoQuotesAndAStringKeyHas() throws {
        let tree = try node(#"{"kind":"array","count":3,"cut":1,"children":[{"key":"0","index":true,"kind":"string","value":"pickup"},{"key":"coupon","kind":"null"}]}"#)

        let children = try #require(tree.children)

        #expect(tree.cut == 1)
        #expect(children[0].index == true)
        #expect(children[0].displayKey == "0")
        #expect(children[1].index == nil)
        #expect(children[1].kind == .null)
        #expect(children[1].displayKey == "\"coupon\"")
    }

    @Test(arguments: accessKeys)
    func aPropertyKeyShowsTheMarkerOfItsAccess(access: DumpNode.Access, key: String) {
        let property = DumpNode(kind: .string, key: "total", access: access, value: "129.95")

        #expect(property.displayKey == key)
    }

    @Test func aDumpDecodesItsTreeOnlyWhenAsked() throws {
        let withTree = dump(seq: 1, treeJSON: Self.cartTree)
        let withoutTree = dump(seq: 2)
        let brokenTree = dump(seq: 3, treeJSON: #"{"kind":"object","children":["#)

        #expect(withTree.decodedTree() == (try node(Self.cartTree)))
        #expect(withoutTree.decodedTree() == nil)
        #expect(brokenTree.decodedTree() == nil)
    }

    @Test func theTreeOfADumpStaysOneStringInTheJSON() throws {
        let caught = dump(seq: 1, treeJSON: Self.cartTree)

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(caught)) as? [String: Any])

        #expect(object["tree"] as? String == Self.cartTree)
        #expect(object["treeJSON"] == nil)
    }

    @Test func aDumpSurvivesARoundTripWithAndWithoutItsTree() throws {
        let withoutTree = dump(seq: 1)
        let withTree = CaughtDump(requestID: "65f1c2a9e3b1", seq: 2, time: Self.started, kind: .dd, label: "cart", text: "App\\Models\\Cart {#1287}", treeJSON: Self.cartTree, truncated: true)

        #expect(try roundTrip(withoutTree) == withoutTree)
        #expect(try roundTrip(withTree) == withTree)
    }

    @Test func aDumpWithNoDefaultValueKeepsEachField() throws {
        let caught = CaughtDump(requestID: "65f1c2a9e3b1", seq: 2, time: Self.started, kind: .dd, file: "/Users/x/Sites/shop/app/Cart.php", line: 12, label: "cart", text: "1", treeJSON: Self.cartTree, truncated: true, number: 41)

        #expect(try roundTrip(caught) == caught)
    }

    @Test func aDumpWithoutANumberHasNoNumberInItsJSONAndDecodesAs0() throws {
        let caught = dump(seq: 1)

        let json = String(decoding: try JSONEncoder().encode(caught), as: UTF8.self)

        #expect(!json.contains("number"))
        #expect(try roundTrip(caught).number == 0)
    }

    @Test func aDumpIsNamedAfterItsRequestAndItsNumber() throws {
        let caught = dump(seq: 3)

        #expect(caught.id == "65f1c2a9e3b1-3")
        #expect(try roundTrip(caught).id == "65f1c2a9e3b1-3")
    }

    @Test func aRequestSurvivesARoundTrip() throws {
        let page = DumpedRequest(id: "65f1c2a9e3b1", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", host: "shop.test", site: "shop.test", started: Self.started, status: 200, duration: 0.184, dumpCount: 2, hasDD: true)
        let command = DumpedRequest(id: "a1b2c3", kind: .command, target: "php artisan import:products", site: "shop.test", workspace: "fix", started: Self.started, exitCode: 0, duration: 3.2, dumpCount: 4)

        #expect(try roundTrip(page) == page)
        #expect(try roundTrip(command) == command)
    }

    @Test func aRequestKeepsItsRoot() throws {
        let page = DumpedRequest(id: "65f1c2a9e3b1", kind: .http, method: "GET", target: "/checkout", host: "shop.test", root: "/Users/x/Sites/shop/public", started: Self.started)

        #expect(try roundTrip(page).root == "/Users/x/Sites/shop/public")
    }

    @Test func aRequestWithoutARootStillDecodes() throws {
        let json = #"{"id":"a1b2c3","kind":"command","target":"php artisan migrate","started":0,"dumpCount":1,"hasDD":false}"#

        let request = try JSONDecoder().decode(DumpedRequest.self, from: Data(json.utf8))

        #expect(request.root == nil)
        #expect(request.target == "php artisan migrate")
        #expect(request.lastSeq == 0)
    }

    @Test func aRequestWithNoDefaultValueKeepsEachField() throws {
        let request = DumpedRequest(
            id: "65f1c2a9e3b1",
            kind: .command,
            method: "GET",
            target: "php artisan migrate",
            url: "https://fix.shop.test/checkout",
            host: "fix.shop.test",
            root: "/Users/x/Sites/shop-fix/public",
            site: "shop.test",
            workspace: "fix",
            started: Self.started,
            status: 500,
            exitCode: 1,
            duration: 2.5,
            dumpCount: 4,
            hasDD: true,
            lastSeq: 7,
            firstSeq: 3,
            placeHost: "fix.shop.test",
            projectFolder: "/Users/x/Sites/shop-fix",
            lastNumber: 12,
            firstNumber: 9
        )

        #expect(try roundTrip(request) == request)
    }

    @Test func aRequestWithoutNumbersHasNoNumberKeysAndDecodesThemAs0() throws {
        let request = DumpedRequest(id: "a1", kind: .http, method: "GET", target: "/", started: Self.started, dumpCount: 1, lastSeq: 1)

        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let decoded = try roundTrip(request)

        #expect(!json.contains("Number"))
        #expect(decoded.lastNumber == 0)
        #expect(decoded.firstNumber == 0)
    }

    @Test func aRequestOfAnOlderNexusdHasNoFirstSeqAndNoLocation() throws {
        let json = #"{"id":"a1b2c3","kind":"command","target":"php artisan migrate","site":"shop.test","started":0,"dumpCount":1,"hasDD":false,"lastSeq":4}"#

        let request = try JSONDecoder().decode(DumpedRequest.self, from: Data(json.utf8))

        #expect(request.firstSeq == 0)
        #expect(request.location == DumpLocation(place: DumpPlace(site: "shop.test")))
    }

    @Test func aRequestTakesALocation() {
        var request = DumpedRequest(id: "a1", kind: .http, target: "/", site: "blog.test", started: Self.started)
        let location = DumpLocation(place: DumpPlace(site: "shop.test", workspace: "fix"), host: "fix.shop.test", projectFolder: "/Users/x/Sites/shop-fix")

        request.location = location

        #expect(request.place == DumpPlace(site: "shop.test", workspace: "fix"))
        #expect(request.placeHost == "fix.shop.test")
        #expect(request.projectFolder == "/Users/x/Sites/shop-fix")
        #expect(request.location == location)
    }

    @Test func aRequestGivesItsStatusAndItsDurationAsText() {
        let page = DumpedRequest(id: "p1", kind: .http, method: "GET", target: "/", started: Self.started, status: 200, duration: 0.184)
        let command = DumpedRequest(id: "c1", kind: .command, target: "php artisan migrate", started: Self.started, exitCode: 1, duration: 65.2)
        let running = DumpedRequest(id: "r1", kind: .http, method: "GET", target: "/", started: Self.started)

        #expect(page.statusText == "200")
        #expect(page.durationText == "184 ms")
        #expect(command.statusText == "exit 1")
        #expect(command.durationText == "1 min 5 s")
        #expect(running.statusText == nil)
        #expect(running.durationText == nil)
    }

    @Test(arguments: [(0.0004, "0 ms"), (0.5, "500 ms"), (0.9994, "999 ms"), (0.9996, "1.0 s"), (1.3, "1.3 s"), (59.94, "59.9 s"), (59.97, "1 min 0 s"), (75.4, "1 min 15 s"), (3600, "60 min 0 s")])
    func aDurationIsShort(seconds: Double, text: String) {
        #expect(DumpedRequest.durationText(seconds, locale: Locale(identifier: "en_US_POSIX")) == text)
    }

    @Test func aDurationUsesTheDecimalSignOfTheLanguage() {
        #expect(DumpedRequest.durationText(1.3, locale: Locale(identifier: "nl_NL")) == "1,3 s")
    }

    @Test func aCommandShowsCLIAsItsMethod() {
        let page = DumpedRequest(id: "65f1c2a9e3b1", kind: .http, method: "POST", target: "/livewire/update", started: Self.started)
        let command = DumpedRequest(id: "a1b2c3", kind: .command, target: "php artisan import:products", started: Self.started)

        #expect(page.displayMethod == "POST")
        #expect(command.method == nil)
        #expect(command.displayMethod == "CLI")
    }

    @Test func aBlockReadsItsReason() throws {
        let block = try JSONDecoder().decode(DumpBlock.self, from: Data(#"{"host":"crm.test","reason":"var_dumper_format","file":"/Users/x/Sites/crm/.env"}"#.utf8))

        #expect(block == DumpBlock(host: "crm.test", reason: .varDumperFormat, file: "/Users/x/Sites/crm/.env"))
        #expect(block.place == nil)
        #expect(try roundTrip(DumpBlock(host: "blog.test", reason: .userIni)) == DumpBlock(host: "blog.test", reason: .userIni))
    }

    @Test func aBlockKeepsItsPlace() throws {
        let block = DumpBlock(host: "fix.shop.test", reason: .userIni, file: "/Users/x/Sites/shop-fix/public/.user.ini", place: DumpPlace(site: "shop.test", workspace: "fix"))

        #expect(try roundTrip(block) == block)
    }

    @Test func aNodeOfANewerPHPSideStillDecodes() throws {
        let tree = try node(#"{"kind":"array","count":1,"children":[{"key":"case","access":"readonly","kind":"enum","value":"Paid"}]}"#)
        let child = try #require(tree.children?.first)

        #expect(child.kind == .label)
        #expect(child.access == .virtual)
        #expect(child.displayKey == "case")
    }

    @Test func anEntryOfEachKindKeepsItsNewFields() throws {
        let query = CaughtDump(requestID: "a1", seq: 4, time: Self.started, kind: .query, file: "/Users/x/Sites/shop/app/Cart.php", line: 38, label: "mysql", text: "select 1", milliseconds: 0.84, pattern: "select ?", number: 7)
        let log = CaughtDump(requestID: "a1", seq: 5, time: Self.started, kind: .log, label: "error", text: "No invoice.", treeJSON: #"{"kind":"array","count":0}"#, detail: "stack")
        let job = CaughtDump(requestID: "a1", seq: 6, time: Self.started, kind: .job, label: "queued", text: "App\\Jobs\\SendOrderMail", detail: "redis · default", ref: "9f1c0f6e")

        for entry in [query, log, job] {
            #expect(try roundTrip(entry) == entry)
        }

        let json = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
        #expect(json.contains(#""ms":0.84"#))
        #expect(!json.contains("milliseconds"))
    }

    @Test func aDumpOfAnOlderNexusdHasNoNewFields() throws {
        let json = #"{"requestID":"a1","seq":1,"time":0,"kind":"dd","text":"1","truncated":false}"#

        let caught = try JSONDecoder().decode(CaughtDump.self, from: Data(json.utf8))

        #expect(caught.kind == .dd)
        #expect(caught.milliseconds == nil)
        #expect(caught.pattern == nil)
        #expect(caught.detail == nil)
        #expect(caught.ref == nil)
    }

    @Test func aRefCanComeAsANumber() throws {
        let json = #"{"requestID":"a1","seq":1,"time":0,"kind":"job","label":"scheduled","text":"woocommerce_cleanup","ref":4711,"truncated":false}"#

        #expect(try JSONDecoder().decode(CaughtDump.self, from: Data(json.utf8)).ref == "4711")
    }

    @Test(arguments: [
        (CaughtDump.Kind.log, "error", nil, true),
        (.log, "CRITICAL", nil, true),
        (.log, "alert", nil, true),
        (.log, "emergency", "stack", true),
        (.log, "warning", "PHP warning", false),
        (.log, "error", "PHP error", true),
        (.log, "critical", "PHP fatal error", true),
        (.log, "notice", "PHP fatal error", true),
        (.log, "info", "stack", false),
        (.log, "deprecated", "PHP deprecated", false),
        (.query, "error", nil, false),
    ] as [(CaughtDump.Kind, String, String?, Bool)])
    func anErrorIsALogLineOfAnErrorLevelOrAPHPError(kind: CaughtDump.Kind, label: String, detail: String?, isError: Bool) {
        let entry = CaughtDump(requestID: "a1", seq: 1, time: Self.started, kind: kind, label: label, text: "x", detail: detail)

        #expect(entry.isError == isError)
    }

    @Test func onlyDumpAndDDAreDumps() {
        #expect(CaughtDump.Kind.dump.isDump)
        #expect(CaughtDump.Kind.dd.isDump)
        #expect(!CaughtDump.Kind.query.isDump)
        #expect(!CaughtDump.Kind.log.isDump)
        #expect(!CaughtDump.Kind.job.isDump)
    }

    @Test func aRequestKeepsItsCountsItsMarksAndItsJob() throws {
        let job = JobRun(system: .action, name: "woocommerce_cleanup_sessions", uuid: "4711", attempt: 1, outcome: .released)
        let request = DumpedRequest(id: "j1", kind: .job, target: "woocommerce_cleanup_sessions", started: Self.started, dumpCount: 1, queryCount: 12, queryMilliseconds: 48.5, logCount: 3, jobCount: 2, marks: [.slow, .nPlusOne], droppedQueries: 704, job: job)

        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        #expect(try roundTrip(request) == request)
        #expect(json.contains(#""marks":["n_plus_one","slow"]"#))
        #expect(request.entryCount == 18)
        #expect(request.displayMethod == "ACTION")
        #expect(request.statusText == "released")
    }

    @Test func aRequestWithOnlyDumpsHasNoKeysOfTheOtherKinds() throws {
        let request = DumpedRequest(id: "a1", kind: .http, method: "GET", target: "/", started: Self.started, dumpCount: 2, lastSeq: 2)

        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        for key in ["queryCount", "queryMilliseconds", "logCount", "errorCount", "jobCount", "marks", "droppedQueries", "job"] {
            #expect(!json.contains("\"\(key)\""))
        }

        #expect(try roundTrip(request) == request)
    }

    @Test(arguments: [
        (JobRun.System.laravel, "JOB"),
        (.cron, "CRON"),
        (.action, "ACTION"),
    ])
    func aJobShowsItsSystemAsItsMethod(system: JobRun.System, method: String) {
        let request = DumpedRequest(id: "j1", kind: .job, target: "send", started: Self.started, job: JobRun(system: system, name: "send"))

        #expect(request.displayMethod == method)
    }

    @Test func theTitleIsTheNameOfAJobTheURLOfAPageOrTheCommand() {
        let job = DumpedRequest(id: "j1", kind: .job, target: "App\\Jobs\\SendOrderMail", url: "https://shop.test/x", started: Self.started, job: JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail"))
        let page = DumpedRequest(id: "p1", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", started: Self.started)
        let command = DumpedRequest(id: "c1", kind: .command, target: "php artisan migrate", started: Self.started)

        #expect(job.title == "App\\Jobs\\SendOrderMail")
        #expect(page.title == "https://shop.test/checkout")
        #expect(command.title == "php artisan migrate")
    }

    @Test(arguments: [
        (JobRun.Outcome.failed, 3, 3, "try 3 of 3"),
        (.failed, 2, nil, "try 2"),
        (.failed, nil, nil, "failed"),
        (.done, 1, 3, "done"),
        (.released, 1, 3, "released"),
    ] as [(JobRun.Outcome, Int?, Int?, String)])
    func aFailedJobGivesItsTryAsItsStatus(outcome: JobRun.Outcome, attempt: Int?, maxTries: Int?, status: String) {
        let job = JobRun(system: .laravel, name: "send", attempt: attempt, maxTries: maxTries, outcome: outcome)
        let request = DumpedRequest(id: "j1", kind: .job, target: "send", started: Self.started, job: job)

        #expect(request.statusText == status)
    }

    @Test func aJobWithoutItsTryHasNoTryText() {
        #expect(JobRun(system: .cron, name: "wp_version_check").tryText == nil)
        #expect(JobRun(system: .laravel, name: "send", attempt: 1, maxTries: 3).tryText == "try 1 of 3")
        #expect(JobRun(system: .laravel, name: "send").outcomeText == nil)
    }

    @Test func aRequestStaysInTheListWithAnEntryOrAsAJobThatEnded() {
        let page = DumpedRequest(id: "p1", kind: .http, target: "/", started: Self.started, status: 200, duration: 0.2)
        let pageWithALogLine = DumpedRequest(id: "p2", kind: .http, target: "/", started: Self.started, logCount: 1)
        let running = DumpedRequest(id: "j1", kind: .job, target: "send", started: Self.started, job: JobRun(system: .laravel, name: "send"))
        let ended = DumpedRequest(id: "j2", kind: .job, target: "send", started: Self.started, job: JobRun(system: .laravel, name: "send", outcome: .done))
        let endedWithoutOutcome = DumpedRequest(id: "j3", kind: .job, target: "send", started: Self.started, duration: 0.1, job: JobRun(system: .cron, name: "send"))

        #expect(!page.staysInList)
        #expect(pageWithALogLine.staysInList)
        #expect(!running.staysInList)
        #expect(ended.staysInList)
        #expect(endedWithoutOutcome.staysInList)
    }

    @Test func anEntryCountsInTheCountOfItsKind() {
        var request = DumpedRequest(id: "a1", kind: .http, target: "/", started: Self.started)
        let kinds: [CaughtDump.Kind] = [.dump, .dd, .query, .query, .log, .job]

        for kind in kinds {
            request.count(CaughtDump(requestID: "a1", seq: 1, time: Self.started, kind: kind, text: "x"), by: 1)
        }

        let added = request
        request.count(CaughtDump(requestID: "a1", seq: 1, time: Self.started, kind: .query, text: "x"), by: -1)

        #expect(added.dumpCount == 2)
        #expect(added.queryCount == 2)
        #expect(added.logCount == 1)
        #expect(added.jobCount == 1)
        #expect(added.entryCount(of: [.dump, .dd]) == 2)
        #expect(added.entryCount(of: [.query, .job]) == 3)
        #expect(request.queryCount == 1)
    }

    @Test func aBlockNamesTheKindsThatItStopsWithOneTitleAndMessage() {
        let env = DumpBlock(host: "shop.test", reason: .varDumperFormat, file: "/w/shop/.env")
        let environment = DumpBlock(host: "shop.test", reason: .varDumperFormat)
        let userIni = DumpBlock(host: "blog.test", reason: .userIni, file: "/w/blog/public/.user.ini")
        let config = DumpBlock(host: "blog.test", reason: .savequeries)

        #expect(DumpBlock.Reason.varDumperFormat.stoppedKinds == [.dump, .dd])
        #expect(DumpBlock.Reason.savequeries.stoppedKinds == [.query])
        #expect(DumpBlock.Reason.userIni.stoppedKinds == [.dump, .dd, .query, .log, .job])
        #expect(env.title == "Nexus cannot catch the dumps of shop.test")
        #expect(env.message == "The .env of shop.test sets VAR_DUMPER_FORMAT. Remove this key to see its dumps here.")
        #expect(environment.message == "The environment of PHP for shop.test sets VAR_DUMPER_FORMAT. Remove this key to see its dumps here.")
        #expect(userIni.title == "Nexus cannot catch anything from blog.test")
        #expect(userIni.message == "The .user.ini of blog.test sets its own prepend file. PHP then runs that file and not the file of Nexus.")
        #expect(config.title == "Nexus cannot catch the queries of blog.test")
        #expect(config.message == "The wp-config.php for blog.test sets SAVEQUERIES to false. Remove this line to see its queries here.")
    }

    @Test func aRequestOfAnOlderNexusdHasNoCountsOfTheOtherKinds() throws {
        let json = #"{"id":"a1b2c3","kind":"http","method":"GET","target":"/","started":0,"dumpCount":2,"hasDD":false}"#

        let request = try JSONDecoder().decode(DumpedRequest.self, from: Data(json.utf8))

        #expect(request.queryCount == 0)
        #expect(request.queryMilliseconds == 0)
        #expect(request.logCount == 0)
        #expect(request.jobCount == 0)
        #expect(request.marks.isEmpty)
        #expect(request.droppedQueries == 0)
        #expect(request.job == nil)
        #expect(request.entryCount == 2)
    }

    @Test func aJobOfActionSchedulerCanHaveANumberAsItsID() throws {
        let json = #"{"system":"action","name":"woocommerce_cleanup_sessions","uuid":4711,"attempt":1,"maxTries":null}"#

        let job = try JSONDecoder().decode(JobRun.self, from: Data(json.utf8))

        #expect(job == JobRun(system: .action, name: "woocommerce_cleanup_sessions", uuid: "4711", attempt: 1))
    }

    @Test func aJobKeepsItsWorkerAndItsRequestAndHasNoKeysForThemWhenItHasNone() throws {
        let linked = JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail", uuid: "9f1c0f6e", command: "php artisan queue:work", queuedBy: "a1")
        let plain = JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail", uuid: "9f1c0f6e")

        let decoded = try JSONDecoder().decode(JobRun.self, from: JSONEncoder().encode(linked))
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)

        #expect(decoded == linked)
        #expect(!plainJSON.contains("command"))
        #expect(!plainJSON.contains("queuedBy"))
    }

    @Test func aBlockForSaveQueriesHasTheRawValueOfTheWire() throws {
        let block = try JSONDecoder().decode(DumpBlock.self, from: Data(#"{"host":"blog.test","reason":"savequeries","file":"/Users/x/Sites/blog/wp-config.php"}"#.utf8))

        #expect(block.reason == .savequeries)
        #expect(block.file == "/Users/x/Sites/blog/wp-config.php")
    }

    @Test func aDumpTakesItsIDFromTheRequestAndTheNumber() throws {
        let json = #"{"requestID":"65f1c2a9e3b1","seq":4,"time":"2026-11-11T10:00:00Z","kind":"dump","text":"1","truncated":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(try decoder.decode(CaughtDump.self, from: Data(json.utf8)).id == "65f1c2a9e3b1-4")
    }
}
